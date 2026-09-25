#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import subprocess
from pathlib import Path


def sql_literal(value: str) -> str:
    return value.replace("'", "''")


def find_sqlcmd() -> str:
    candidates = [
        "/opt/mssql-tools18/bin/sqlcmd",
        "/opt/mssql-tools/bin/sqlcmd",
        "sqlcmd",
    ]
    for c in candidates:
        if c == "sqlcmd":
            return c
        if Path(c).exists():
            return c
    return "sqlcmd"


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--server", default="localhost")
    p.add_argument("--user", default="sa")
    p.add_argument("--database", default="NYC311_DW")
    p.add_argument("--manifest", required=True)
    p.add_argument("--sql-source-path", required=True,
                   help="Path as visible to the SQL Server service, e.g. /var/opt/mssql/import/nyc311.csv")
    args = p.parse_args()

    password = os.environ.get("MSSQL_SA_PASSWORD") or os.environ.get("SQLCMDPASSWORD")
    if not password:
        raise SystemExit("MSSQL_SA_PASSWORD (or SQLCMDPASSWORD) must be set")

    manifest = json.loads(Path(args.manifest).read_text(encoding="utf-8"))
    rows = int(manifest["rows_verified_in_csv"])
    sha = manifest["sha256"]
    day = manifest["selection"]["chosen_date"]
    source = args.sql_source_path

    sql = f"""
USE [{args.database}];
UPDATE etl.RuntimeConfig SET ConfigValue=N'{sql_literal(source)}' WHERE ConfigKey=N'SourceCsvPath';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{rows}' WHERE ConfigKey=N'ExpectedSourceRows';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{sql_literal(sha)}' WHERE ConfigKey=N'SourceSha256';
UPDATE etl.RuntimeConfig SET ConfigValue=N'{sql_literal(day)}' WHERE ConfigKey=N'DatasetDate';
SELECT ConfigKey, ConfigValue FROM etl.RuntimeConfig ORDER BY ConfigKey;
"""
    env = os.environ.copy()
    env["SQLCMDPASSWORD"] = password
    cmd = [
        find_sqlcmd(), "-S", args.server, "-U", args.user,
        "-C", "-b", "-d", "master", "-Q", sql,
    ]
    subprocess.run(cmd, check=True, env=env)


if __name__ == "__main__":
    main()
