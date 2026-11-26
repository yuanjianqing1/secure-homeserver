#!/usr/bin/env bash
# Install a scheduled health check: runs healthcheck.sh as root on a schedule and
# logs the results to the systemd journal.
#
# Usage: sudo ./scripts/install-timer.sh [--peer NAME] [--interval CALENDAR]
#   --peer NAME           device to test with tailscale ping on each run
#   --interval CALENDAR   systemd OnCalendar expression (default: hourly)
# View results: journalctl -u secure-homeserver-healthcheck
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

PEER=""
INTERVAL="hourly"
while (($#)); do
  case $1 in
    --peer)     PEER=${2:?--peer requires a value}; shift 2 ;;
    --interval) INTERVAL=${2:?--interval requires a value}; shift 2 ;;
    -h|--help)  print_usage; exit 0 ;;
    *)          die "Unknown option: $1 (see --help)" ;;
  esac
done

if [[ -n ${PEER} && ! ${PEER} =~ ^[A-Za-z0-9._-]+$ ]]; then
  die "Device names may contain only letters, digits, dots, underscores and hyphens"
fi

require_root
systemd-analyze calendar "${INTERVAL}" >/dev/null 2>&1 || die "Invalid OnCalendar expression: ${INTERVAL}"

BIN="/usr/local/sbin/${SH_NAME}-healthcheck"
UNIT="${SH_NAME}-healthcheck"
install -m 0755 "${SCRIPT_DIR}/healthcheck.sh" "${BIN}"

peer_arg=""
if [[ -n ${PEER} ]]; then
  peer_arg=" --peer ${PEER}"
fi

cat >"/etc/systemd/system/${UNIT}.service" <<EOF
# Managed by ${SH_NAME} (scripts/install-timer.sh)
[Unit]
Description=${SH_NAME} health check
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BIN} --quiet${peer_arg}
# Exit code 1 means warnings only and is not a failure; 2 means failures
SuccessExitStatus=1
EOF

cat >"/etc/systemd/system/${UNIT}.timer" <<EOF
# Managed by ${SH_NAME} (scripts/install-timer.sh)
[Unit]
Description=Run ${SH_NAME} health check (${INTERVAL})

[Timer]
OnCalendar=${INTERVAL}
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "${UNIT}.timer" >/dev/null 2>&1
log_ok "Enabled timer ${UNIT}.timer (${INTERVAL})"

log_info "Running once now..."
systemctl start "${UNIT}.service" || true
journalctl -u "${UNIT}.service" -n 20 --no-pager || true

cat <<EOF

View past results:  journalctl -u ${UNIT}
Next scheduled run: systemctl list-timers ${UNIT}.timer
EOF
