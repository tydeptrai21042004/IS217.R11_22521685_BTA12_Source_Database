#!/usr/bin/env python3
"""Download a complete, real NYC 311 calendar-day slice under a hard size cap.

The script NEVER truncates or randomly samples rows. It searches backward from a
starting date, estimates complete-day CSV size, then downloads the largest safe
candidate. If the real CSV would exceed the hard cap, that candidate is deleted
and the next candidate is tried.

Default hard cap: 50,000,000 bytes (50.00 MB decimal).
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import sys
import time
from dataclasses import dataclass, asdict
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

DATASET_ID = "erm2-nwe9"
DOMAIN = "https://data.cityofnewyork.us"
RESOURCE_URL = f"{DOMAIN}/resource/{DATASET_ID}.json"
USER_AGENT = "UIT-IS217-BTA12-NYC311-Linux/2.0"

SOURCE_COLUMNS = [
    "unique_key", "created_date", "closed_date", "agency", "agency_name",
    "complaint_type", "descriptor", "location_type", "incident_zip", "city",
    "borough", "status", "latitude", "longitude",
]
CSV_HEADER = [
    "UniqueKey", "CreatedDate", "ClosedDate", "Agency", "AgencyName",
    "ComplaintType", "Descriptor", "LocationType", "IncidentZip", "City",
    "Borough", "Status", "Latitude", "Longitude",
]


@dataclass
class Candidate:
    day: str
    row_count: int
    estimated_bytes: int


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--start-date", default="2025-01-15", help="YYYY-MM-DD")
    p.add_argument("--lookback-days", type=int, default=45)
    p.add_argument("--output-dir", required=True)
    p.add_argument("--manifest-json", required=True)
    p.add_argument("--manifest-csv", required=True)
    p.add_argument("--max-bytes", type=int, default=50_000_000,
                   help="Hard cap for the final CSV. Default exactly 50,000,000 bytes.")
    p.add_argument("--safe-estimate-ratio", type=float, default=0.90,
                   help="Only preselect days estimated below this fraction of cap.")
    p.add_argument("--sample-rows", type=int, default=300)
    p.add_argument("--page-size", type=int, default=50_000)
    return p.parse_args()


def http_get_json(params: dict[str, str], timeout: int = 120, retries: int = 5):
    url = RESOURCE_URL + "?" + urlencode(params)
    last = None
    for attempt in range(retries):
        try:
            req = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
            with urlopen(req, timeout=timeout) as r:
                return json.loads(r.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError) as exc:
            last = exc
            if attempt + 1 == retries:
                raise
            delay = min(2 ** attempt, 12)
            print(f"[WARN] API request failed ({exc}); retrying in {delay}s", flush=True)
            time.sleep(delay)
    raise RuntimeError(last)


def interval_where(day: date) -> str:
    nxt = day + timedelta(days=1)
    return (
        f"created_date >= '{day.isoformat()}T00:00:00.000' AND "
        f"created_date < '{nxt.isoformat()}T00:00:00.000'"
    )


def get_count(day: date) -> int:
    payload = http_get_json({
        "$select": "count(*) as row_count",
        "$where": interval_where(day),
    })
    return int(payload[0]["row_count"])


def get_rows(day: date, *, limit: int, offset: int = 0):
    return http_get_json({
        "$select": ",".join(SOURCE_COLUMNS),
        "$where": interval_where(day),
        "$order": "unique_key ASC",
        "$limit": str(limit),
        "$offset": str(offset),
    })


def normalize(row: dict) -> list[str]:
    return ["" if row.get(c) is None else str(row.get(c, "")).strip() for c in SOURCE_COLUMNS]


def encode_csv_row(values: list[str]) -> bytes:
    buf = io.StringIO(newline="")
    csv.writer(buf, quoting=csv.QUOTE_MINIMAL, lineterminator="\n").writerow(values)
    return buf.getvalue().encode("utf-8")


def estimate_day(day: date, sample_rows: int) -> Candidate | None:
    count = get_count(day)
    if count <= 0:
        return None
    sample = get_rows(day, limit=min(sample_rows, count), offset=0)
    if not sample:
        return None
    sample_bytes = sum(len(encode_csv_row(normalize(r))) for r in sample)
    avg = sample_bytes / len(sample)
    # Add 8% headroom for row-size variation + header.
    estimate = int(avg * count * 1.08 + len(encode_csv_row(CSV_HEADER)))
    return Candidate(day=day.isoformat(), row_count=count, estimated_bytes=estimate)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def verify_csv(path: Path) -> tuple[int, list[str]]:
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        count = sum(1 for _ in reader)
    return count, header


def try_download(candidate: Candidate, out_dir: Path, max_bytes: int, page_size: int) -> Path | None:
    day = date.fromisoformat(candidate.day)
    final = out_dir / f"nyc311_{candidate.day}.csv"
    partial = out_dir / f".nyc311_{candidate.day}.partial"
    final.unlink(missing_ok=True)
    partial.unlink(missing_ok=True)

    expected = candidate.row_count
    downloaded = 0
    offset = 0
    seen: set[str] = set()
    current_bytes = 0

    with partial.open("wb") as f:
        header_bytes = encode_csv_row(CSV_HEADER)
        if len(header_bytes) > max_bytes:
            raise RuntimeError("CSV header alone exceeds max size (unexpected).")
        f.write(header_bytes)
        current_bytes += len(header_bytes)

        while downloaded < expected:
            rows = get_rows(day, limit=min(page_size, expected - downloaded), offset=offset)
            if not rows:
                break
            for row in rows:
                key = str(row.get("unique_key", "")).strip()
                if not key:
                    partial.unlink(missing_ok=True)
                    raise RuntimeError(f"Source row without unique_key on {candidate.day}")
                if key in seen:
                    partial.unlink(missing_ok=True)
                    raise RuntimeError(f"Duplicate unique_key from API paging: {key}")
                seen.add(key)

                row_bytes = encode_csv_row(normalize(row))
                # Hard guarantee: never write a byte that would push the local file over cap.
                if current_bytes + len(row_bytes) > max_bytes:
                    print(
                        f"[SKIP] {candidate.day}: complete day would exceed hard cap "
                        f"{max_bytes:,} bytes. Partial file is deleted.", flush=True
                    )
                    f.close()
                    partial.unlink(missing_ok=True)
                    return None
                f.write(row_bytes)
                current_bytes += len(row_bytes)

            downloaded += len(rows)
            offset += len(rows)
            print(
                f"[DOWNLOAD] {candidate.day}: {downloaded:,}/{expected:,} rows | "
                f"{current_bytes/1_000_000:.2f} MB", flush=True
            )

    if downloaded != expected:
        partial.unlink(missing_ok=True)
        raise RuntimeError(
            f"Incomplete API download for {candidate.day}: expected={expected}, downloaded={downloaded}"
        )

    partial.replace(final)
    rows, header = verify_csv(final)
    if header != CSV_HEADER or rows != expected:
        final.unlink(missing_ok=True)
        raise RuntimeError(
            f"CSV verification failed for {candidate.day}: expected={expected}, verified={rows}"
        )
    if final.stat().st_size > max_bytes:
        final.unlink(missing_ok=True)
        raise RuntimeError("Hard size-cap invariant violated.")
    return final


def main() -> int:
    args = parse_args()
    if args.max_bytes <= 0 or args.lookback_days <= 0 or args.page_size <= 0:
        raise ValueError("max-bytes, lookback-days and page-size must be positive")
    if not (0.50 <= args.safe_estimate_ratio <= 1.0):
        raise ValueError("safe-estimate-ratio must be between 0.50 and 1.0")

    start = date.fromisoformat(args.start_date)
    out_dir = Path(args.output_dir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    manifest_json = Path(args.manifest_json).resolve()
    manifest_csv = Path(args.manifest_csv).resolve()
    manifest_json.parent.mkdir(parents=True, exist_ok=True)
    manifest_csv.parent.mkdir(parents=True, exist_ok=True)

    # Remove old NYC311 CSVs so output contains only the selected source dataset.
    for old in out_dir.glob("nyc311_*.csv"):
        old.unlink()
    for old in out_dir.glob(".nyc311_*.partial"):
        old.unlink()

    safe_limit = int(args.max_bytes * args.safe_estimate_ratio)
    scanned: list[Candidate] = []
    print(
        f"[INFO] Searching up to {args.lookback_days} complete days from {start.isoformat()} "
        f"for a real dataset <= {args.max_bytes:,} bytes ({args.max_bytes/1_000_000:.2f} MB).",
        flush=True,
    )

    for i in range(args.lookback_days):
        d = start - timedelta(days=i)
        try:
            c = estimate_day(d, args.sample_rows)
        except Exception as exc:
            print(f"[WARN] Could not estimate {d}: {exc}", flush=True)
            continue
        if c is None:
            continue
        scanned.append(c)
        print(
            f"[SCAN] {c.day}: rows={c.row_count:,}, "
            f"estimated={c.estimated_bytes/1_000_000:.2f} MB",
            flush=True,
        )

    # Prefer the largest estimated complete-day dataset below a conservative threshold.
    candidates = sorted(
        [c for c in scanned if c.estimated_bytes <= safe_limit],
        key=lambda c: c.estimated_bytes,
        reverse=True,
    )
    # If estimator was conservative and found none, still try all days smallest-first;
    # hard byte checking guarantees nothing > max_bytes is retained.
    if not candidates:
        candidates = sorted(scanned, key=lambda c: c.estimated_bytes)

    chosen: Candidate | None = None
    final_path: Path | None = None
    attempts: list[dict] = []
    for c in candidates:
        print(
            f"[TRY] {c.day}: estimated {c.estimated_bytes/1_000_000:.2f} MB, "
            f"{c.row_count:,} rows",
            flush=True,
        )
        path = try_download(c, out_dir, args.max_bytes, args.page_size)
        attempts.append({**asdict(c), "accepted": path is not None})
        if path is not None:
            chosen, final_path = c, path
            break

    if chosen is None or final_path is None:
        raise RuntimeError(
            "No complete calendar day could be downloaded under the 50 MB hard cap. "
            "Increase lookback-days; do not increase max-bytes if your assignment requires <=50 MB."
        )

    actual_bytes = final_path.stat().st_size
    digest = sha256_file(final_path)
    verified_rows, header = verify_csv(final_path)
    assert actual_bytes <= args.max_bytes
    assert verified_rows == chosen.row_count
    assert header == CSV_HEADER

    manifest = {
        "source": "NYC Open Data",
        "dataset_name": "311 Service Requests from 2020 to Present",
        "dataset_id": DATASET_ID,
        "source_resource_url": RESOURCE_URL,
        "selection": {
            "method": "automatic_complete_calendar_day_under_hard_size_cap",
            "start_date": args.start_date,
            "lookback_days": args.lookback_days,
            "chosen_date": chosen.day,
            "sampling": False,
            "truncation": False,
        },
        "hard_size_cap_bytes": args.max_bytes,
        "hard_size_cap_mb_decimal": args.max_bytes / 1_000_000,
        "rows_expected_from_api": chosen.row_count,
        "rows_verified_in_csv": verified_rows,
        "file": str(final_path),
        "size_bytes": actual_bytes,
        "size_mb_decimal": round(actual_bytes / 1_000_000, 4),
        "sha256": digest,
        "columns": CSV_HEADER,
        "selection_attempts": attempts,
        "generated_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
    }
    manifest_json.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    with manifest_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["dataset_id", "chosen_date", "rows", "size_bytes", "size_mb", "sha256", "file"])
        w.writerow([
            DATASET_ID, chosen.day, verified_rows, actual_bytes,
            f"{actual_bytes/1_000_000:.4f}", digest, str(final_path),
        ])

    print("\n[PASS] Real dataset selected and verified")
    print(f"       date       : {chosen.day}")
    print(f"       rows       : {verified_rows:,}")
    print(f"       size       : {actual_bytes:,} bytes ({actual_bytes/1_000_000:.2f} MB)")
    print(f"       hard cap   : {args.max_bytes:,} bytes")
    print(f"       sampling   : NO")
    print(f"       truncation : NO")
    print(f"       sha256     : {digest}")
    print(f"       file       : {final_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise
