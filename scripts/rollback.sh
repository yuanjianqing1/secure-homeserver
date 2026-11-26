#!/usr/bin/env bash
# Undo the changes this project made to the system. With no components given,
# everything is undone. Tailscale itself is not uninstalled.
#
# Usage: sudo ./scripts/rollback.sh [ssh] [firewall] [server-mode] [timer] [--yes]
#   ssh           remove the SSH hardening drop-in
#   firewall      remove the ufw rules added by this project (without locking out SSH)
#   server-mode   restore default sleep, lid and Wi-Fi power saving behavior
#   timer         remove the scheduled health check
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

COMPONENTS=()
while (($#)); do
  case $1 in
    ssh|firewall|server-mode|timer) COMPONENTS+=("$1"); shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *)         die "Unknown option: $1 (see --help)" ;;
  esac
done
if ((${#COMPONENTS[@]} == 0)); then
  COMPONENTS=(ssh firewall server-mode timer)
fi

require_root
confirm "Will undo: ${COMPONENTS[*]}. Continue?" || die "Cancelled"

rollback_ssh() {
  local f="/etc/ssh/sshd_config.d/10-${SH_NAME}.conf"
  if [[ ! -e ${f} ]]; then
    log_info "ssh: nothing to undo"
    return
  fi
  rm -f "${f}"
  mkdir -p /run/sshd
  sshd -t || die "sshd config test failed after removal; check /etc/ssh/sshd_config.d/"
  systemctl try-reload-or-restart ssh
  log_ok "ssh: removed ${f}; settings now come from the rest of the system config"
}

rollback_firewall() {
  local line rule
  local -a ours parts
  if ! command -v ufw >/dev/null 2>&1; then
    log_info "firewall: ufw not installed; skipping"
    return
  fi
  mapfile -t ours < <(ufw show added 2>/dev/null | grep "comment '${SH_NAME}" || true)
  for line in "${ours[@]}"; do
    rule=${line#ufw }
    rule=${rule% comment *}
    read -r -a parts <<<"${rule}"
    ufw --force delete "${parts[@]}" >/dev/null
    log_ok "firewall: deleted ${rule}"
  done
  if ((${#ours[@]} == 0)); then
    log_info "firewall: no rules added by this project"
  fi

  # Lockout protection: ufw is still active but no rule allows SSH any more.
  if LC_ALL=C ufw status | grep -q '^Status: active' \
     && ! ufw show added | grep -Eq '^ufw allow .*(OpenSSH|\b22\b)'; then
    log_warn "ufw is still active but no rule allows SSH; new SSH connections will be refused."
    if confirm "Disable ufw? (answer N to allow OpenSSH from every source instead)"; then
      ufw --force disable >/dev/null
      log_ok "firewall: ufw disabled"
    else
      ufw allow OpenSSH >/dev/null
      log_ok "firewall: OpenSSH allowed"
    fi
  fi
}

rollback_server_mode() {
  local wifi_unit="${SH_NAME}-wifi-powersave-off.service"
  systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1
  rm -f "/etc/systemd/logind.conf.d/10-${SH_NAME}.conf"
  if [[ -e /etc/systemd/system/${wifi_unit} ]]; then
    systemctl disable --now "${wifi_unit}" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${wifi_unit}"
  fi
  rm -f "/etc/NetworkManager/conf.d/99-${SH_NAME}-wifi-powersave.conf"
  systemctl daemon-reload
  log_ok "server-mode: default power behavior restored (fully effective after reboot)"
}

rollback_timer() {
  local unit="${SH_NAME}-healthcheck"
  systemctl disable --now "${unit}.timer" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/${unit}.timer" "/etc/systemd/system/${unit}.service" \
        "/usr/local/sbin/${SH_NAME}-healthcheck"
  systemctl daemon-reload
  log_ok "timer: scheduled health check removed"
}

for c in "${COMPONENTS[@]}"; do
  case ${c} in
    ssh)         rollback_ssh ;;
    firewall)    rollback_firewall ;;
    server-mode) rollback_server_mode ;;
    timer)       rollback_timer ;;
  esac
done

cat <<'EOF'

Tailscale was left untouched. To disconnect or uninstall it:
  sudo tailscale down                                  # disconnect, keep installed
  sudo tailscale logout && sudo apt purge tailscale    # full uninstall (then remove the device in the admin console)
EOF
