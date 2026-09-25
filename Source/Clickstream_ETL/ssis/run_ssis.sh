#!/usr/bin/env bash
set -Eeuo pipefail

PKG="${1:?package required}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/common.sh"

ensure_sa_password

DTEXEC="$(dtexec_path)"
if [[ -z "${DTEXEC:-}" || ! -x "$DTEXEC" ]]; then
  echo "[FAIL] dtexec not found." >&2
  exit 1
fi

if [[ ! -f "$PKG" ]]; then
  echo "[FAIL] SSIS package not found: $PKG" >&2
  exit 1
fi

# Microsoft dtexec /CONNECTION syntax:
#   /CONN connection_manager_name;"connection string"
#
# The inner quotes are IMPORTANT.  Without them dtexec interprets the
# semicolons inside the SQL Server connection string as separators between
# additional /CONNECTION items, which causes errors such as:
#   Option "Source=localhost;Initial" is not valid.
#
# Bash receives the entire value below as ONE argv entry:
#   ClickstreamDW;"Data Source=localhost;Initial Catalog=...;"
python3 "$HERE/ssis/validate_dtsx.py" "$PKG"

CONN_STRING="Data Source=localhost;Initial Catalog=ClickstreamDW;User ID=sa;Password=${MSSQL_SA_PASSWORD};TrustServerCertificate=True;"
CONN_OVERRIDE="ClickstreamDW;\"${CONN_STRING}\""

echo "[INFO] Running SSIS package with runtime connection override."
echo "[INFO] dtexec: $DTEXEC"
echo "[INFO] package: $PKG"
echo "[INFO] connection manager: ClickstreamDW"
# Never echo the actual connection string because it contains the sa password.

"$DTEXEC" \
  /F "$PKG" \
  /CONN "$CONN_OVERRIDE" \
  /REPORTING E

rc=$?
if [[ "$rc" -ne 0 ]]; then
  echo "[FAIL] dtexec exit code: $rc" >&2
  exit "$rc"
fi

echo "[PASS] Native Linux SSIS package completed."
