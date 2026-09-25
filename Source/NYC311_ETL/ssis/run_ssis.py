#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
from pathlib import Path


def find_dtexec() -> str:
    for c in ["/opt/ssis/bin/dtexec", "dtexec"]:
        if c.startswith("/") and Path(c).exists():
            return c
        resolved = shutil.which(c)
        if resolved:
            return resolved
    raise SystemExit("dtexec not found. Install/configure mssql-server-is first.")


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--package", required=True)
    p.add_argument("--server", default="localhost")
    p.add_argument("--user", default="sa")
    p.add_argument("--database", default="NYC311_DW")
    args = p.parse_args()

    password = os.environ.get("MSSQL_SA_PASSWORD")
    if not password:
        raise SystemExit("MSSQL_SA_PASSWORD must be set")

    # SQL Authentication is required for SSIS on Linux. The package's dummy
    # connection is replaced at runtime; no password is persisted in the DTSX.
    connection_string = (
        f"Data Source={args.server};Initial Catalog={args.database};Provider=SQLNCLI11.1;"
        f"User ID={args.user};Password={password};Persist Security Info=True;"
        "Auto Translate=False;TrustServerCertificate=True;"
    )
    cmd = [
        find_dtexec(),
        "/F", str(Path(args.package).resolve()),
        "/CONNECTION", f"NYC311_DW;{connection_string}",
        "/REPORTING", "E",
    ]
    print("[RUN] dtexec /F <package> /CONNECTION NYC311_DW;<redacted> /REPORTING E")
    completed = subprocess.run(cmd)
    if completed.returncode != 0:
        raise SystemExit(f"SSIS failed; dtexec exit code {completed.returncode}")
    print("[PASS] SSIS package completed successfully")


if __name__ == "__main__":
    main()
