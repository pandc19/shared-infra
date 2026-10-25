# shared-infra Deployment Reference

Last updated: 2026-10-18

See also: [SETUP.md](../SETUP.md) (order), [new-app.md](new-app.md) (add an app), [manual-configuration.md](manual-configuration.md) (hand steps), [new-app-database.md](new-app-database.md) (per-app DB), [git-flow.md](git-flow.md) (branching, GitHub settings), [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md).

**Status:** droplet live in London (`lon1`) since 2026-10-18 (reserved IP `209.38.170.24`, a snapshot: the Terraform output is the source of truth). `lon1` is a stopgap (moving back: [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md#moving-to-another-region-for-example-lon1---nyc1)) because `nyc1` had no `s-1vcpu-1gb` capacity; moving back replaces the droplet and wipes it, so back up first ([DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md)). This file lists what is configured, where, and under which name.

## Architecture

- **Terraform** builds one DigitalOcean droplet (`shared-apps-1`) with its firewall, SSH key, reserved IP, project attachment and one Cloudflare DNS record. State lives in a Spaces bucket. It never touches Coolify and doesn't use the Coolify provider.
- **Coolify Cloud** is the hosted control plane. It SSHes into the droplet **as root** with its own key and manages apps, `shared-postgres` and backups.
- **The droplet** is plain Ubuntu 24.04; cloud-init adds Docker, swap, SSH hardening, fail2ban, unattended-upgrades.
- **Cloudflare** proxies `*.novaej.com` to the reserved IP; Coolify's proxy (Traefik) gets Let's Encrypt certificates per app.
- **GitHub Actions** runs Terraform: plan on PR, apply on `main`, manual destroy behind two approvals.

## Components and platforms

| Component | Platform | Name / value |
|---|---|---|
| Compute | DigitalOcean droplet | `shared-apps-1`, `s-1vcpu-1gb` (default), region `lon1` (default, London; `nyc1` was out of capacity on 2026-10-18 and is the intended home to return to), `ubuntu-24-04-x64` |
| Stable address | DigitalOcean reserved IP | created by Terraform, assigned via `digitalocean_reserved_ip_assignment` |
| Firewall | DigitalOcean Cloud Firewall | `shared-apps-1-fw` |
| SSH key (DO side) | `digitalocean_ssh_key` | `shared-apps-coolify` (holds Coolify's public key only) |
| DO Project | DigitalOcean | `Shared Apps` - looked up by name, never created by Terraform |
| State + backups | DigitalOcean Spaces | bucket `shared-infra-storage`, region `nyc3`, created by hand, private |
| DNS / proxy | Cloudflare | zone `novaej.com`; `*.novaej.com` A record, proxied, Terraform-managed |
| Control plane | Coolify Cloud | server `shared-apps-1`, user `root`, port 22 |
| Database | Postgres in Coolify | `shared-postgres` (not Terraform) |
| IaC CI/CD | GitHub Actions | `.github/workflows/terraform.yml` |
| Repo | GitHub | https://github.com/pandc19/shared-infra |

## Terraform layout and inputs

```
modules/droplet/        droplet, SSH key, reserved IP + assignment, firewall, project attachment, DNS, cloud-init
environments/shared/    backend.tf, main.tf (providers + module call), variables.tf, outputs.tf, terraform.tfvars.example
```

A second box later = a new `environments/<name>/` calling the same module with another `name`, `ssh_key_name` and backend `key`.

### Variables (`environments/shared/variables.tf`)

| Variable | Default | Source in GitHub Actions | Notes |
|---|---|---|---|
| `do_token` | - | secret `DO_TOKEN` | sensitive |
| `cloudflare_token` | - | secret `CLOUDFLARE_TOKEN` | sensitive |
| `coolify_ssh_public_key` | - | variable `COOLIFY_SSH_PUBLIC_KEY` | public key only; validated, private keys are rejected |
| `cloudflare_zone_id` | - | variable `CLOUDFLARE_ZONE_ID` | zone containing `base_domain` |
| `base_domain` | - | variable `BASE_DOMAIN` (`novaej.com`) | |
| `region` | `lon1` | not wired (edit default or tfvars) | droplet + reserved IP region |
| `droplet_size` | `s-1vcpu-1gb` | not wired (edit default or tfvars) | |
| `restrict_http_to_cloudflare` | `true` | variable `RESTRICT_HTTP_TO_CLOUDFLARE` (optional) | `false` opens 80/443 to everyone |
| `project_name` | `Shared Apps` | not wired | must match an existing DO Project exactly |

The workflow maps GitHub values to `TF_VAR_*` environment variables. `terraform.tfvars` is git-ignored and is only used when running Terraform locally.

### Outputs

`reserved_ip`, `droplet_id`, and `coolify_server_settings` (a copy-paste block for Coolify's Add Server form). In CI they appear at the end of the `apply` job log.

### Terraform state backend

| Setting | Value |
|---|---|
| Backend | S3-compatible, DigitalOcean Spaces |
| Endpoint | `https://nyc3.digitaloceanspaces.com` |
| Bucket | `shared-infra-storage` |
| State key | `tfstate/shared/terraform.tfstate` |
| Credentials | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` = the `shared-infra-terraform-state` Spaces key |
| Backup location | Coolify writes under `data/` (see Coolify section); `tfstate/` is Terraform's |

## DigitalOcean - droplet and firewall

| Setting | Value |
|---|---|
| Droplet name | `shared-apps-1` |
| Image | `ubuntu-24-04-x64` (plain distribution image) |
| `resize_disk` | `false` (a size change never grows the disk) |
| `lifecycle.ignore_changes` | `user_data`, `ssh_keys` - edits to cloud-init or the key never trigger a rebuild; use `terraform apply -replace=...` deliberately |
| Root login | by key only (`PermitRootLogin prohibit-password`), key = the Coolify public key |
| Inbound 80/443 | Cloudflare IPv4 ranges (fetched live from cloudflare.com/ips-v4) when `restrict_http_to_cloudflare = true`; otherwise `0.0.0.0/0` and `::/0` |
| Inbound 22 | `0.0.0.0/0` (Coolify Cloud has no fixed IPs) |
| Outbound | TCP and UDP, all ports |
| Project attachment | droplet and reserved IP attached to `Shared Apps` via `digitalocean_project_resources` |

### Cloud-init (first boot only)

| Item | Detail |
|---|---|
| SSH drop-in | `/etc/ssh/sshd_config.d/00-shared-infra-hardening.conf`: `PermitRootLogin prohibit-password`, `PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PubkeyAuthentication yes`, `MaxAuthTries 3`, `LoginGraceTime 30`, `AllowUsers root`. `00-` so it wins over `50-cloud-init.conf`. |
| fail2ban | `/etc/fail2ban/jail.d/sshd.local`: sshd jail, systemd backend, 5 tries / 10 min, 1 hour ban |
| Swap | `fallocate -l 2G /swapfile`, in fstab; `vm.swappiness=10` via `/etc/sysctl.d/99-swappiness.conf` |
| Packages | `ca-certificates curl gnupg git jq wget openssl`, then `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin fail2ban unattended-upgrades` |
| apt | every call uses `-o DPkg::Lock::Timeout=300`; Docker from Docker's official apt repo, not get.docker.com |
| Guard | `sshd -t` before the ssh restart; marker file `/var/lib/cloud/shared-infra-provisioned` on completion |

No deploy user, no sudo model, no app code, no docker-compose: Coolify owns everything above this.

## Cloudflare

| Item | Value |
|---|---|
| Zone | `novaej.com` |
| DNS record (Terraform) | `*.novaej.com` A -> reserved IP, proxied, TTL auto |
| App hostnames | `<name>.novaej.com` (hyphens, not underscores) - one level, covered by free Universal SSL |
| SSL/TLS mode | **Full (strict)** - set by hand; zone-wide, so check other proxied sites first |
| API token | `Zone : DNS : Edit` on the `novaej.com` zone; used only by Terraform |
| Zone ID | zone Overview page, API section |

Explicit records (`www`, `api`, `MX`, an old host's CNAME) win over the wildcard. Unclaimed names resolve to the droplet and Traefik returns 404.

**Let's Encrypt and the firewall.** With 80/443 restricted to Cloudflare, HTTP-01 works for **proxied** records. A **DNS-only** record breaks it: set `restrict_http_to_cloudflare = false` and apply first.

## DigitalOcean Spaces keys

Created by hand (steps in [manual-configuration.md](manual-configuration.md#1-digitalocean)), limited to the bucket with Read/Write/Delete. Keys are per bucket, not per prefix; two exist so one can be revoked alone.

| Key name | Used by | Values live in |
|---|---|---|
| `shared-infra-terraform-state` | Terraform state backend | GitHub secrets `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`; locally `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| `shared-infra-coolify-backups` | Coolify S3 destination | Coolify only |

## Coolify Cloud

| Item | Value |
|---|---|
| Private key | generated in Keys & Tokens -> Private Keys (ED25519, name `shared-apps-1`); never leaves Coolify |
| Public key | in GitHub variable `COOLIFY_SSH_PUBLIC_KEY` and installed as root's authorized key by Terraform |
| Server | name `shared-apps-1`, IP = `reserved_ip` output, port 22, user `root`, build server off |
| Wildcard domain | `https://novaej.com` (only seeds default app domains; set `<name>.novaej.com` per app) |
| Proxy | Traefik, started by hand after validation (Server -> Proxy -> Start Proxy) |
| GitHub source | Two GitHub Apps, each installed on selected repos: `coolify-pandc19` (personal account, poketrain and tidewatch) and `coolify-novaej` (`novaej` organization, comprobify-mcp-server). Apps use *Private Repository (with GitHub App)*, never a deploy key. |
| Docker cleanup | server-level (Servers -> `shared-apps-1` -> Docker Cleanup): frequency `0 4 * * *` (04:00 UTC), trigger *Run on every schedule*, unused networks **delete**, application images **delete all old images**, unused volumes **keep** (see warning below) |
| Images kept for rollback | **disabled on purpose** to keep the disk lean: server Docker Cleanup *Application images* = delete all old images, so the app's Rollback page shows *Disabled by the server*. Roll back with a git revert and redeploy. To enable, set that server option to keep retained images; then each app's *Images to keep* (default 2) applies. Rollback never undoes database migrations. |
| Env var rule | secrets are runtime variables only: **Build Variable off** |
| S3 storage | endpoint `https://nyc3.digitaloceanspaces.com`, region `nyc3`, bucket `shared-infra-storage`, the `shared-infra-coolify-backups` key |
| Postgres | `shared-postgres`, pinned major version, persistent storage, backup to S3 (no prefix field; lands at `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<db>-<timestamp>-<id>.dmp`). Retention: 2 backups / 7 days local, 14 backups / 30 days on S3. Daily cron `0 3 * * *` (server time, UTC). |

## Apps

| App | Domain | Database / role | Source repo | Notes |
|---|---|---|---|---|
| poketrain | `poketrain.novaej.com` | `poketrain` / `poketrain_app` | `pandc19/poketrain` via `coolify-pandc19`, branch `main` | Dockerfile build (Next.js standalone, port 3000), entrypoint runs `prisma migrate deploy`, auto-deploy on. Restored from a Neon dump on 2026-10-18. |
| tidewatch | none | `tidewatch_testnet` / `tidewatch_app` | `pandc19/tidewatch` via `coolify-pandc19`, branch `main` | Binance trading bot (Python), Dockerfile build. No port and no domain: it only makes outbound connections. Health is a heartbeat file, not HTTP. Entrypoint runs `alembic upgrade head`. Stop timeout 40 s or more. Running on the Binance testnet since 2026-10-19, no real money. Details in the app's `docs/coolify.md`. |
| comprobify-mcp-server | `comprobify.novaej.com/mcp` | none (stateless) | `novaej/comprobify-mcp-server` via `coolify-novaej`, branch `main` | Read-only OAuth-protected MCP server for Comprobify (Python), Dockerfile build, port 8000, health check on `/.well-known/oauth-protected-resource/mcp`. Needs `MCP_SERVER_URL`, `COMPROBIFY_WEB_URL`, `COMPROBIFY_API_URL` and `MCP_INTROSPECTION_SECRET` (shared with Comprobify web), all runtime-only. Details in the app's `docs/deployment.md`. |

**Never set unused volumes to delete.** Cleanup removes stopped containers first, then unused volumes, so a stopped `shared-postgres` would lose its data volume. Backups are daily, so a loss would cost up to a day.

Add a row for every new app ([new-app.md](new-app.md)).

## GitHub - secrets, variables, environments

Everything is at **repository level** (Settings -> Secrets and variables -> Actions). The two Environments hold no secrets.

### Repository secrets

| Secret | Value |
|---|---|
| `DO_TOKEN` | DigitalOcean API token, read+write |
| `CLOUDFLARE_TOKEN` | Cloudflare token, DNS edit on `novaej.com` |
| `SPACES_ACCESS_KEY_ID` | `shared-infra-terraform-state` key ID |
| `SPACES_SECRET_ACCESS_KEY` | its secret |

### Repository variables

| Variable | Value |
|---|---|
| `COOLIFY_SSH_PUBLIC_KEY` | public key from Coolify |
| `CLOUDFLARE_ZONE_ID` | Cloudflare zone ID |
| `BASE_DOMAIN` | `novaej.com` |
| `RESTRICT_HTTP_TO_CLOUDFLARE` | optional; `false` opens 80/443 to all |
| `TERRAFORM_ENABLED` | kill switch: every job is skipped unless `true`. Currently `true`, so a push touching `modules/**` or `environments/**` plans and applies. Set `false` to park the project. |

### Environments

| Environment | Reviewers | Used by |
|---|---|---|
| `shared-infra` | none | `plan` and `apply` jobs |
| `shared-infra-destroy` | required reviewer(s); restrict to `main` | `plan-destroy` and `apply-destroy` - two separate approvals |

Create `shared-infra-destroy` with its reviewers **before** the first destroy; GitHub otherwise auto-creates it with none and the destroy runs ungated. Branch rules and repo settings: [git-flow.md](git-flow.md#github-repository-settings).

### Workflow triggers (`terraform.yml`)

| Event | Condition | Result |
|---|---|---|
| Pull request | same-repo PRs only (runs on every PR so the required `plan` check always reports) | `plan` |
| Push to `main` | same path filter | `plan`, then `apply` |
| Manual | `action=plan` | `plan` |
| Manual | `action=apply`, on `main` | `plan`, then `apply` |
| Manual | `action=destroy`, on `main` | approval 1 -> `plan -destroy` -> approval 2 -> `destroy` |

Docs-only changes never trigger it. Docs-only changes to `main` never trigger it. Concurrency group `terraform-shared` serializes runs. CI pins Terraform 1.7.5 (`required_version >= 1.7`); providers `digitalocean ~> 2.40`, `cloudflare ~> 4.0`, `http ~> 3.4`; lock file committed.

## Running Terraform locally (alternative to CI)

```sh
cd environments/shared
cp terraform.tfvars.example terraform.tfvars   # coolify_ssh_public_key, base_domain, cloudflare_zone_id
export TF_VAR_do_token=...  TF_VAR_cloudflare_token=...
export AWS_ACCESS_KEY_ID=...  AWS_SECRET_ACCESS_KEY=...   # the shared-infra-terraform-state key
terraform init && terraform plan
```

Don't apply from CI and locally against the same state at the same time.

## Known issues and history

| Date | Event |
|---|---|
| 2026-10-18 (later) | Default region changed to `lon1` (PR #2). Merge applied cleanly: 7 added, 0 changed, 0 destroyed. Droplet live, reserved IP `209.38.170.24`. |
| 2026-10-18 | First apply: SSH key, reserved IP and DNS created; droplet failed with `422 Size is not available in this region` (`s-1vcpu-1gb`, `nyc1`, a DigitalOcean capacity notice). Partial resources destroyed via the workflow's destroy path. Plan for a clean run is 7 resources: SSH key, droplet, reserved IP, assignment, firewall, project resources, DNS record. |
