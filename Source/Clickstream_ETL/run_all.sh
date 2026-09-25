#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/common.sh"

INSTALL=0
REFRESH=0
MAX_BYTES=50000000

while [[ $# -gt 0 ]]; do
 case "$1" in
  --install) INSTALL=1; shift;;
  --refresh-data) REFRESH=1; shift;;
  --max-bytes) MAX_BYTES="$2"; shift 2;;
  -h|--help)
   echo 'Usage: ./run_all.sh [--install] [--refresh-data] [--max-bytes 50000000]'
   exit 0;;
  *) echo "Unknown option: $1"; exit 2;;
 esac
done

(( MAX_BYTES<=50000000 )) || { echo '[FAIL] Refusing cap above 50,000,000 bytes.'; exit 2; }

ensure_sa_password
if (( INSTALL )); then
  ensure_sudo_password
  "$HERE/setup_linux.sh"
fi

"$HERE/automation/check_prerequisites.sh" || {
 echo '[FAIL] Missing prerequisites. Your machine already installed SQL Server/SSIS previously; use --install only if needed.'
 exit 1
}

start_sql_server_if_needed
wait_for_sql

SQLCMD="$(sqlcmd_path)"
SQL=("$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b)

DATA="$HERE/data"
RAW="$DATA/raw"
mkdir -p "$DATA" "$RAW" "$ROOT/Database/generated"
CSV="$DATA/clickstream_source.csv"
MAN="$DATA/manifest.json"

SDIR='/var/opt/mssql/data/bta12_clickstream_source'
SCSV="$SDIR/clickstream_source.csv"
PKG="$HERE/ssis/00_Master_Clickstream_ETL.dtsx"

echo '[1/9] Prepare COMPLETE UCI Clickstream dataset (<50MB; archive ~0.8MB)'
ARGS=(--output "$CSV" --manifest "$MAN" --raw-dir "$RAW" --max-bytes "$MAX_BYTES")
(( REFRESH )) && ARGS+=(--refresh)
python3 "$HERE/automation/download_clickstream.py" "${ARGS[@]}"

ACT=$(stat -c %s "$CSV")
(( ACT<=50000000 )) || { echo '[FAIL] Canonical CSV >50MB'; exit 1; }

echo '[2/9] Copy verified CSV for SQL Server'
sudo_run mkdir -p "$SDIR"
sudo_run cp -f "$CSV" "$SCSV"
sudo_run chown mssql:mssql "$SCSV"
sudo_run chmod 640 "$SCSV"

echo '[3/9] Build ClickstreamDW warehouse'
"${SQL[@]}" -i "$ROOT/Database/sql/00_create_database.sql"
"${SQL[@]}" -i "$ROOT/Database/sql/01_etl_procedures.sql"

readarray -t M < <(python3 -c "import json;m=json.load(open('$MAN'));print(m['rows_verified']);print(m['canonical_csv']['sha256']);print(m['canonical_csv']['bytes'])")
ROWS="${M[0]}"; SHA="${M[1]}"; BYTES="${M[2]}"

echo '[4/9] Configure ETL runtime'
"${SQL[@]}" -d ClickstreamDW -Q "
UPDATE etl.RuntimeConfig SET ConfigValue=N'$SCSV' WHERE ConfigKey=N'SourceCsvPath';
UPDATE etl.RuntimeConfig SET ConfigValue=N'$ROWS' WHERE ConfigKey=N'ExpectedSourceRows';
UPDATE etl.RuntimeConfig SET ConfigValue=N'$SHA' WHERE ConfigKey=N'SourceSha256';
UPDATE etl.RuntimeConfig SET ConfigValue=N'$BYTES' WHERE ConfigKey=N'SourceBytes';"

echo '[5/9] Generate SSIS DTSX'
python3 "$HERE/ssis/build_dtsx.py" --output "$PKG"

echo '[6/9] Run native Linux SSIS'
"$HERE/ssis/run_ssis.sh" "$PKG"

echo '[7/9] Validate warehouse'
"${SQL[@]}" -d ClickstreamDW -Q 'EXEC etl.usp_ReportValidation;' | tee "$ROOT/Database/generated/validation_output.txt"
STATUS=$("${SQL[@]}" -d ClickstreamDW -h -1 -W -Q "SET NOCOUNT ON; SELECT TOP(1) Status FROM etl.ETLBatch ORDER BY BatchId DESC;" | xargs)
[[ "$STATUS" == SUCCEEDED ]] || { echo "[FAIL] ETL status=$STATUS"; exit 1; }
cp -f "$MAN" "$ROOT/Database/generated/source_manifest.json"

echo '[8/9] Export MDF/LDF'
"$ROOT/Database/export_database_files.sh" "$ROOT/Database/generated"

echo '[9/9] Done'
find "$ROOT/Database/generated" -maxdepth 1 -type f -printf '%f %s bytes\n' | sort
printf '[PASS] dataset="UCI Clickstream Data for Online Shopping" rows=%s csv=%s bytes (whole dataset, no sampling)\n' "$ROWS" "$ACT"
