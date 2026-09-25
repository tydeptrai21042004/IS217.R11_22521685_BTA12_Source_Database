#!/usr/bin/env bash
set -Eeuo pipefail

# Microsoft currently documents SQL Server 2022 SSIS (mssql-server-is) on Ubuntu 20.04.
# This installer therefore refuses unsupported Ubuntu versions rather than forcing packages.

if [[ "${EUID}" -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

if [[ ! -r /etc/os-release ]]; then
  echo "[FAIL] /etc/os-release not found. This setup script targets Ubuntu 20.04." >&2
  exit 1
fi
# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "20.04" ]]; then
  echo "[FAIL] Full native SSIS setup is pinned to Ubuntu 20.04." >&2
  echo "       Detected: ${PRETTY_NAME:-unknown Linux}." >&2
  echo "       Use an Ubuntu 20.04 VM/host for Microsoft-supported SQL Server 2022 SSIS." >&2
  echo "       Do not use a container for SSIS; Microsoft does not support SSIS-in-container installation." >&2
  exit 2
fi

: "${MSSQL_SA_PASSWORD:?Export MSSQL_SA_PASSWORD first (strong SQL Server SA password)}"

$SUDO apt-get update
$SUDO apt-get install -y curl ca-certificates gnupg software-properties-common python3

# Microsoft signing key and SQL Server 2022 repository.
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | $SUDO tee /etc/apt/trusted.gpg.d/microsoft.asc >/dev/null
$SUDO add-apt-repository -y "$(curl -fsSL https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2022.list)"

# Tools repository for sqlcmd 18.
curl -fsSL https://packages.microsoft.com/config/ubuntu/20.04/prod.list | $SUDO tee /etc/apt/sources.list.d/mssql-release.list >/dev/null
$SUDO apt-get update

if ! dpkg -s mssql-server >/dev/null 2>&1; then
  $SUDO apt-get install -y mssql-server
fi

if [[ ! -f /var/opt/mssql/mssql.conf ]]; then
  echo "[INFO] Configuring SQL Server Developer edition non-interactively"
  $SUDO env MSSQL_PID=Developer ACCEPT_EULA=Y MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" \
    /opt/mssql/bin/mssql-conf -n setup
else
  echo "[INFO] SQL Server appears already configured"
fi

$SUDO systemctl enable --now mssql-server

$SUDO env ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
if ! dpkg -s mssql-server-is >/dev/null 2>&1; then
  $SUDO apt-get install -y mssql-server-is
fi

# Configure SSIS if dtexec is not yet available.
if [[ ! -x /opt/ssis/bin/dtexec ]]; then
  $SUDO env SSIS_PID=Developer ACCEPT_EULA=Y /opt/ssis/bin/ssis-conf -n setup
fi

cat <<'EOF'

[PASS] Linux prerequisites installed/configured.
Add these to your shell profile if desired:
  export PATH=/opt/mssql-tools18/bin:/opt/ssis/bin:$PATH

Then run:
  ./run_all.sh
EOF
