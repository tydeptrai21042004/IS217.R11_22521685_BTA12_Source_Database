#!/usr/bin/env bash
set -Eeuo pipefail

SERVER="${1:-localhost}"
USER_NAME="${2:-sa}"
DATABASE="${3:-NYC311_DW}"
OUTPUT_DIR="${4:-$(pwd)/generated}"

: "${MSSQL_SA_PASSWORD:?Set MSSQL_SA_PASSWORD before running this script}"
export SQLCMDPASSWORD="$MSSQL_SA_PASSWORD"

find_sqlcmd() {
  if command -v sqlcmd >/dev/null 2>&1; then command -v sqlcmd; return; fi
  if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then echo /opt/mssql-tools18/bin/sqlcmd; return; fi
  if [[ -x /opt/mssql-tools/bin/sqlcmd ]]; then echo /opt/mssql-tools/bin/sqlcmd; return; fi
  return 1
}
SQLCMD="$(find_sqlcmd)" || { echo "[FAIL] sqlcmd not found" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR"

mapfile -t DB_FILES < <(
  "$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -h -1 -W -Q \
    "SET NOCOUNT ON; SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(N'$DATABASE') ORDER BY file_id;" \
    | sed '/^[[:space:]]*$/d'
)

if (( ${#DB_FILES[@]} < 2 )); then
  echo "[FAIL] Could not resolve MDF/LDF paths for $DATABASE" >&2
  exit 1
fi

echo "[INFO] Taking $DATABASE offline for a consistent MDF/LDF copy..."
"$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -Q \
  "ALTER DATABASE [$DATABASE] SET OFFLINE WITH ROLLBACK IMMEDIATE;"

online_db() {
  "$SQLCMD" -S "$SERVER" -U "$USER_NAME" -C -b -Q \
    "IF DB_ID(N'$DATABASE') IS NOT NULL ALTER DATABASE [$DATABASE] SET ONLINE;" >/dev/null 2>&1 || true
}
trap online_db EXIT

for file in "${DB_FILES[@]}"; do
  file="$(echo "$file" | xargs)"
  [[ -f "$file" ]] || { echo "[FAIL] Database file not accessible: $file" >&2; exit 1; }
  echo "[COPY] $file -> $OUTPUT_DIR/"
  if [[ -r "$file" ]]; then
    cp -f "$file" "$OUTPUT_DIR/"
  else
    sudo cp -f "$file" "$OUTPUT_DIR/"
    sudo chown "$(id -u):$(id -g)" "$OUTPUT_DIR/$(basename "$file")"
  fi
done

online_db
trap - EXIT

echo "[PASS] MDF/LDF copied to $OUTPUT_DIR"
