#!/usr/bin/env bash
set -u

fail=0
check_cmd() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf '[PASS] %-24s\n' "$name"
  else
    printf '[FAIL] %-24s\n' "$name"
    fail=1
  fi
}

check_cmd "python3" command -v python3
check_cmd "sqlcmd" bash -c 'command -v sqlcmd || [[ -x /opt/mssql-tools18/bin/sqlcmd ]] || [[ -x /opt/mssql-tools/bin/sqlcmd ]]'
check_cmd "dtexec" bash -c 'command -v dtexec || [[ -x /opt/ssis/bin/dtexec ]]'
check_cmd "SQL Server service" systemctl is-active --quiet mssql-server

if [[ -z "${MSSQL_SA_PASSWORD:-}" ]]; then
  echo '[FAIL] MSSQL_SA_PASSWORD environment variable'
  fail=1
else
  echo '[PASS] MSSQL_SA_PASSWORD environment variable'
fi

exit "$fail"
