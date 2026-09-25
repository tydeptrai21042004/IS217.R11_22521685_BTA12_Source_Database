#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/common.sh"

fail=0
for c in python3; do
  if command -v "$c" >/dev/null 2>&1; then
    printf '[PASS] %-25s\n' "$c"
  else
    printf '[FAIL] %-25s\n' "$c"
    fail=1
  fi
done

if sqlcmd_path >/dev/null 2>&1; then printf '[PASS] %-25s\n' sqlcmd; else printf '[FAIL] %-25s\n' sqlcmd; fail=1; fi
if dtexec_path >/dev/null 2>&1; then printf '[PASS] %-25s\n' dtexec; else printf '[FAIL] %-25s\n' dtexec; fail=1; fi
[[ -x /opt/mssql/bin/sqlservr ]] && printf '[PASS] %-25s\n' sqlservr || { printf '[FAIL] %-25s\n' sqlservr; fail=1; }
[[ -x /opt/ssis/bin/dtexec ]] && printf '[PASS] %-25s\n' SSIS || { printf '[FAIL] %-25s\n' SSIS; fail=1; }

. /etc/os-release
echo "[INFO] OS: ${PRETTY_NAME:-unknown}"
if grep -qi microsoft /proc/version 2>/dev/null; then echo '[INFO] Environment: WSL'; else echo '[INFO] Environment: Linux'; fi
exit "$fail"
