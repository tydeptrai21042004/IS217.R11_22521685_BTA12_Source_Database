#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/../common.sh"; fail=0
check(){ if eval "$2" >/dev/null 2>&1; then printf '[PASS] %-24s\n' "$1"; else printf '[FAIL] %-24s\n' "$1"; fail=1; fi; }
check python3 'command -v python3'
check openpyxl 'python3 -c "import openpyxl"'
check sqlcmd 'sqlcmd_path'
check dtexec 'dtexec_path'
check sqlservr 'test -x /opt/mssql/bin/sqlservr'
check SSIS 'test -x /opt/ssis/bin/dtexec'
source /etc/os-release; echo "[INFO] OS: $PRETTY_NAME"; grep -qi microsoft /proc/version 2>/dev/null && echo '[INFO] Environment: WSL' || true
exit $fail
