#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DB_ROOT="$REPO_ROOT/Database"
DATA_DIR="$SCRIPT_DIR/data"
MANIFEST_JSON="$DATA_DIR/manifest.json"
MANIFEST_CSV="$DATA_DIR/manifest.csv"
PACKAGE="$SCRIPT_DIR/ssis/00_Master_NYC311_ETL.dtsx"
GENERATED_DB="$DB_ROOT/generated"
VALIDATION_OUT="$GENERATED_DB/validation_output.txt"

SERVER="localhost"
USER_NAME="sa"
START_DATE="2025-01-15"
LOOKBACK_DAYS=45
MAX_BYTES=50000000
INSTALL_DEPS=0
EXPORT_DB=1

usage() {
  cat <<'EOF'
Usage: ./run_all.sh [options]

Options:
  --server HOST             SQL Server host (default: localhost)
  --user USER               SQL login (default: sa)
  --start-date YYYY-MM-DD   Search backwards from this date (default: 2025-01-15)
  --lookback-days N         Number of complete days to consider (default: 45)
  --max-bytes N             Hard CSV cap (default: 50000000 = exactly 50.00 MB decimal)
  --install                 Run setup_linux.sh first if prerequisites are missing
  --no-export-db            Do not offline/copy MDF and LDF at the end
  -h, --help                Show help

Environment:
  MSSQL_SA_PASSWORD         Required. Used for SQL Authentication; never saved in DTSX.
EOF
}

while (( $# )); do
  case "$1" in
    --server) SERVER="$2"; shift 2 ;;
    --user) USER_NAME="$2"; shift 2 ;;
    --start-date) START_DATE="$2"; shift 2 ;;
    --lookback-days) LOOKBACK_DAYS="$2"; shift 2 ;;
    --max-bytes) MAX_BYTES="$2"; shift 2 ;;
    --install) INSTALL_DEPS=1; shift ;;
    --no-export-db) EXPORT_DB=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
  read -rsp 'SQL Server SA password: ' MSSQL_SA_PASSWORD
  echo
  export MSSQL_SA_PASSWORD
fi
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"

find_sqlcmd() {
  if command -v sqlcmd >/dev/null 2>&1; then command -v sqlcmd; return; fi
  if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then echo /opt/mssql-tools18/bin/sqlcmd; return; fi
  if [[ -x /opt/mssql-tools/bin/sqlcmd ]]; then echo /opt/mssql-tools/bin/sqlcmd; return; fi
  return 1
}

if ! "$SCRIPT_DIR/check_prerequisites.sh"; then
  if (( INSTALL_DEPS )); then
    "$SCRIPT_DIR/setup_linux.sh"
  else
    echo "[FAIL] Missing prerequisites. On supported Ubuntu 20.04 run:" >&2
    echo "       ./run_all.sh --install" >&2
    exit 1
  fi
fi

SQLCMD="$(find_sqlcmd)" || { echo '[FAIL] sqlcmd not found' >&2; exit 1; }
mkdir -p "$DATA_DIR" "$GENERATED_DB"

cat <<EOF
============================================================
 IS217.R11 - 22521685 - BTA12 Linux ETL
 SQL Server       : $SERVER
 Search start     : $START_DATE
 Lookback         : $LOOKBACK_DAYS days
 HARD dataset cap : $MAX_BYTES bytes (50 MB default)
============================================================
EOF

echo "[1/9] Auto-select and download a COMPLETE real NYC 311 day <= hard cap"
python3 "$SCRIPT_DIR/automation/download_nyc311.py" \
  --start-date "$START_DATE" \
  --lookback-days "$LOOKBACK_DAYS" \
  --output-dir "$DATA_DIR" \
  --manifest-json "$MANIFEST_JSON" \
  --manifest-csv "$MANIFEST_CSV" \
  --max-bytes "$MAX_BYTES"

LOCAL_CSV="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["file"])' "$MANIFEST_JSON")"
CHOSEN_DATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["selection"]["chosen_date"])' "$MANIFEST_JSON")"
ACTUAL_BYTES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["size_bytes"])' "$MANIFEST_JSON")"
if (( ACTUAL_BYTES > MAX_BYTES )); then
  echo "[FAIL] Dataset-size invariant violated: $ACTUAL_BYTES > $MAX_BYTES" >&2
  exit 1
fi

echo "[2/9] Copy verified CSV where local SQL Server service can read it"
SQL_IMPORT_DIR="/var/opt/mssql/import/nyc311_bta12"
SQL_CSV="$SQL_IMPORT_DIR/nyc311_${CHOSEN_DATE}.csv"
sudo mkdir -p "$SQL_IMPORT_DIR"
sudo install -o mssql -g mssql -m 0640 "$LOCAL_CSV" "$SQL_CSV"

if [[ "$(stat -c %s "$LOCAL_CSV")" -gt "$MAX_BYTES" ]]; then
  echo '[FAIL] Local dataset exceeds hard cap after copy check' >&2; exit 1
fi

echo "[3/9] Create/reset warehouse schema and ETL procedures"
"$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -i "$DB_ROOT/sql/00_create_database.sql"
"$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -i "$DB_ROOT/sql/01_etl_procedures.sql"

echo "[4/9] Configure runtime metadata"
python3 "$SCRIPT_DIR/automation/configure_runtime.py" \
  --server "$SERVER" --user "$USER_NAME" \
  --manifest "$MANIFEST_JSON" --sql-source-path "$SQL_CSV"

echo "[5/9] Generate Linux-runnable DTSX (no stored SQL password)"
python3 "$SCRIPT_DIR/ssis/build_ssis_package.py" --output "$PACKAGE"

echo "[6/9] Execute SSIS with dtexec + SQL Authentication"
python3 "$SCRIPT_DIR/ssis/run_ssis.py" \
  --package "$PACKAGE" --server "$SERVER" --user "$USER_NAME"

echo "[7/9] Run warehouse validation"
"$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -d NYC311_DW \
  -Q "EXEC etl.usp_ReportValidation;" | tee "$VALIDATION_OUT"
"$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -i "$DB_ROOT/sql/02_manual_validation.sql" \
  | tee -a "$VALIDATION_OUT"

echo "[8/9] Verify the selected source is still <= the hard cap"
FINAL_SIZE="$(stat -c %s "$LOCAL_CSV")"
if (( FINAL_SIZE > MAX_BYTES )); then
  echo "[FAIL] Dataset exceeds hard cap: $FINAL_SIZE > $MAX_BYTES" >&2
  exit 1
fi
echo "[PASS] Dataset size: $FINAL_SIZE bytes <= $MAX_BYTES bytes"

if (( EXPORT_DB )); then
  echo "[9/9] Export consistent MDF/LDF copies"
  "$DB_ROOT/export_database_files.sh" "$SERVER" "$USER_NAME" NYC311_DW "$GENERATED_DB"
else
  echo "[9/9] MDF/LDF export skipped (--no-export-db)"
fi

cat <<EOF

============================================================
SUCCESS
Chosen complete day : $CHOSEN_DATE
Dataset             : $LOCAL_CSV
Dataset bytes       : $FINAL_SIZE (hard cap $MAX_BYTES)
Sampling            : NO
Truncation          : NO
Manifest            : $MANIFEST_JSON
SSIS package        : $PACKAGE
Validation          : $VALIDATION_OUT
Database output     : $GENERATED_DB
============================================================
EOF
