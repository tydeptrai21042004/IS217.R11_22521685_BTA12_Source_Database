#!/usr/bin/env bash
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
ensure_sa_password

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || { echo '[FAIL] Ubuntu required'; exit 1; }
case "${VERSION_ID:-}" in
  20.04|22.04) ;;
  *) echo "[FAIL] Use Ubuntu 20.04 or 22.04; detected ${PRETTY_NAME:-unknown}"; exit 1 ;;
esac
UBU="$VERSION_ID"
CODENAME="${VERSION_CODENAME:-}"
if [[ -z "$CODENAME" ]]; then
  case "$UBU" in 20.04) CODENAME=focal;; 22.04) CODENAME=jammy;; esac
fi

echo "[INFO] Installing for $PRETTY_NAME"
grep -qi microsoft /proc/version 2>/dev/null && echo '[INFO] WSL detected.' || true

# ---------------------------------------------------------------------------
# Repair stale/broken Microsoft repository definitions BEFORE apt-get update.
# The previous project could leave these files pointing at packages.microsoft.com
# without a usable key, which causes apt update to fail with:
# NO_PUBKEY EB3E94ADBE1229CF
# ---------------------------------------------------------------------------
echo '[INFO] Repairing Microsoft APT repository/key configuration.'
sudo_run rm -f \
  /etc/apt/sources.list.d/mssql-server-2022.list \
  /etc/apt/sources.list.d/mssql-release.list \
  /etc/apt/sources.list.d/microsoft-prod.list

# With our broken entries removed, Ubuntu repositories can be refreshed safely.
sudo_env DEBIAN_FRONTEND=noninteractive apt-get update
sudo_env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  curl ca-certificates gnupg software-properties-common python3 python3-openpyxl

# Install Microsoft's legacy signing key in BOTH forms:
# 1) global trusted key (matches current Microsoft Ubuntu docs), and
# 2) a dedicated binary keyring used by explicit signed-by entries below.
TMP_ASC="$(mktemp)"
TMP_GPG="$(mktemp)"
trap 'rm -f "$TMP_ASC" "$TMP_GPG"' EXIT
curl --fail --show-error --silent --location \
  https://packages.microsoft.com/keys/microsoft.asc \
  -o "$TMP_ASC"

# Verify we really downloaded Microsoft's package signing key.
# Capture output first so `pipefail` cannot turn a successful fingerprint
# match into a false failure through SIGPIPE.
KEY_INFO="$(gpg --show-keys --with-colons "$TMP_ASC" 2>/dev/null || true)"
if [[ "$KEY_INFO" != *"BC528686B50D79E339D3721CEB3E94ADBE1229CF"* ]]; then
  echo '[FAIL] Downloaded Microsoft signing key has an unexpected fingerprint.' >&2
  exit 1
fi

gpg --batch --yes --dearmor -o "$TMP_GPG" "$TMP_ASC"
sudo_run install -o root -g root -m 0644 "$TMP_ASC" /etc/apt/trusted.gpg.d/microsoft.asc
sudo_run install -o root -g root -m 0644 "$TMP_GPG" /usr/share/keyrings/microsoft-prod.gpg

# Create deterministic repository files ourselves. This avoids ambiguity about
# whether a downloaded .list file expects the global trusted store or signed-by.
cat > /tmp/mssql-server-2022.list <<EOF_REPO
deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${UBU}/mssql-server-2022 ${CODENAME} main
EOF_REPO
cat > /tmp/mssql-release.list <<EOF_REPO
deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/${UBU}/prod ${CODENAME} main
EOF_REPO
sudo_run install -o root -g root -m 0644 /tmp/mssql-server-2022.list /etc/apt/sources.list.d/mssql-server-2022.list
sudo_run install -o root -g root -m 0644 /tmp/mssql-release.list /etc/apt/sources.list.d/mssql-release.list
rm -f /tmp/mssql-server-2022.list /tmp/mssql-release.list

# Confirm the key is visible before touching package metadata.
echo '[INFO] Microsoft key fingerprint:'
gpg --show-keys --with-fingerprint /usr/share/keyrings/microsoft-prod.gpg 2>/dev/null | sed -n '1,8p'

# Clean old failed package indexes so apt cannot reuse a stale unsigned result.
sudo_run rm -rf /var/lib/apt/lists/partial
sudo_run mkdir -p /var/lib/apt/lists/partial

echo '[INFO] Refreshing package metadata with repaired Microsoft keyring.'
sudo_env DEBIAN_FRONTEND=noninteractive apt-get update

# Make sure apt sees the packages before attempting a large install.
# IMPORTANT: do not pipe `apt-cache policy` into `grep -q` while `pipefail`
# is enabled. grep exits immediately after its first match, which can send
# SIGPIPE to apt-cache and incorrectly make a successful lookup look failed.
apt_candidate() {
  local pkg="$1" policy candidate
  policy="$(apt-cache policy "$pkg" 2>&1 || true)"
  candidate="$(awk '/^[[:space:]]*Candidate:/ { print $2; exit }' <<<"$policy")"
  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    echo "[FAIL] No installation candidate for: $pkg" >&2
    printf '%s\n' "$policy" >&2
    return 1
  fi
  echo "[PASS] APT candidate: $pkg=$candidate"
}

for pkg in mssql-server mssql-server-is mssql-tools18; do
  apt_candidate "$pkg"
done

sudo_env ACCEPT_EULA=Y DEBIAN_FRONTEND=noninteractive apt-get install -y \
  mssql-server mssql-server-is mssql-tools18 unixodbc-dev

# Keep sqlcmd discoverable in the current and future shells.
export PATH="/opt/mssql-tools18/bin:/opt/ssis/bin:$PATH"
if [[ -d "$HOME" && -w "$HOME" ]]; then
  grep -qxF 'export PATH="$PATH:/opt/mssql-tools18/bin:/opt/ssis/bin"' "$HOME/.bashrc" 2>/dev/null || \
    printf '\nexport PATH="$PATH:/opt/mssql-tools18/bin:/opt/ssis/bin"\n' >> "$HOME/.bashrc"
fi

if [[ ! -f /var/opt/mssql/data/master.mdf ]]; then
  echo '[INFO] Configuring SQL Server Developer Edition unattended.'
  sudo_env MSSQL_PID=Developer ACCEPT_EULA=Y MSSQL_SA_PASSWORD="$MSSQL_SA_PASSWORD" \
    /opt/mssql/bin/mssql-conf -n setup
else
  echo '[INFO] Existing SQL Server database detected; preserving its existing system databases.'
fi

echo '[INFO] Configuring SSIS Developer Edition unattended.'
sudo_env SSIS_PID=Developer ACCEPT_EULA=Y /opt/ssis/bin/ssis-conf -n setup

start_sql_server_if_needed
wait_for_sql
SQLCMD="$(sqlcmd_path)"
DTEXEC="$(dtexec_path)"
"$SQLCMD" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -Q 'SELECT @@VERSION;' | head -n 8
"$DTEXEC" /? >/dev/null 2>&1 || true

echo "[PASS] Installed. sqlcmd=$SQLCMD dtexec=$DTEXEC"
