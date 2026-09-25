#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"

ensure_sa_password
"$HERE/automation/check_prerequisites.sh"
start_sql_server_if_needed
wait_for_sql

SQLCMD="$(sqlcmd_path)"
SQL=("$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)

PKG="$HERE/ssis/00_Master_Clickstream_ETL.dtsx"
MAN="$HERE/data/manifest.json"
OUT="$ROOT/Database/generated"
mkdir -p "$OUT"

[[ -f "$MAN" ]] || {
  echo "[FAIL] data/manifest.json missing. Run ./run_all.sh once first." >&2
  exit 1
}

echo '[5/9] Regenerate SSIS package with safe ObjectNames'
python3 "$HERE/ssis/build_dtsx.py" --output "$PKG"
python3 "$HERE/ssis/validate_dtsx.py" "$PKG"

echo '[6/9] Run native Linux SSIS'
"$HERE/ssis/run_ssis.sh" "$PKG"

echo '[7/9] Validate warehouse'
"${SQL[@]}" -d ClickstreamDW \
  -Q 'EXEC etl.usp_ReportValidation;' \
  | tee "$OUT/validation_output.txt"

STATUS=$(
  "${SQL[@]}" -d ClickstreamDW -h -1 -W \
    -Q "SET NOCOUNT ON; SELECT TOP(1) Status FROM etl.ETLBatch ORDER BY BatchId DESC;" \
  | xargs
)

[[ "$STATUS" == "SUCCEEDED" ]] || {
  echo "[FAIL] ETL status=$STATUS" >&2
  exit 1
}

cp -f "$MAN" "$OUT/source_manifest.json"

echo '[8/9] Export MDF/LDF'
"$ROOT/Database/export_database_files.sh" "$OUT"

echo '[9/9] Done'
find "$OUT" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
echo '[PASS] Completed from step 5.'
