#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


def q(s: str) -> str:
    return s.replace("'", "''")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--server", required=True)
    p.add_argument("--database", default="NYC311_DW")
    p.add_argument("--manifest", required=True)
    args = p.parse_args()

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    source_file = manifest["file"]
    rows = int(manifest["rows_verified_in_csv"])
    sha = manifest["sha256"]
    day = manifest["scope"]["created_date_day"]

    sql = f"""
USE [{args.database}];
UPDATE etl.RuntimeConfig SET ConfigValue=N'{q(source_file)}' WHERE ConfigKey=N'SourceCsvPath';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{rows}' WHERE ConfigKey=N'ExpectedSourceRows';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{q(sha)}' WHERE ConfigKey=N'SourceSha256';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{q(day)}' WHERE ConfigKey=N'DatasetDate';
SELECT * FROM etl.RuntimeConfig ORDER BY ConfigKey;
"""
    cmd = ["sqlcmd", "-S", args.server, "-E", "-b", "-d", "master", "-Q", sql]
    print("[RUN]", " ".join(cmd[:-1]), "<SQL>")
    subprocess.run(cmd, check=True)


if __name__ == "__main__":
    main()
