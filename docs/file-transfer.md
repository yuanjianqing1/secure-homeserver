# File transfer

Every method runs over the Tailscale network; no extra ports need to be opened.

| Method | Best for | Notes |
|---|---|---|
| SFTP GUI clients (WinSCP, FileZilla, etc.) | Everyday transfers, browsing directories | Runs over SSH (tcp/22); choose the **SFTP** protocol and **private key** authentication |
| `scp` / `sftp` commands | Scripts, batch operations | Built into Windows 10 and later |
| `rsync` | Syncing large directories, resumable transfers | Only transfers what changed; good for backups |
| Taildrop | Occasionally sending a single file | Built into Tailscale; no SSH needed |

## SFTP clients

`harden-ssh.sh` disables password login, so GUI clients must use a private key:

- **WinSCP**: Login → Advanced → SSH → Authentication → Private key file, then select `id_ed25519`. WinSCP offers to convert the OpenSSH key to `.ppk`; accept the conversion.
- **FileZilla**: Settings → SFTP → Add key file.

## Command line

```powershell
# Upload a file
scp .\file.zip <USER>@<TAILSCALE_IP>:~/
# Upload a directory
scp -r .\folder <USER>@<TAILSCALE_IP>:~/
# Download
scp <USER>@<TAILSCALE_IP>:~/file.zip .\
```

```bash
# Sync a directory (transfers only changed files; resumable)
rsync -avP ./data/ <USER>@<TAILSCALE_IP>:~/data/
```

## Taildrop

- Send: on Windows, right-click the file → Send to → Tailscale → pick a device; on the command line, `tailscale file cp <file> <device>:`
- Receive: files land in a staging area and must be retrieved manually: `sudo tailscale file get ~/`

Note: Taildrop is mainly for devices **owned by the same user**. Once the server is tagged `tag:server` it no longer belongs to a personal account and may not receive Taildrop files; use SFTP instead.
