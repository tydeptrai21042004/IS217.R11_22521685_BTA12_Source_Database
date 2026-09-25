#!/usr/bin/env bash
set -Eeuo pipefail
BTA12_CONFIG_DIR="${HOME}/.config/bta12"
mkdir -p "$BTA12_CONFIG_DIR"; chmod 700 "$BTA12_CONFIG_DIR" 2>/dev/null || true
if [[ -z "${BTA12_SUDO_PASSWORD:-}" && -f "$BTA12_CONFIG_DIR/sudo_password" ]]; then BTA12_SUDO_PASSWORD="$(cat "$BTA12_CONFIG_DIR/sudo_password")"; fi
ensure_sudo_password(){
  if [[ "${EUID}" -eq 0 ]] || sudo -n true 2>/dev/null; then return 0; fi
  if [[ -n "${BTA12_SUDO_PASSWORD:-}" ]]; then return 0; fi
  if [[ -t 0 ]]; then
    read -r -s -p "[sudo] password for ${USER}: " BTA12_SUDO_PASSWORD
    echo
    export BTA12_SUDO_PASSWORD
    if ! printf '%s\n' "$BTA12_SUDO_PASSWORD" | sudo -S -p '' -v >/dev/null 2>&1; then
      unset BTA12_SUDO_PASSWORD
      echo '[FAIL] Invalid sudo password.' >&2
      return 1
    fi
  fi
}
sudo_run(){ ensure_sudo_password || return 1; if [[ "${EUID}" -eq 0 ]]; then "$@"; elif sudo -n true 2>/dev/null; then sudo "$@"; elif [[ -n "${BTA12_SUDO_PASSWORD:-}" ]]; then printf '%s\n' "$BTA12_SUDO_PASSWORD" | sudo -S -p '' "$@"; else sudo "$@"; fi; }
sudo_env(){ ensure_sudo_password || return 1; if [[ "${EUID}" -eq 0 ]]; then env "$@"; elif sudo -n true 2>/dev/null; then sudo env "$@"; elif [[ -n "${BTA12_SUDO_PASSWORD:-}" ]]; then printf '%s\n' "$BTA12_SUDO_PASSWORD" | sudo -S -p '' env "$@"; else sudo env "$@"; fi; }
sqlcmd_path(){ command -v sqlcmd 2>/dev/null || { [[ -x /opt/mssql-tools18/bin/sqlcmd ]] && echo /opt/mssql-tools18/bin/sqlcmd; } || { [[ -x /opt/mssql-tools/bin/sqlcmd ]] && echo /opt/mssql-tools/bin/sqlcmd; }; }
dtexec_path(){ command -v dtexec 2>/dev/null || { [[ -x /opt/ssis/bin/dtexec ]] && echo /opt/ssis/bin/dtexec; }; }
ensure_sa_password(){
  if [[ -n "${MSSQL_SA_PASSWORD:-}" ]]; then return 0; fi
  local f="$BTA12_CONFIG_DIR/sa_password"
  if [[ -f "$f" ]]; then MSSQL_SA_PASSWORD="$(cat "$f")"; export MSSQL_SA_PASSWORD; return 0; fi
  MSSQL_SA_PASSWORD="$(python3 -c "import secrets; print('Bta12!'+secrets.token_urlsafe(18))")"
  printf '%s' "$MSSQL_SA_PASSWORD" > "$f"; chmod 600 "$f"; export MSSQL_SA_PASSWORD
  echo "[INFO] Generated SQL Server sa password at $f (mode 600)."
}
start_sql_server_if_needed(){
  pgrep -x sqlservr >/dev/null 2>&1 && return 0
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files mssql-server.service >/dev/null 2>&1; then sudo_run systemctl start mssql-server 2>/dev/null && return 0; fi
  echo "[INFO] systemd unavailable; starting sqlservr directly (WSL fallback)."
  sudo_run mkdir -p /var/opt/mssql/log; sudo_run chown -R mssql:mssql /var/opt/mssql
  if [[ "${EUID}" -eq 0 ]]; then su -s /bin/bash -c 'nohup /opt/mssql/bin/sqlservr >/var/opt/mssql/log/sqlservr-bta12.log 2>&1 &' mssql
  elif sudo -n true 2>/dev/null; then sudo -u mssql bash -lc 'nohup /opt/mssql/bin/sqlservr >/var/opt/mssql/log/sqlservr-bta12.log 2>&1 &'
  elif [[ -n "${BTA12_SUDO_PASSWORD:-}" ]]; then printf '%s\n' "$BTA12_SUDO_PASSWORD" | sudo -S -p '' -u mssql bash -lc 'nohup /opt/mssql/bin/sqlservr >/var/opt/mssql/log/sqlservr-bta12.log 2>&1 &'
  else sudo -u mssql bash -lc 'nohup /opt/mssql/bin/sqlservr >/var/opt/mssql/log/sqlservr-bta12.log 2>&1 &'; fi
}
wait_for_sql(){
  ensure_sa_password; local sqlcmd="$(sqlcmd_path)"; local i
  for i in $(seq 1 90); do if "$sqlcmd" -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -l 2 -Q 'SET NOCOUNT ON; SELECT 1;' >/dev/null 2>&1; then echo '[PASS] SQL Server is ready.'; return 0; fi; sleep 2; done
  echo '[FAIL] SQL Server did not become ready. Check /var/opt/mssql/log/errorlog' >&2; return 1
}
