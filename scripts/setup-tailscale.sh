#!/usr/bin/env bash
# Install Tailscale and join this machine to the tailnet. Tailscale SSH is turned
# off; SSH is left to OpenSSH.
#
# Usage: sudo ./scripts/setup-tailscale.sh [--hostname NAME] [--tag tag:server] [--yes]
#   --hostname NAME   name this machine shows in the tailnet
#   --tag TAG         request an ACL tag (e.g. tag:server; must be allowed by tagOwners)
#   --yes             skip all confirmations
# Unattended: pass the auth key via the environment only, so it stays out of shell history:
#   sudo TS_AUTHKEY=tskey-xxxx ./scripts/setup-tailscale.sh
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

HOSTNAME_OPT=""
TAG_OPT=""
while (($#)); do
  case $1 in
    --hostname) HOSTNAME_OPT=${2:?--hostname requires a value}; shift 2 ;;
    --tag)      TAG_OPT=${2:?--tag requires a value}; shift 2 ;;
    -y|--yes)   ASSUME_YES=1; shift ;;
    -h|--help)  print_usage; exit 0 ;;
    *)          die "Unknown option: $1 (see --help)" ;;
  esac
done

if [[ -n ${TAG_OPT} && ! ${TAG_OPT} =~ ^tag:[A-Za-z0-9-]+$ ]]; then
  die "Tags must look like tag:name, e.g. tag:server"
fi

require_root
warn_if_not_ubuntu

# 1. Make sure OpenSSH is available first: with Tailscale SSH off, it owns port 22.
if ! dpkg -s openssh-server >/dev/null 2>&1; then
  log_info "openssh-server is not installed; installing..."
  apt_install openssh-server
fi
if ssh_is_running; then
  log_ok "OpenSSH is running"
else
  systemctl enable --now ssh
  log_ok "Started OpenSSH"
fi

# 2. Install Tailscale (official script; adds Tailscale's apt repository)
if command -v tailscale >/dev/null 2>&1; then
  log_ok "Tailscale already installed: $(tailscale version | head -n1)"
else
  confirm "Install Tailscale via https://tailscale.com/install.sh?" || die "Cancelled"
  require_cmd curl
  curl -fsSL https://tailscale.com/install.sh | sh
fi
systemctl enable --now tailscaled >/dev/null 2>&1

# 3. Log in or update settings
state=$(tailscale status --json 2>/dev/null \
  | grep -o '"BackendState": *"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/' || true)

up_args=(--ssh=false)
if [[ -n ${HOSTNAME_OPT} ]]; then
  up_args+=("--hostname=${HOSTNAME_OPT}")
fi

if [[ ${state} == Running ]]; then
  log_info "This machine is already in the tailnet; only updating settings."
  log_warn "If you are logged in through Tailscale SSH, turning it off may drop your session; reconnect with OpenSSH afterwards."
  confirm "Turn off Tailscale SSH and apply settings?" || die "Cancelled"
  tailscale set "${up_args[@]}"
  if [[ -n ${TAG_OPT} ]]; then
    log_info "Requesting tag ${TAG_OPT} (you may need to re-authenticate in a browser)"
    tailscale up --reset "${up_args[@]}" "--advertise-tags=${TAG_OPT}"
  fi
else
  if [[ -n ${TAG_OPT} ]]; then
    up_args+=("--advertise-tags=${TAG_OPT}")
  fi
  if [[ -n ${TS_AUTHKEY:-} ]]; then
    up_args+=("--auth-key=${TS_AUTHKEY}")
  else
    log_info "A login URL will be printed next; open it in a browser and authorize this machine."
  fi
  tailscale up "${up_args[@]}"
fi

# 4. Result
log_ok "Tailscale IPv4: $(tailscale ip -4 2>/dev/null | head -n1 || echo unknown)"
cat <<'EOF'

Next steps:
  1. In the Tailscale admin console, enable "Disable key expiry" for this machine
     (tagged devices don't expire by default).
  2. Test the connection from another device: tailscale ping <this-machine>
  3. Add your client's SSH public key to ~/.ssh/authorized_keys, then run:
     sudo ./scripts/harden-ssh.sh
EOF
