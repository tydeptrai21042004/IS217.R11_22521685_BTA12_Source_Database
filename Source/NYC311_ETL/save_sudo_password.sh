#!/usr/bin/env bash
set -Eeuo pipefail
DIR="${HOME}/.config/bta12"; mkdir -p "$DIR"; chmod 700 "$DIR"
read -r -s -p 'Ubuntu sudo password (saved only outside the assignment folder): ' P; echo
printf '%s' "$P" > "$DIR/sudo_password"; chmod 600 "$DIR/sudo_password"; unset P
echo "[PASS] Saved to $DIR/sudo_password (mode 600). Delete with: rm -f '$DIR/sudo_password'"
