#!/usr/bin/env bash
# Prepare a laptop to run as an always-on server: disable sleep and hibernation,
# ignore the lid switch, and turn off Wi-Fi power saving.
#
# Usage: sudo ./scripts/server-mode.sh [--keep-wifi-powersave] [--yes]
#   --keep-wifi-powersave   leave Wi-Fi power saving untouched
#   --yes                   skip confirmation
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

KEEP_WIFI=0
while (($#)); do
  case $1 in
    --keep-wifi-powersave) KEEP_WIFI=1; shift ;;
    -y|--yes)              ASSUME_YES=1; shift ;;
    -h|--help)             print_usage; exit 0 ;;
    *)                     die "Unknown option: $1 (see --help)" ;;
  esac
done

require_root
warn_if_not_ubuntu

# 1. Block sleep at the system level: no program's suspend request will take effect.
SLEEP_TARGETS=(sleep.target suspend.target hibernate.target hybrid-sleep.target)
systemctl mask "${SLEEP_TARGETS[@]}" >/dev/null 2>&1
log_ok "Masked: ${SLEEP_TARGETS[*]}"

# 2. Lid close, the sleep key and idle time trigger no action.
LOGIND_DROPIN="/etc/systemd/logind.conf.d/10-${SH_NAME}.conf"
mkdir -p "$(dirname "${LOGIND_DROPIN}")"
cat >"${LOGIND_DROPIN}" <<EOF
# Managed by ${SH_NAME} (scripts/server-mode.sh). Revert: sudo ./scripts/rollback.sh server-mode
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
log_ok "Wrote ${LOGIND_DROPIN} (takes effect after reboot)"

# 3. Wi-Fi power saving can drop the connection when idle.
WIFI_UNIT="${SH_NAME}-wifi-powersave-off.service"
NM_CONF="/etc/NetworkManager/conf.d/99-${SH_NAME}-wifi-powersave.conf"
mapfile -t wifi_ifaces < <(
  for d in /sys/class/net/*/wireless; do
    if [[ -e ${d} ]]; then basename "$(dirname "${d}")"; fi
  done
)

if ((KEEP_WIFI)); then
  log_info "Skipping Wi-Fi power saving settings"
elif ((${#wifi_ifaces[@]} == 0)); then
  log_info "No wireless interface found; skipping Wi-Fi settings"
else
  command -v iw >/dev/null 2>&1 || apt_install iw
  # In systemd units, $$ is a literal $
  cat >"/etc/systemd/system/${WIFI_UNIT}" <<'EOF'
[Unit]
Description=Disable Wi-Fi power saving (secure-homeserver)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in /sys/class/net/*/wireless; do [ -e "$$d" ] || continue; i=$$(basename "$$(dirname "$$d")"); iw dev "$$i" set power_save off; done'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "${WIFI_UNIT}" >/dev/null 2>&1
  if [[ -d /etc/NetworkManager/conf.d ]]; then
    printf '[connection]\nwifi.powersave = 2\n' >"${NM_CONF}"
    log_ok "Wrote ${NM_CONF}"
  fi
  for i in "${wifi_ifaces[@]}"; do
    log_ok "${i}: $(iw dev "${i}" get power_save 2>/dev/null || echo 'status unknown')"
  done
fi

cat <<'EOF'

Done. Reboot once so the logind settings take effect: sudo reboot
Verify: systemctl is-enabled suspend.target   # should print "masked"
EOF
