# SSH decision: Tailscale SSH or OpenSSH

## Background

Tailscale ships its own SSH server (`tailscale up --ssh`). When enabled, **connections to port 22 on the machine's Tailscale IP are intercepted by tailscaled** and never reach the system's OpenSSH. Both use port 22, but they authenticate in completely different ways.

```text
client → 100.x.y.z:22
            │
            ├─ Tailscale SSH on  → handled by tailscaled (Tailscale identity)
            └─ Tailscale SSH off → handled by OpenSSH/sshd (key or password)
```

## Comparison

| | Tailscale SSH | OpenSSH |
|---|---|---|
| Authentication | Tailscale account identity, controlled by `ssh` rules in the ACL | Public key or password, controlled by sshd config |
| Key management | No public keys to distribute | Public keys go into `authorized_keys` |
| Client compatibility | Works with command-line `ssh`; some GUI clients that only support password/key auth fail | Supported by every SSH and SFTP client |
| Auditing | Session recording in the admin console (paid feature) | System logs (`journalctl -u ssh`) |
| Dependencies | Depends on tailscaled and the Tailscale account state | Only depends on a stock system service |
| Emergency LAN access | Reachable only via the Tailscale IP | Reachable via the LAN IP (if the firewall allows it) |

## Decision: OpenSSH

1. **Compatibility**: in practice, command-line `ssh` worked, but another client that only supports password and key authentication kept failing with `authentication failed`. The cause was Tailscale SSH intercepting the connection; see [troubleshooting.md](troubleshooting.md#2-some-clients-fail-to-authenticate-while-command-line-ssh-works).
2. **Fewer single points of failure**: if Tailscale has a problem, OpenSSH is still available for emergency login on the LAN.
3. **Portability**: OpenSSH hardening is a general skill that carries over to any networking setup.

## Implementation

- `setup-tailscale.sh` explicitly passes `--ssh=false`
- `harden-ssh.sh` hardens OpenSSH (keys only, no root, AllowUsers)
- `healthcheck.sh` checks that `RunSSH` hasn't been turned back on

## Caveats when switching

- **The host key changes**: Tailscale SSH and OpenSSH use different host keys. After switching, clients warn that the host key doesn't match. This is expected; confirm and update `known_hosts`. If you see this warning **without** having switched, though, suspect a man-in-the-middle attack.
- **Your current session may drop**: if you are logged in through Tailscale SSH, turning it off may disconnect you. First make sure OpenSSH is running and that you can log in through it.
