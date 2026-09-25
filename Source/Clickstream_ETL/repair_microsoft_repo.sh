#!/usr/bin/env bash
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/common.sh"
ensure_sudo_password
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || { echo '[FAIL] Ubuntu required'; exit 1; }
UBU="${VERSION_ID:-22.04}"
CODENAME="${VERSION_CODENAME:-jammy}"
case "$UBU" in
  20.04) [[ -n "$CODENAME" ]] || CODENAME=focal ;;
  22.04) [[ -n "$CODENAME" ]] || CODENAME=jammy ;;
  *) echo "[FAIL] Unsupported Ubuntu version: $UBU"; exit 1 ;;
esac

echo '[INFO] Removing stale BTA12 Microsoft repository files.'
sudo_run rm -f \
  /etc/apt/sources.list.d/mssql-server-2022.list \
  /etc/apt/sources.list.d/mssql-release.list \
  /etc/apt/sources.list.d/microsoft-prod.list

# Needed tools normally exist already; if not, Ubuntu repos are now usable.
sudo_env DEBIAN_FRONTEND=noninteractive apt-get update
sudo_env DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates gnupg

A="$(mktemp)"; G="$(mktemp)"; trap 'rm -f "$A" "$G"' EXIT
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc -o "$A"
if ! gpg --show-keys --with-colons "$A" 2>/dev/null | grep -qi 'BC528686B50D79E339D3721CEB3E94ADBE1229CF'; then
  echo '[FAIL] Microsoft signing key fingerprint mismatch.' >&2
  exit 1
fi
gpg --batch --yes --dearmor -o "$G" "$A"
sudo_run install -o root -g root -m 0644 "$A" /etc/apt/trusted.gpg.d/microsoft.asc
sudo_run install -o root -g root -m 0644 "$G" /usr/share/keyrings/microsoft-prod.gpg

printf 'deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/%s/mssql-server-2022 %s main\n' "$UBU" "$CODENAME" > /tmp/mssql-server-2022.list
printf 'deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/%s/prod %s main\n' "$UBU" "$CODENAME" > /tmp/mssql-release.list
sudo_run install -o root -g root -m 0644 /tmp/mssql-server-2022.list /etc/apt/sources.list.d/mssql-server-2022.list
sudo_run install -o root -g root -m 0644 /tmp/mssql-release.list /etc/apt/sources.list.d/mssql-release.list
rm -f /tmp/mssql-server-2022.list /tmp/mssql-release.list

sudo_env DEBIAN_FRONTEND=noninteractive apt-get update

echo '[PASS] Microsoft APT repository repaired.'
for p in mssql-server mssql-server-is mssql-tools18; do
  apt-cache policy "$p" | sed -n '1,5p'
done
