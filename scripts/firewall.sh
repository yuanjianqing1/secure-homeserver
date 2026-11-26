#!/usr/bin/env bash
# Firewall: deny all inbound traffic by default; SSH is open only on the
# Tailscale interface (tailscale0).
#
# Usage: sudo ./scripts/firewall.sh [--ssh-port N] [--allow-lan CIDR]... [--open-tailscale-udp] [--yes]
#   --ssh-port N           SSH port (default 22)
#   --allow-lan CIDR       also allow SSH from a LAN subnet (for emergencies; repeatable)
#   --open-tailscale-udp   allow 41641/udp to improve direct P2P connectivity (optional)
#   --yes                  skip confirmation
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

SSH_PORT=22
LAN_CIDRS=()
OPEN_UDP=0
while (($#)); do
  case $1 in
    --ssh-port)           SSH_PORT=${2:?--ssh-port requires a value}; shift 2 ;;
    --allow-lan)          LAN_CIDRS+=("${2:?--allow-lan requires a value}"); shift 2 ;;
    --open-tailscale-udp) OPEN_UDP=1; shift ;;
    -y|--yes)             ASSUME_YES=1; shift ;;
    -h|--help)            print_usage; exit 0 ;;
    *)                    die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ ${SSH_PORT} =~ ^[0-9]+$ ]] || die "Port must be a number: ${SSH_PORT}"
for cidr in "${LAN_CIDRS[@]}"; do
  [[ ${cidr} =~ ^[0-9a-fA-F:.]+/[0-9]{1,3}$ ]] || die "Invalid CIDR: ${cidr}"
done

require_root
warn_if_not_ubuntu
ip link show tailscale0 >/dev/null 2>&1 || die "Interface tailscale0 not found; run setup-tailscale.sh first"
if ! command -v ufw >/dev/null 2>&1; then
  log_info "ufw is not installed; installing..."
  apt_install ufw
fi

# Lockout protection: look for current SSH connections that don't go through Tailscale.
risky=()
while read -r ip; do
  if [[ -z ${ip} ]] || is_tailscale_ip "${ip}" || is_loopback_ip "${ip}"; then
    continue
  fi
  risky+=("${ip}")
done < <(ssh_peer_ips "${SSH_PORT}")

if ((${#risky[@]})); then
  log_warn "Found SSH connections not going through Tailscale: ${risky[*]}"
  log_warn "Once enabled, these addresses cannot open new SSH connections (existing ones usually survive)."
  if ((${#LAN_CIDRS[@]} == 0)); then
    confirm "Continue anyway? (use --allow-lan <CIDR> to keep LAN access)" || die "Cancelled"
  fi
fi

COMMENT="${SH_NAME}"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow in on tailscale0 to any port "${SSH_PORT}" proto tcp comment "${COMMENT}: ssh via tailscale" >/dev/null
log_ok "Allowed: tailscale0 → tcp/${SSH_PORT}"

for cidr in "${LAN_CIDRS[@]}"; do
  ufw allow from "${cidr}" to any port "${SSH_PORT}" proto tcp comment "${COMMENT}: ssh from lan" >/dev/null
  log_ok "Allowed: ${cidr} → tcp/${SSH_PORT}"
done

if ((OPEN_UDP)); then
  ufw allow 41641/udp comment "${COMMENT}: tailscale direct" >/dev/null
  log_ok "Allowed: 41641/udp (Tailscale direct connections)"
fi

# Older rules that open SSH to every source would defeat the restriction above.
mapfile -t exposed < <(ufw show added 2>/dev/null \
  | grep -E "^ufw allow (OpenSSH|${SSH_PORT}|${SSH_PORT}/tcp)$" || true)
if ((${#exposed[@]})); then
  log_warn "Found older rules that open SSH to every source:"
  printf '    %s\n' "${exposed[@]}" >&2
  if confirm "Delete them so SSH is reachable only through Tailscale?"; then
    for line in "${exposed[@]}"; do
      read -r -a parts <<<"${line#ufw }"
      ufw --force delete "${parts[@]}" >/dev/null
      log_ok "Deleted: ${line}"
    done
  else
    log_warn "Keeping the old rules: SSH is still open to every source."
  fi
fi

ufw --force enable >/dev/null
log_ok "ufw enabled"
ufw status verbose
