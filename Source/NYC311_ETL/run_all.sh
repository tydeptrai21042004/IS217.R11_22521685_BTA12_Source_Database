#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/../.." && pwd)"; source "$HERE/common.sh"
INSTALL=0; START_DATE='2025-01-15'; LOOKBACK=60; MAX_BYTES=50000000
while [[ $# -gt 0 ]]; do case "$1" in --install) INSTALL=1;shift;; --start-date) START_DATE="$2";shift 2;; --lookback-days) LOOKBACK="$2";shift 2;; --max-bytes) MAX_BYTES="$2";shift 2;; -h|--help) echo 'Usage: ./run_all.sh [--install] [--start-date YYYY-MM-DD] [--lookback-days N]';exit 0;; *) echo "Unknown $1";exit 2;; esac; done
(( MAX_BYTES<=50000000 )) || { echo '[FAIL] >50MB refused'; exit 2; }; ensure_sa_password; if (( INSTALL )); then ensure_sudo_password; "$HERE/setup_linux.sh"; fi
"$HERE/automation/check_prerequisites.sh" || { echo '[FAIL] Run with --install'; exit 1; }; start_sql_server_if_needed; wait_for_sql; SQLCMD="$(sqlcmd_path)"; SQL=("$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)
DATA="$HERE/data";mkdir -p "$DATA"; CSV="$DATA/nyc311_source.csv"; MAN="$DATA/manifest.json"; SDIR='/var/opt/mssql/data/bta12_source'; SCSV="$SDIR/nyc311_source.csv"; PKG="$HERE/ssis/00_Master_NYC311_ETL.dtsx"; mkdir -p "$ROOT/Database/generated"
echo '[1/9] Select/download complete real dataset <=50MB'; python3 "$HERE/automation/download_nyc311.py" --start-date "$START_DATE" --lookback-days "$LOOKBACK" --max-bytes "$MAX_BYTES" --output "$CSV" --manifest "$MAN"; ACT=$(stat -c %s "$CSV"); (( ACT<=50000000 )) || exit 1
echo '[2/9] Copy source for SQL Server'; sudo_run mkdir -p "$SDIR"; sudo_run cp -f "$CSV" "$SCSV"; sudo_run chown mssql:mssql "$SCSV"; sudo_run chmod 640 "$SCSV"
echo '[3/9] Build warehouse'; "${SQL[@]}" -i "$ROOT/Database/sql/00_create_database.sql"; "${SQL[@]}" -i "$ROOT/Database/sql/01_etl_procedures.sql"
readarray -t M < <(python3 -c "import json; m=json.load(open('$MAN')); print(m['rows_verified']); print(m['sha256']); print(m['selected_complete_day'])"); ROWS="${M[0]}"; SHA="${M[1]}"; DAY="${M[2]}"
echo '[4/9] Configure runtime'; "${SQL[@]}" -d NYC311_DW -Q "UPDATE etl.RuntimeConfig SET ConfigValue=N'$SCSV' WHERE ConfigKey=N'SourceCsvPath'; UPDATE etl.RuntimeConfig SET ConfigValue=N'$ROWS' WHERE ConfigKey=N'ExpectedSourceRows'; UPDATE etl.RuntimeConfig SET ConfigValue=N'$SHA' WHERE ConfigKey=N'SourceSha256'; UPDATE etl.RuntimeConfig SET ConfigValue=N'$DAY' WHERE ConfigKey=N'DatasetDate';"
echo '[5/9] Generate DTSX'; python3 "$HERE/ssis/build_dtsx.py" --output "$PKG"
echo '[6/9] Run SSIS'; "$HERE/ssis/run_ssis.sh" "$PKG"
echo '[7/9] Validate'; "${SQL[@]}" -d NYC311_DW -Q 'EXEC etl.usp_ReportValidation;' | tee "$ROOT/Database/generated/validation_output.txt"; STATUS=$("${SQL[@]}" -d NYC311_DW -h -1 -W -Q "SET NOCOUNT ON; SELECT TOP(1) Status FROM etl.ETLBatch ORDER BY BatchId DESC;"|xargs); [[ "$STATUS" == SUCCEEDED ]] || { echo "[FAIL] ETL status=$STATUS";exit 1; }
echo '[8/9] Export MDF/LDF'; "$ROOT/Database/export_database_files.sh" "$ROOT/Database/generated"
echo '[9/9] Done'; find "$ROOT/Database/generated" -maxdepth 1 -type f -printf '%f %s bytes\n'|sort; printf '[PASS] day=%s rows=%s dataset=%s bytes\n' "$DAY" "$ROWS" "$ACT"
