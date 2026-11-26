#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers for the secure-homeserver scripts. Meant to be sourced, not executed.

# shellcheck disable=SC2034  # used by the scripts that source this file
SH_NAME="secure-homeserver"
ASSUME_YES="${ASSUME_YES:-0}"

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_RESET=''
fi

log_info()  { printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Print the calling script's header comment block (from line 2 up to the first
# non-comment line) as its help text.
print_usage() {
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "Root privileges required; run with sudo."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Missing command: $c"
  done
}

# confirm "question": returns 0 on yes. Returns 0 immediately when ASSUME_YES=1 (or --yes).
confirm() {
  local answer
  if [[ ${ASSUME_YES} == 1 ]]; then
    return 0
  fi
  if [[ ! -t 0 ]]; then
    log_warn "Non-interactive shell, answering \"no\": $1 (use --yes to skip prompts)"
    return 1
  fi
  read -r -p "$1 [y/N] " answer
  [[ ${answer} =~ ^[Yy]([Ee][Ss])?$ ]]
}

warn_if_not_ubuntu() {
  local id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    id=$(. /etc/os-release && echo "${ID:-}")
  fi
  if [[ ${id} != ubuntu ]]; then
    log_warn "This project is designed for Ubuntu Server; detected: ${id:-unknown}"
  fi
}

apt_install() {
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
}

ssh_is_running() {
  systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket
}

# Print the peer IP of every established inbound SSH connection (one per line).
ssh_peer_ips() {
  local port=${1:-22}
  ss -Htn state established "( sport = :${port} )" 2>/dev/null \
    | awk '{print $4}' \
    | sed -E 's/^\[//; s/\]?:[0-9]+$//; s/^::ffff://'
}

# Whether an address is in Tailscale's ranges (100.64.0.0/10 or fd7a:115c:a1e0::/48).
is_tailscale_ip() {
  local ip=$1 second
  if [[ ${ip} == fd7a:115c:a1e0:* ]]; then
    return 0
  fi
  if [[ ${ip} =~ ^100\.([0-9]{1,3})\. ]]; then
    second=${BASH_REMATCH[1]}
    (( second >= 64 && second <= 127 )) && return 0
  fi
  return 1
}

is_loopback_ip() {
  [[ $1 == 127.* || $1 == ::1 ]]
}
