#!/usr/bin/env bash
# SSH hardening: key-only login, no root login, and only the listed user may log in.
# Settings go into a separate file under /etc/ssh/sshd_config.d/; the stock
# sshd_config is never modified.
#
# Usage: sudo ./scripts/harden-ssh.sh [--user NAME] [--allow-password] [--yes]
#   --user NAME        user allowed to log in over SSH (default: the user running sudo)
#   --allow-password   keep password login; apply the other hardening only
#   --yes              skip confirmation
set -Eeuo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET_USER=${SUDO_USER:-}
ALLOW_PASSWORD=0
while (($#)); do
  case $1 in
    --user)           TARGET_USER=${2:?--user requires a value}; shift 2 ;;
    --allow-password) ALLOW_PASSWORD=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    -h|--help)        print_usage; exit 0 ;;
    *)                die "Unknown option: $1 (see --help)" ;;
  esac
done

require_root
warn_if_not_ubuntu
require_cmd sshd

[[ -n ${TARGET_USER} && ${TARGET_USER} != root ]] \
  || die "Cannot determine the login user; specify it with --user (must not be root)"
id "${TARGET_USER}" >/dev/null 2>&1 || die "No such user: ${TARGET_USER}"

DROPIN="/etc/ssh/sshd_config.d/10-${SH_NAME}.conf"
grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' /etc/ssh/sshd_config \
  || die "/etc/ssh/sshd_config has no 'Include /etc/ssh/sshd_config.d/*.conf'; cannot manage settings via a drop-in file"

# Lockout protection: before disabling passwords, make sure the user has a public key.
home=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
keys="${home}/.ssh/authorized_keys"
key_pattern='(^|[[:space:]])(ssh-(ed25519|rsa|dss)|ecdsa-sha2-|sk-)'
if [[ ${ALLOW_PASSWORD} == 0 ]]; then
  if [[ ! -s ${keys} ]] || ! grep -Eq "${key_pattern}" "${keys}"; then
    die "No public key in ${keys}. Upload your client's public key first (see README), or pass --allow-password."
  fi
  log_ok "${TARGET_USER} has $(grep -Ec "${key_pattern}" "${keys}") public key(s)"
fi

# sshd's StrictModes rejects key files with overly broad permissions; fix them.
if [[ -d ${home}/.ssh ]]; then
  chmod 700 "${home}/.ssh"
  chown "${TARGET_USER}:" "${home}/.ssh"
fi
if [[ -f ${keys} ]]; then
  chmod 600 "${keys}"
  chown "${TARGET_USER}:" "${keys}"
fi

password_value=no
if [[ ${ALLOW_PASSWORD} == 1 ]]; then
  password_value=yes
fi

log_info "Will write ${DROPIN}: only ${TARGET_USER} may log in, PasswordAuthentication=${password_value}"
confirm "Continue?" || die "Cancelled"

tmp=$(mktemp)
prev=""
cleanup() { rm -f "${tmp}" ${prev:+"${prev}"}; }
trap cleanup EXIT

cat >"${tmp}" <<EOF
# Managed by ${SH_NAME} (scripts/harden-ssh.sh). Revert: sudo ./scripts/rollback.sh ssh
# sshd uses the first value it reads for each option; this file sorts early, so it
# takes precedence over other *.conf files.
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication ${password_value}
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers ${TARGET_USER}
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

if [[ -e ${DROPIN} ]]; then
  prev=$(mktemp)
  cp -a "${DROPIN}" "${prev}"
fi
install -m 0644 "${tmp}" "${DROPIN}"

mkdir -p /run/sshd
if ! sshd -t; then
  if [[ -n ${prev} ]]; then
    cp -a "${prev}" "${DROPIN}"
  else
    rm -f "${DROPIN}"
  fi
  die "sshd config test failed; changes reverted"
fi

# Confirm the settings actually take effect (a file that sorts earlier could override them).
effective=$(sshd -T -C "user=${TARGET_USER},host=localhost,addr=127.0.0.1")
for pair in "permitrootlogin no" "pubkeyauthentication yes" "passwordauthentication ${password_value}"; do
  if grep -qix "${pair}" <<<"${effective}"; then
    log_ok "Effective: ${pair}"
  else
    log_warn "Not effective: ${pair} (check files in /etc/ssh/sshd_config.d/ that sort earlier)"
  fi
done

systemctl try-reload-or-restart ssh
log_ok "sshd reloaded"

cat <<EOF

IMPORTANT: do not close your current SSH session yet! Test from a new window:
  1. Key login should succeed:       ssh ${TARGET_USER}@<TAILSCALE_IP>
  2. Password login should be denied: ssh -o PubkeyAuthentication=no ${TARGET_USER}@<TAILSCALE_IP>
     (expected: Permission denied (publickey))
Other SSH clients such as WinSCP must switch to private key authentication too.
If something goes wrong, run this in the current window: sudo ./scripts/rollback.sh ssh
EOF
