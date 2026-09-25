#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; source "$HERE/common.sh"; ensure_sa_password
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || { echo '[FAIL] Ubuntu required'; exit 1; }
case "${VERSION_ID:-}" in 20.04|22.04) ;; *) echo "[FAIL] Use Ubuntu 20.04 or 22.04; detected ${PRETTY_NAME:-unknown}"; exit 1;; esac
UBU="$VERSION_ID"; echo "[INFO] Installing for $PRETTY_NAME"; grep -qi microsoft /proc/version 2>/dev/null && echo '[INFO] WSL detected.' || true
sudo_env DEBIAN_FRONTEND=noninteractive apt-get update
sudo_env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg software-properties-common python3
TMPKEY="$(mktemp)"; curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor > "$TMPKEY"; sudo_run install -m 0644 "$TMPKEY" /usr/share/keyrings/microsoft-prod.gpg; rm -f "$TMPKEY"
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBU}/mssql-server-2022.list" > /tmp/mssql-server-2022.list
sudo_run install -m 0644 /tmp/mssql-server-2022.list /etc/apt/sources.list.d/mssql-server-2022.list
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${UBU}/prod.list" > /tmp/mssql-release.list
sudo_run install -m 0644 /tmp/mssql-release.list /etc/apt/sources.list.d/mssql-release.list
rm -f /tmp/mssql-server-2022.list /tmp/mssql-release.list
sudo_env DEBIAN_FRONTEND=noninteractive apt-get update
sudo_env ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y mssql-server mssql-server-is mssql-tools18 unixodbc-dev
if [[ ! -f /var/opt/mssql/data/master.mdf ]]; then
  echo '[INFO] Configuring SQL Server Developer Edition unattended.'
  sudo_env MSSQL_PID=Developer ACCEPT_EULA=Y MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" /opt/mssql/bin/mssql-conf -n setup
else echo '[INFO] Existing SQL Server database detected; preserving its sa password.'; fi
echo '[INFO] Configuring SSIS Developer Edition unattended.'
sudo_env SSIS_PID=Developer ACCEPT_EULA=Y /opt/ssis/bin/ssis-conf -n setup
start_sql_server_if_needed; wait_for_sql
SQLCMD="$(sqlcmd_path)"; DTEXEC="$(dtexec_path)"
"$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q 'SELECT @@VERSION;' | head -n 8
"$DTEXEC" /? >/dev/null 2>&1 || true
echo "[PASS] Installed. sqlcmd=$SQLCMD dtexec=$DTEXEC"
