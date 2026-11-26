# Troubleshooting log

Real problems encountered while building and using this setup. Each entry follows "symptom → investigation → root cause → fix → lessons".

---

## 1. Server goes offline after being idle, and SSH can't reconnect

**Symptom**
After a period of inactivity, existing connections drop and new SSH connections time out. Pressing a key on the server's keyboard brings it back.

**Investigation**
```bash
journalctl -b | grep -iE "suspend|sleep|lid" | tail -20
```
The log shows `Reached target Sleep` and `Suspending system...`: the system was suspending.

Further comparison: it never happened with only the command line in use; **it started only after a graphical user session was launched**. Disconnecting is not the same as logging out, so the session kept running in the background.

**Root cause**
The power manager in the user session behaved like it was on a laptop: after some idle time it asked the system to suspend. Once suspended, the network card stops, so neither Tailscale nor SSH can connect.

**Fix**
Instead of disabling power settings program by program, block suspend at the system level so that no program's suspend request takes effect:
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```
A logind drop-in also makes closing the lid do nothing. All of this is in `scripts/server-mode.sh`, and `healthcheck.sh` checks that these targets are masked.

**Lessons**
- When a problem appears only under certain conditions, look for the difference between "with it" and "without it" to narrow things down quickly.
- Blocking at the root (masking systemd targets) is more reliable than configuring every possible trigger.

---

## 2. Some clients fail to authenticate while command-line SSH works

**Symptom**
Command-line `ssh` logs in fine. Another client that only supports password and key authentication keeps reporting `authentication failed`, even with the correct password.

**Investigation**
```bash
# After one attempt from the failing client, check the OpenSSH log
sudo journalctl -u ssh -n 30 --no-pager
```
There were **no login entries from `100.x.y.z` at all**: the connection never reached sshd.

```bash
tailscale debug prefs | grep RunSSH
# "RunSSH": true
```

**Root cause**
Tailscale SSH had been enabled during setup. Every connection to port 22 on the Tailscale IP was taken over by tailscaled, which authenticates with Tailscale identity, while that client could only submit a password, so authentication failed. Command-line `ssh` is compatible with Tailscale SSH's authentication flow, which is why everything looked fine on the surface.

**Fix**
```bash
sudo tailscale set --ssh=false
```
Port 22 goes back to OpenSSH, and all authentication is managed by sshd. See [ssh-decision.md](ssh-decision.md) for the reasoning.

**Lessons**
- "Same port" does not mean "same service": confirm which process actually handles the connection.
- An **absence** of server-side log entries is itself a strong clue: the request was intercepted before it arrived.

---

## 3. SFTP clients fail or show a host key warning after switching SSH servers

**Symptom**
After turning off Tailscale SSH, previously saved SFTP connections fail or warn that the host key differs from the one on record.

**Root cause**
Tailscale SSH and OpenSSH use **different host keys**. The client remembers the old key, so it thinks the other end has changed.

**Fix**
Confirm the change was caused by your own switch, then accept the new key in the client (on the command line, remove the old entry with `ssh-keygen -R <TAILSCALE_IP>`).

**Lessons**
Host key warnings exist to stop man-in-the-middle attacks. Only accept a new key when you can explain why it changed.

---

## 4. Sluggish over mobile data: network problem or application problem?

**Symptom**
Interaction is noticeably slower when connecting over mobile data.

**Investigation**
```powershell
tailscale ping <server-name>
# pong from <server-name> (100.x.y.z) via [<IPv6 address>]:41641 in 44ms
```
- `via [IPv6]:41641`: **direct P2P**, not going through a DERP relay
- `44ms`: normal latency

**Conclusion**
Both the network path and the latency were fine. The bottleneck was the amount of data the application sent (bandwidth-limited), not the tunnel itself. Reducing the application's data volume (e.g. stronger compression) made it smooth again.

**Lessons**
- Diagnose layer by layer: network (path, latency) → transport → application, instead of tweaking settings right away.
- A single `tailscale ping` shows both "which path" and "how much latency"; this check is built into `healthcheck.sh --peer`.
