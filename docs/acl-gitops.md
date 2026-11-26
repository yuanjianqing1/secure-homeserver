# Managing Tailscale ACLs with GitOps

The access policy lives in [`tailscale/policy.hujson`](../tailscale/policy.hujson) and is changed the same way as code: open a pull request → automated tests → merge to `main` → automatic deployment.

## Why

- **Reviewable**: every change has a commit, so who changed what and why is always on record
- **Testable**: the policy's `tests` state who must and must not be able to reach what, so mistakes are caught before merging
- **Revertible**: if something breaks, `git revert` and merge

## Current policy

| Rule | Meaning |
|---|---|
| `autogroup:member` → `autogroup:self`, all ports | Your own devices can reach each other |
| `autogroup:member` → `tag:server`, `tcp:22`, `icmp` | Only SSH and ping are allowed to the server |
| `tagOwners`: `tag:server` can only be assigned by admins | Prevents ordinary members from disguising their devices as servers |

Devices tagged `tag:server` **have key expiry disabled by default**, which suits always-on servers. Request the tag with `setup-tailscale.sh --tag tag:server`, or assign it manually in the admin console.

## Enabling it

1. **Back up the current policy**: copy it from the Access controls page in the Tailscale admin console. Once automatic deployment is on, the policy in the console is **overwritten** by the file in this repository.
2. **Edit `policy.hujson`**: replace `<YOUR_TAILSCALE_LOGIN>` with your Tailscale login, or the tests will fail.
3. **Create an OAuth client**: admin console → Settings → OAuth clients; grant write access to the policy file and note the client ID and secret.
4. **Configure the GitHub repository**:
   - Settings → Secrets and variables → Actions → **Secrets**:
     - `TS_OAUTH_ID`: OAuth client ID
     - `TS_OAUTH_SECRET`: OAuth client secret
     - `TS_TAILNET`: tailnet name (shown under Settings → General in the admin console)
   - **Variables**: `TS_GITOPS_ENABLED` = `true`
5. Change `policy.hujson` in a pull request, check that "Tailscale ACL / Test policy" passes, then merge.

Without `TS_GITOPS_ENABLED` the workflow is skipped, so forks and freshly created repositories don't fail for lack of secrets.

## Security notes

- Keep the OAuth secret only in GitHub Secrets; **never write it into any file or commit**
- Grant the OAuth client only what it needs (the policy file)
- Pull requests from forks don't receive secrets, so they cannot change your policy
