#!/usr/bin/env bash
set -Eeuo pipefail
PKG="${1:?package required}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/common.sh"
ensure_sa_password
DTEXEC="$(dtexec_path)"
CONN="Data Source=localhost;Initial Catalog=ClickstreamDW;User ID=sa;Password=${MSSQL_SA_PASSWORD};TrustServerCertificate=True;"
"$DTEXEC" /F "$PKG" /CONNECTION 'ClickstreamDW;'"$CONN" /REPORTING E
