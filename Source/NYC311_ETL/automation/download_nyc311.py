#!/usr/bin/env python3
"""
Download a COMPLETE one-day slice of the official NYC 311 dataset.

No sampling is performed. The script:
1. queries COUNT(*) for the requested Created Date interval,
2. downloads every row using deterministic paging,
3. checks output row count,
4. enforces max file size,
5. writes manifest.json and manifest.csv with SHA-256.

Uses only the Python standard library.
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
from datetime import date, datetime, timedelta
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError

DATASET_ID = "erm2-nwe9"
DOMAIN = "https://data.cityofnewyork.us"
SELECT_COLUMNS = [
    "unique_key",
    "created_date",
    "closed_date",
    "agency",
    "agency_name",
    "complaint_type",
    "descriptor",
    "location_type",
    "incident_zip",
    "city",
    "borough",
    "status",
    "latitude",
    "longitude",
]

EXPECTED_HEADER = [
    "UniqueKey",
    "CreatedDate",
    "ClosedDate",
    "Agency",
    "AgencyName",
    "ComplaintType",
    "Descriptor",
    "LocationType",
    "IncidentZip",
    "City",
    "Borough",
    "Status",
    "Latitude",
    "Longitude",
]

USER_AGENT = "UIT-IS217-BTA12-NYC311-ETL/1.0"


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--date", default="2025-01-15", help="YYYY-MM-DD")
    p.add_argument("--output", required=True)
    p.add_argument("--manifest-json", required=True)
    p.add_argument("--manifest-csv", required=True)
    p.add_argument("--max-mb", type=float, default=49.0)
    p.add_argument("--page-size", type=int, default=50000)
    return p.parse_args()


def http_get(url: str, timeout: int = 120, retries: int = 5) -> bytes:
    last = None
    for attempt in range(retries):
        try:
            req = Request(url, headers={"User-Agent": USER_AGENT})
            with urlopen(req, timeout=timeout) as r:
                return r.read()
        except (HTTPError, URLError, TimeoutError) as exc:
            last = exc
            if attempt + 1 == retries:
                raise
            sleep_s = min(2 ** attempt, 15)
            print(f"[WARN] HTTP attempt {attempt+1} failed: {exc}; retry in {sleep_s}s")
            time.sleep(sleep_s)
    raise RuntimeError(last)


def make_interval(day: str) -> tuple[str, str]:
    d = date.fromisoformat(day)
    d2 = d + timedelta(days=1)
    return d.isoformat() + "T00:00:00.000", d2.isoformat() + "T00:00:00.000"


def build_where(day: str) -> str:
    start, end = make_interval(day)
    return f"created_date >= '{start}' AND created_date < '{end}'"


def get_expected_count(day: str) -> int:
    params = {
        "$select": "count(*) as row_count",
        "$where": build_where(day),
    }
    url = f"{DOMAIN}/resource/{DATASET_ID}.json?{urlencode(params)}"
    payload = json.loads(http_get(url).decode("utf-8"))
    if not payload or "row_count" not in payload[0]:
        raise RuntimeError(f"Unexpected count response: {payload!r}")
    return int(payload[0]["row_count"])


def get_page(day: str, limit: int, offset: int) -> list[dict]:
    params = {
        "$select": ",".join(SELECT_COLUMNS),
        "$where": build_where(day),
        "$order": "unique_key ASC",
        "$limit": str(limit),
        "$offset": str(offset),
    }
    url = f"{DOMAIN}/resource/{DATASET_ID}.json?{urlencode(params)}"
    payload = json.loads(http_get(url).decode("utf-8"))
    if not isinstance(payload, list):
        raise RuntimeError("Unexpected API payload.")
    return payload


def normalize_row(row: dict) -> list[str]:
    def s(key: str) -> str:
        v = row.get(key, "")
        return "" if v is None else str(v).strip()

    return [
        s("unique_key"),
        s("created_date"),
        s("closed_date"),
        s("agency"),
        s("agency_name"),
        s("complaint_type"),
        s("descriptor"),
        s("location_type"),
        s("incident_zip"),
        s("city"),
        s("borough"),
        s("status"),
        s("latitude"),
        s("longitude"),
    ]


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def count_csv_rows(path: Path) -> int:
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        if header != EXPECTED_HEADER:
            raise RuntimeError(f"Unexpected CSV header: {header}")
        return sum(1 for _ in reader)


def main() -> int:
    args = parse_args()
    out = Path(args.output).resolve()
    mjson = Path(args.manifest_json).resolve()
    mcsv = Path(args.manifest_csv).resolve()

    out.parent.mkdir(parents=True, exist_ok=True)
    mjson.parent.mkdir(parents=True, exist_ok=True)
    mcsv.parent.mkdir(parents=True, exist_ok=True)

    # Validate date early
    date.fromisoformat(args.date)

    max_bytes = int(args.max_mb * 1024 * 1024)
    expected = get_expected_count(args.date)
    print(f"[INFO] Official source row count for {args.date}: {expected:,}")
    if expected == 0:
        raise RuntimeError("The selected day returned zero rows.")

    tmp = out.with_suffix(out.suffix + ".partial")
    if tmp.exists():
        tmp.unlink()

    downloaded = 0
    offset = 0
    seen_keys = set()

    # utf-8-sig makes the file easy to inspect in Excel and SQL Server.
    with tmp.open("w", encoding="utf-8-sig", newline="") as f:
        writer = csv.writer(f, quoting=csv.QUOTE_MINIMAL, lineterminator="\n")
        writer.writerow(EXPECTED_HEADER)

        while downloaded < expected:
            page = get_page(args.date, args.page_size, offset)
            if not page:
                break

            for row in page:
                key = str(row.get("unique_key", "")).strip()
                if not key:
                    raise RuntimeError("Source row without unique_key.")
                if key in seen_keys:
                    raise RuntimeError(f"Duplicate unique_key returned by paging: {key}")
                seen_keys.add(key)
                writer.writerow(normalize_row(row))

            downloaded += len(page)
            offset += len(page)
            f.flush()

            size = tmp.stat().st_size
            print(
                f"[INFO] downloaded={downloaded:,}/{expected:,} "
                f"size={size / 1024 / 1024:.2f} MB"
            )

            if size > max_bytes:
                f.close()
                tmp.unlink(missing_ok=True)
                raise RuntimeError(
                    f"Dataset exceeded {args.max_mb:.2f} MB. "
                    "Choose another complete day or reduce selected columns; "
                    "the script will not silently sample/truncate."
                )

    if downloaded != expected:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(
            f"Incomplete download: expected={expected:,}, downloaded={downloaded:,}"
        )

    if out.exists():
        out.unlink()
    tmp.replace(out)

    verified_rows = count_csv_rows(out)
    if verified_rows != expected:
        out.unlink(missing_ok=True)
        raise RuntimeError(
            f"CSV verification failed: expected={expected:,}, csv_rows={verified_rows:,}"
        )

    size_bytes = out.stat().st_size
    digest = sha256_file(out)

    manifest = {
        "source": "NYC Open Data",
        "dataset_name": "311 Service Requests from 2020 to Present",
        "dataset_id": DATASET_ID,
        "scope": {
            "created_date_day": args.date,
            "sampling": False,
            "scope_type": "complete_calendar_day",
        },
        "rows_expected_from_api": expected,
        "rows_downloaded": downloaded,
        "rows_verified_in_csv": verified_rows,
        "columns": EXPECTED_HEADER,
        "file": str(out),
        "size_bytes": size_bytes,
        "size_mb": round(size_bytes / 1024 / 1024, 4),
        "sha256": digest,
        "downloaded_at_utc": datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    }

    mjson.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    with mcsv.open("w", encoding="utf-8-sig", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(["dataset_id", "day", "rows", "size_bytes", "size_mb", "sha256", "file"])
        w.writerow([
            DATASET_ID, args.date, verified_rows, size_bytes,
            manifest["size_mb"], digest, str(out)
        ])

    print("[PASS] Complete real-data slice downloaded and verified.")
    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        raise
