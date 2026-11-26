#!/usr/bin/env bash
# Server health check: Tailscale connectivity, SSH and firewall settings, sleep
# settings and system resources.
# Runs as a normal user; with sudo it also checks the effective sshd config and
# firewall rules.
# Does not depend on lib.sh, so it can be copied to /usr/local/sbin and run by a timer.
#
# Usage: ./scripts/healthcheck.sh [--peer NAME] [--quiet]
#   --peer NAME   use tailscale ping to test the path (direct or DERP relay) and latency to a device
#   --quiet       print only warnings, failures and the final summary
# Exit codes: 0 all OK, 1 warnings, 2 failures
set -uo pipefail
export LC_ALL=C   # keep ufw, systemctl, etc. output in English for parsing

SELF_UNIT="secure-homeserver-healthcheck.service"
PEER=""
QUIET=0
while (($#)); do
  case $1 in
    --peer)    PEER=${2:?--peer requires a value}; shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit 0 ;;
    *)         echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_RESET=$'\e[0m'
else
  C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
fi

WARN_COUNT=0
FAIL_COUNT=0
section() { ((QUIET)) || printf '\n== %s ==\n' "$*"; }
ok()      { ((QUIET)) || printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
info()    { ((QUIET)) || printf '[INFO] %s\n' "$*"; }
warn()    { WARN_COUNT=$((WARN_COUNT + 1)); printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
fail()    { FAIL_COUNT=$((FAIL_COUNT + 1)); printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*"; }

IS_ROOT=0
if [[ ${EUID} -eq 0 ]]; then IS_ROOT=1; fi

# ---------------------------------------------------------------- Tailscale
section "Tailscale"
if ! command -v tailscale >/dev/null 2>&1; then
  fail "tailscale is not installed"
else
  if systemctl is-active --quiet tailscaled; then
    ok "tailscaled is running"
  else
    fail "tailscaled is not running"
  fi

  state=$(tailscale status --json 2>/dev/null \
    | grep -o '"BackendState": *"[^"]*"' | head -n1 | sed -E 's/.*"([^"]*)"$/\1/')
  if [[ ${state} == Running ]]; then
    ok "Connected to tailnet"
  else
    fail "Not connected to tailnet (BackendState=${state:-unknown})"
  fi

  if prefs=$(tailscale debug prefs 2>/dev/null); then
    if grep -Eq '"RunSSH": *true' <<<"${prefs}"; then
      warn "Tailscale SSH is on: port 22 on the Tailscale IP is intercepted by tailscaled (see docs/ssh-decision.md)"
    else
      ok "Tailscale SSH is off; port 22 is handled by OpenSSH"
    fi
  fi

  if [[ -n ${PEER} ]]; then
    # tailscale ping may exit non-zero over DERP, so judge by its output.
    out=$(tailscale ping -c 1 --timeout 5s "${PEER}" 2>&1)
    pong=$(grep -m1 '^pong' <<<"${out}")
    latency=$(grep -oE 'in [0-9.]+[^ ]*' <<<"${pong}" | head -n1)
    if [[ -z ${pong} ]]; then
      fail "Cannot reach ${PEER}: $(tail -n1 <<<"${out}")"
    elif grep -q 'via DERP' <<<"${pong}"; then
      warn "Path to ${PEER} goes through a DERP relay (${latency:-latency unknown}); no direct P2P connection"
    else
      ok "Direct P2P path to ${PEER} (${latency:-latency unknown})"
    fi
  fi
fi

# ---------------------------------------------------------------- SSH
section "SSH"
if systemctl is-active --quiet ssh || systemctl is-active --quiet ssh.socket; then
  ok "OpenSSH is running"
else
  fail "OpenSSH is not running (neither ssh.service nor ssh.socket is active)"
fi

expect_kv() { # text key value ok-message warn-message
  if grep -qix "$2 $3" <<<"$1"; then ok "$4"; else warn "$5"; fi
}

if ((IS_ROOT)); then
  mkdir -p /run/sshd 2>/dev/null
  if eff=$(sshd -T 2>/dev/null); then
    expect_kv "${eff}" passwordauthentication no "Password authentication disabled" "Password authentication allowed (run harden-ssh.sh)"
    expect_kv "${eff}" permitrootlogin no "Root login disabled" "Root login allowed"
  else
    warn "Cannot read effective sshd config (sshd -T failed)"
  fi
else
  info "Running as a normal user; skipping sshd config checks (run with sudo to include them)"
fi

# ---------------------------------------------------------------- Firewall
section "Firewall"
if ((IS_ROOT)); then
  if command -v ufw >/dev/null 2>&1; then
    st=$(ufw status 2>/dev/null)
    if grep -q '^Status: active' <<<"${st}"; then ok "ufw is active"; else fail "ufw is not active"; fi
    if grep -Eq 'on tailscale0[[:space:]]+ALLOW' <<<"${st}"; then
      ok "Allow rule for tailscale0 present"
    else
      warn "No allow rule for tailscale0 found"
    fi
    if grep -Eq '^(22(/tcp)?|OpenSSH)( \(v6\))?[[:space:]]+ALLOW[[:space:]]+Anywhere' <<<"${st}"; then
      warn "SSH is open to every source (run firewall.sh)"
    fi
  else
    fail "ufw is not installed"
  fi
else
  info "Running as a normal user; skipping firewall checks"
fi

# ---------------------------------------------------------------- Power
section "Power"
unmasked=()
for t in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
  if [[ $(systemctl is-enabled "${t}" 2>/dev/null) != masked ]]; then
    unmasked+=("${t}")
  fi
done
if ((${#unmasked[@]} == 0)); then
  ok "Sleep and hibernation disabled"
else
  warn "These targets are not masked, so the system may suspend: ${unmasked[*]} (run server-mode.sh)"
fi

# ---------------------------------------------------------------- Resources
section "Resources"
disk=$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')
if ((disk >= 90)); then
  fail "Root filesystem ${disk}% used"
elif ((disk >= 80)); then
  warn "Root filesystem ${disk}% used"
else
  ok "Root filesystem ${disk}% used"
fi

mem_total=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
mem_avail=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
mem_pct=$((mem_avail * 100 / mem_total))
if ((mem_pct < 10)); then
  warn "Only ${mem_pct}% memory available"
else
  ok "${mem_pct}% memory available ($((mem_avail / 1024)) MiB)"
fi

load1=$(cut -d' ' -f1 /proc/loadavg)
cores=$(nproc)
if awk -v l="${load1}" -v c="${cores}" 'BEGIN { exit !(l > c) }'; then
  warn "1-minute load ${load1} exceeds CPU thread count ${cores}"
else
  ok "1-minute load ${load1} (${cores} threads)"
fi

mapfile -t failed_units < <(systemctl --failed --no-legend --plain 2>/dev/null \
  | awk '{ print $1 }' | grep -vx "${SELF_UNIT}")
if ((${#failed_units[@]})); then
  warn "Failed systemd units: ${failed_units[*]}"
else
  ok "No failed systemd units"
fi

info "Uptime: $(uptime -p)"

# ---------------------------------------------------------------- Summary
summary="Health check finished: ${FAIL_COUNT} failures, ${WARN_COUNT} warnings"
if ((FAIL_COUNT)); then
  printf '\n%s%s%s\n' "$C_RED" "${summary}" "$C_RESET"
  exit 2
elif ((WARN_COUNT)); then
  printf '\n%s%s%s\n' "$C_YELLOW" "${summary}" "$C_RESET"
  exit 1
fi
printf '\n%s%s%s\n' "$C_GREEN" "${summary}" "$C_RESET"
exit 0
