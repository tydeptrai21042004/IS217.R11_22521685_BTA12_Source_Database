#!/usr/bin/env python3
"""
Download and canonicalize the COMPLETE UCI Clickstream Data for Online Shopping.

The official UCI archive is very small (~776 KB) and contains:
- e-shop clothing 2008.csv (~6.4 MB)
- data description text

No sampling/truncation is permitted.
"""
from __future__ import annotations
import argparse, csv, hashlib, io, json, os, shutil, sys, urllib.request, zipfile
from pathlib import Path
from datetime import datetime, timezone

URL = "https://archive.ics.uci.edu/static/public/553/clickstream%2Bdata%2Bfor%2Bonline%2Bshopping.zip"
EXPECTED_ROWS = 165_474
MAX_COLUMNS = 14
CANONICAL_HEADER = [
    "Year","Month","Day","ClickOrder","CountryCode","SessionID",
    "MainCategory","ClothingModel","Colour","PhotoLocation",
    "ModelPhotography","Price","PriceAboveCategoryAvg","PageNo"
]

def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024*1024), b""):
            h.update(block)
    return h.hexdigest()

def download(url: str, dest: Path, max_bytes: int):
    tmp = dest.with_suffix(dest.suffix + ".part")
    tmp.unlink(missing_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent":"UIT-IS217-BTA12/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r, tmp.open("wb") as out:
        clen = r.headers.get("Content-Length")
        if clen and int(clen) > max_bytes:
            raise RuntimeError(f"Server Content-Length {clen} exceeds hard cap {max_bytes}")
        total = 0
        while True:
            block = r.read(1024*1024)
            if not block:
                break
            total += len(block)
            if total > max_bytes:
                tmp.unlink(missing_ok=True)
                raise RuntimeError(f"Download exceeded hard cap {max_bytes:,} bytes")
            out.write(block)
            print(f"[INFO] download {total/1_000_000:.2f} MB / {max_bytes/1_000_000:.2f} MB")
    tmp.replace(dest)

def detect_text(path: Path):
    raw = path.read_bytes()
    for enc in ("utf-8-sig","utf-8","cp1252","latin-1"):
        try:
            return raw.decode(enc), enc
        except UnicodeDecodeError:
            pass
    raise RuntimeError("Could not decode source CSV")

def sniff_dialect(sample: str):
    try:
        return csv.Sniffer().sniff(sample[:10000], delimiters=";,|\t,")
    except Exception:
        class D(csv.excel):
            delimiter = ";"
        return D

def validate_cached(csv_path: Path, manifest_path: Path, max_bytes: int) -> bool:
    if not csv_path.exists() or not manifest_path.exists():
        return False
    try:
        m = json.loads(manifest_path.read_text(encoding="utf-8"))
        if m.get("rows_verified") != EXPECTED_ROWS:
            return False
        if csv_path.stat().st_size > max_bytes:
            return False
        if m.get("canonical_csv",{}).get("sha256") != sha256(csv_path):
            return False
        return True
    except Exception:
        return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--output", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--raw-dir", required=True)
    ap.add_argument("--max-bytes", type=int, default=50_000_000)
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args()

    out = Path(args.output).resolve()
    manifest = Path(args.manifest).resolve()
    raw_dir = Path(args.raw_dir).resolve()
    raw_dir.mkdir(parents=True, exist_ok=True)
    out.parent.mkdir(parents=True, exist_ok=True)

    if args.max_bytes > 50_000_000:
        raise RuntimeError("Refusing max-bytes above 50,000,000")

    if not args.refresh and validate_cached(out, manifest, args.max_bytes):
        m = json.loads(manifest.read_text(encoding="utf-8"))
        print(f"[PASS] Using verified cache: {out}")
        print(f"[PASS] rows={m['rows_verified']:,} bytes={out.stat().st_size:,}")
        return

    archive = raw_dir/"clickstream_uci_553.zip"
    print("[INFO] Downloading official UCI archive (~0.8 MB).")
    download(URL, archive, args.max_bytes)

    if not zipfile.is_zipfile(archive):
        raise RuntimeError("Downloaded file is not a valid ZIP archive.")

    with zipfile.ZipFile(archive) as z:
        names = z.namelist()
        csv_names = [n for n in names if n.lower().endswith(".csv")]
        if len(csv_names) != 1:
            raise RuntimeError(f"Expected one CSV in archive, got: {csv_names}")
        member = csv_names[0]
        raw_csv = raw_dir/"e-shop clothing 2008.csv"
        with z.open(member) as src, raw_csv.open("wb") as dst:
            copied = 0
            while True:
                block = src.read(1024*1024)
                if not block:
                    break
                copied += len(block)
                if copied > args.max_bytes:
                    raw_csv.unlink(missing_ok=True)
                    raise RuntimeError("Extracted source CSV exceeds 50,000,000-byte hard cap.")
                dst.write(block)

    text, encoding = detect_text(raw_csv)
    dialect = sniff_dialect(text)
    rows = list(csv.reader(io.StringIO(text), dialect))
    if not rows:
        raise RuntimeError("Source CSV is empty.")

    # UCI source normally contains a header. Determine using first cell.
    first = [c.strip().lower() for c in rows[0]]
    has_header = first and first[0] in ("year", '"year"')
    data_rows = rows[1:] if has_header else rows

    if len(data_rows) != EXPECTED_ROWS:
        raise RuntimeError(
            f"Unexpected UCI row count: expected {EXPECTED_ROWS:,}, got {len(data_rows):,}"
        )

    tmp = out.with_suffix(out.suffix+".part")
    tmp.unlink(missing_ok=True)
    with tmp.open("w", encoding="utf-8", newline="") as f:
        w = csv.writer(f, lineterminator="\n")
        w.writerow(CANONICAL_HEADER)
        for i, row in enumerate(data_rows, start=1):
            if len(row) != MAX_COLUMNS:
                raise RuntimeError(f"Row {i} has {len(row)} columns; expected {MAX_COLUMNS}")
            w.writerow([c.strip() for c in row])
            if i % 20000 == 0:
                f.flush()
                if tmp.stat().st_size > args.max_bytes:
                    tmp.unlink(missing_ok=True)
                    raise RuntimeError("Canonical CSV exceeded hard cap.")
    if tmp.stat().st_size > args.max_bytes:
        tmp.unlink(missing_ok=True)
        raise RuntimeError("Canonical CSV exceeded hard cap.")
    tmp.replace(out)

    m = {
        "source": "UCI Machine Learning Repository",
        "dataset": "Clickstream Data for Online Shopping",
        "uci_id": 553,
        "sampling": False,
        "truncation": False,
        "expected_rows": EXPECTED_ROWS,
        "rows_verified": len(data_rows),
        "source_encoding": encoding,
        "source_delimiter": dialect.delimiter,
        "downloaded_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat(),
        "archive": {
            "url": URL,
            "bytes": archive.stat().st_size,
            "sha256": sha256(archive),
        },
        "raw_csv": {
            "bytes": raw_csv.stat().st_size,
            "sha256": sha256(raw_csv),
        },
        "canonical_csv": {
            "path": str(out),
            "bytes": out.stat().st_size,
            "sha256": sha256(out),
            "columns": CANONICAL_HEADER,
        }
    }
    manifest.write_text(json.dumps(m, indent=2), encoding="utf-8")
    print(f"[PASS] COMPLETE dataset ready: rows={EXPECTED_ROWS:,}, csv={out.stat().st_size/1_000_000:.2f} MB")
    print(f"[PASS] archive={archive.stat().st_size/1_000_000:.2f} MB; no sampling; no truncation")

if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[FAIL] {e}", file=sys.stderr)
        raise
