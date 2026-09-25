#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/../Source/NYC311_ETL/common.sh"; OUT="${1:-$HERE/generated}"; mkdir -p "$OUT"; ensure_sa_password; SQLCMD="$(sqlcmd_path)"; Q=("$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W)
mapfile -t FILES < <("${Q[@]}" -Q "SET NOCOUNT ON; SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(N'NYC311_DW') ORDER BY file_id;" | sed '/^$/d')
[[ ${#FILES[@]} -ge 2 ]] || { echo '[FAIL] MDF/LDF not found' >&2; exit 1; }
"${Q[@]}" -Q "ALTER DATABASE [NYC311_DW] SET OFFLINE WITH ROLLBACK IMMEDIATE;"; restore(){ "${Q[@]}" -Q "ALTER DATABASE [NYC311_DW] SET ONLINE;" >/dev/null 2>&1 || true; }; trap restore EXIT
for f in "${FILES[@]}"; do f="$(echo "$f"|xargs)"; sudo_run cp -f "$f" "$OUT/"; sudo_run chown "$(id -u):$(id -g)" "$OUT/$(basename "$f")"; done
restore; trap - EXIT; echo "[PASS] Exported MDF/LDF to $OUT"
