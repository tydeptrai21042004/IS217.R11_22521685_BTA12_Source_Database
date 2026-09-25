#!/usr/bin/env bash
set -Eeuo pipefail
OUT="${1:?output directory required}"
mkdir -p "$OUT"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../Source/Clickstream_ETL" && pwd)"
source "$ROOT/common.sh"
ensure_sa_password
SQLCMD="$(sqlcmd_path)"
SQL=("$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -h -1 -W)

mapfile -t FILES < <("${SQL[@]}" -Q "SET NOCOUNT ON; SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(N'ClickstreamDW') ORDER BY file_id;" | sed '/^$/d')
((${#FILES[@]}>=2)) || { echo '[WARN] Could not resolve database files'; exit 0; }

"${SQL[@]}" -Q "ALTER DATABASE [ClickstreamDW] SET OFFLINE WITH ROLLBACK IMMEDIATE;"
trap '"${SQL[@]}" -Q "ALTER DATABASE [ClickstreamDW] SET ONLINE;" >/dev/null 2>&1 || true' EXIT

for f in "${FILES[@]}"; do
  sudo_run cp -f "$f" "$OUT/"
  sudo_run chown "$(id -u):$(id -g)" "$OUT/$(basename "$f")"
done

"${SQL[@]}" -Q "ALTER DATABASE [ClickstreamDW] SET ONLINE;"
trap - EXIT
echo "[PASS] MDF/LDF copied to $OUT"
