#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/../common.sh"; PACKAGE="${1:?Usage: run_ssis.sh PACKAGE.dtsx}"; ensure_sa_password; DTEXEC="$(dtexec_path)"
CONN="Provider=MSOLEDBSQL;Data Source=localhost;Initial Catalog=NYC311_DW;User ID=sa;Password=${MSSQL_SA_PASSWORD};Encrypt=Optional;TrustServerCertificate=True;"
echo '[INFO] Running native Linux SSIS/dtexec.'
"$DTEXEC" /F "$PACKAGE" /CONNECTION "NYC311_DW;\"$CONN\"" /REPORTING E
rc=$?; [[ $rc -eq 0 ]] || { echo "[FAIL] dtexec=$rc" >&2; exit $rc; }; echo '[PASS] SSIS completed.'
