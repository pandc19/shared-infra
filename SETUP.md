# Setup guide

How to bring `shared-infra` up from this repo, in order. Detailed steps for each manual part: [docs/manual-configuration.md](docs/manual-configuration.md). Every name and value: [docs/deployment-reference.md](docs/deployment-reference.md). Branching and PR rules: [docs/git-flow.md](docs/git-flow.md).

**Order:** DigitalOcean -> Cloudflare -> Coolify key -> GitHub -> first deploy -> verify -> Coolify server -> Postgres -> apps.

Conventions: bucket `shared-infra-storage` (state in `tfstate/`, backups under `data/`), DO Project `Shared Apps`, droplet `shared-apps-1`, apps at `<name>.novaej.com` via wildcard `*.novaej.com` (hyphens, not underscores).

---

## 1. DigitalOcean
Create by hand (Terraform can't create the bucket holding its own state): an API token (`DO_TOKEN`), a Project named `Shared Apps`, the private bucket `shared-infra-storage` in nyc3, and **two** limited Spaces keys from API -> Spaces Keys: `shared-infra-terraform-state` (GitHub secrets) and `shared-infra-coolify-backups` (Coolify only). Steps: [manual-configuration.md](docs/manual-configuration.md#1-digitalocean).

## 2. Cloudflare
An API token with DNS edit on the zone (`CLOUDFLARE_TOKEN`), the zone ID (`CLOUDFLARE_ZONE_ID`), and SSL mode **Full (strict)**. Nothing for the edge certificate: free Universal SSL covers the one-level `<name>.novaej.com` pattern. Explicit records beat the wildcard.

**Let's Encrypt vs the firewall.** By default only Cloudflare's ranges reach 80/443. Certificate issuance works while records are **proxied**. A **DNS-only** record breaks it: set `RESTRICT_HTTP_TO_CLOUDFLARE=false` (or `restrict_http_to_cloudflare = false` locally) and apply, which opens 80/443 to everyone. Port 22 is open either way (Coolify Cloud has no fixed IPs).

## 3. Coolify key
Generate an ED25519 key in Coolify (Keys & Tokens -> Private Keys). Put only the **public** line in `COOLIFY_SSH_PUBLIC_KEY`. Never generate keys in Terraform: the private key would land in state. If apply reports a duplicate key, delete the stale one in DigitalOcean Settings -> Security.

## 4. GitHub
Set the secrets and variables at repository level, create the environments `shared-infra` (no reviewers) and `shared-infra-destroy` (reviewers, `main` only), and add the `main` ruleset: full list in [git-flow.md](docs/git-flow.md#github-repository-settings). `TERRAFORM_ENABLED` is the kill switch: every job is skipped unless it is `true`.

## 5. First deploy
1. Set `TERRAFORM_ENABLED=true`.
2. Open a PR touching Terraform files. The `plan` job changes nothing. Expect **7 to add, 0 to change, 0 to destroy** (SSH key, droplet, reserved IP, assignment, firewall, project resources, DNS record).
3. Merge. `plan` then `apply` build everything; the end of the `apply` log prints `reserved_ip` and `coolify_server_settings`.

To run Terraform locally instead, see "Running Terraform locally" in the reference. Never apply from both places at once.

| Failure | Cause |
|---|---|
| `init` fails | wrong Spaces key, or bucket not in nyc3 (endpoint in `backend.tf`) |
| project lookup error | Project isn't exactly `Shared Apps` |
| Cloudflare auth error | token doesn't cover the zone |
| `422 Size is not available in this region` | no capacity there; change `region`/`droplet_size` in `variables.tf` (default is `lon1` since `nyc1` was out on 2026-10-18) |

A failed apply keeps what was created in state; re-run `apply`, or clean up with the destroy path in [DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md).

## 6. Verify the box
Wait 3-5 minutes for cloud-init. Coolify's *Validate Server* proves SSH as root and Docker. For a direct check, SSH in with a key you control ([new-app-database.md](docs/new-app-database.md) steps 1-3):

```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<reserved-ip> \
  'cloud-init status --wait; ls /var/lib/cloud/shared-infra-provisioned; docker --version; swapon --show; sysctl vm.swappiness; systemctl is-active fail2ban; sshd -T | grep -E "^(permitrootlogin|passwordauthentication|allowusers|maxauthtries|logingracetime)"'
```
Expect `done`, Docker present, 2G swap, swappiness 10, fail2ban `active`, `prohibit-password`, `passwordauthentication no`, `allowusers root`, 3 tries, 30 s. If wrong: `tail -n 100 /var/log/cloud-init-output.log`.

## 7. Coolify: server, proxy, Postgres
Add the server (`shared-apps-1`, reserved IP, port 22, user `root`, your key), validate, **Start Proxy**. Add the S3 destination, create `shared-postgres` (public access off, pinned major version), and add the backup schedule with Save to S3, then **Backup now** and confirm the file in Spaces. Steps and settings: [manual-configuration.md](docs/manual-configuration.md#4-coolify-cloud).

Run the restore test on a throwaway database before real data ([manual-configuration.md](docs/manual-configuration.md#5-databases-per-app-restores-laptop-access)).

## 8. Apps
Once: enable Docker cleanup on the server and register a GitHub source for each GitHub account or organization ([manual-configuration.md](docs/manual-configuration.md#6-github-source-cleanup-deploying-an-app)). Then, per app, follow **[docs/new-app.md](docs/new-app.md)**: database and role ([new-app-database.md](docs/new-app-database.md)), create the application from the GitHub App source, runtime-only secrets, auto-deploy, verify, back up, and protect the app repo's `main`. Test on a real hostname: the firewall blocks access by IP.

## Done when
An app loads over HTTPS on `<name>.novaej.com`, `shared-postgres` has a successful S3 backup, and a restore test passed.
