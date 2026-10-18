# shared-infra Deployment Reference

Last updated: 2026-10-18

**Status: droplet live in London (`lon1`) since 2026-10-18** - droplet `shared-apps-1`, reserved IP `209.38.170.24`, firewall, project attachment and wildcard `*.novaej.com` all provisioned (7 resources, via the workflow's apply on `main`). `lon1` is a stopgap: `nyc1` had no `s-1vcpu-1gb` capacity on 2026-10-18 and is the intended home. Moving back replaces the droplet and reserved IP (data on the box is lost), so follow [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) and back up Postgres first. Still to do in Coolify: add the server, create `shared-postgres` with S3 backups and a restore test, deploy apps (first: poketrain at `poketrain.novaej.com`). See [SETUP.md](../SETUP.md) sections 7 and 8.

This file is the single list of **what is configured, where, and with which name**. [SETUP.md](../SETUP.md) is the ordered guide for doing it; [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) is the runbook for tearing down and rebuilding.

## Architecture

- **Terraform** provisions one DigitalOcean droplet (`shared-apps-1`), its firewall, an SSH key holding Coolify's public key, a reserved IP, the project attachment, and one Cloudflare DNS record. State lives in a DigitalOcean Spaces bucket.
- **Coolify Cloud** is the control plane (hosted by Coolify). It connects to the droplet over SSH **as root** with a key Coolify generated. Everything above the box (apps, `shared-postgres`, backups, the reverse proxy) is created in Coolify. Terraform never touches Coolify and does not use the Coolify provider.
- **The droplet** is a plain Ubuntu 24.04 image. Cloud-init installs Docker (Docker's official apt repo), a 2G swap file, SSH hardening, fail2ban and unattended-upgrades, and nothing else.
- **Cloudflare** proxies `*.novaej.com` to the reserved IP. Coolify's proxy (Traefik) on the droplet obtains Let's Encrypt certificates for each app.
- **GitHub Actions** runs Terraform: plan on PR, apply on `main`, manual destroy behind two approvals.
- **Postgres** (`shared-postgres`) is created in Coolify on the droplet. Its backups go to the Spaces bucket.

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

Explicit records (`www`, `api`, `MX`, other projects) always win over the wildcard. Any unclaimed name resolves to the droplet and Traefik returns 404.

**Let's Encrypt and the firewall.** With 80/443 restricted to Cloudflare, HTTP-01 works while records are **proxied** (the validator hits Cloudflare, which forwards the challenge). A **DNS-only** record breaks it: set `restrict_http_to_cloudflare = false` and apply first.

## DigitalOcean Spaces keys

Created by hand (API -> Spaces Keys -> Generate New Key -> Limited Access, bucket `shared-infra-storage`, Read/Write/Delete). Keys are per bucket, not per prefix; two keys exist only so one can be revoked independently.

| Key name | Used by | Where the values live |
|---|---|---|
| `shared-infra-terraform-state` | Terraform state backend | GitHub secrets `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`; locally `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| `shared-infra-coolify-backups` | Coolify S3 destination for `shared-postgres` | Coolify only |

## Coolify Cloud

| Item | Value |
|---|---|
| Private key | generated in Keys & Tokens -> Private Keys (ED25519, name `shared-apps-1`); never leaves Coolify |
| Public key | in GitHub variable `COOLIFY_SSH_PUBLIC_KEY` and installed as root's authorized key by Terraform |
| Server | name `shared-apps-1`, IP = `reserved_ip` output, port 22, user `root`, build server off |
| Wildcard domain | `https://novaej.com` (only seeds default app domains; set `<name>.novaej.com` per app) |
| S3 storage | endpoint `https://nyc3.digitaloceanspaces.com`, region `nyc3`, bucket `shared-infra-storage`, the `shared-infra-coolify-backups` key |
| Postgres | `shared-postgres`, pinned major version, persistent storage, scheduled backup to S3 (no prefix field; lands at `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<db>-<timestamp>-<id>.dmp`). Retention: 2 backups / 7 days local, 14 backups / 30 days on S3. Daily cron `0 3 * * *` (server time, UTC). |

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

Create `shared-infra-destroy` with its reviewer rule **before** the first destroy: if it doesn't exist GitHub creates it with no reviewers and the destroy runs ungated.

### Workflow triggers (`terraform.yml`)

| Event | Condition | Result |
|---|---|---|
| Pull request | files under `modules/**`, `environments/**` or the workflow changed; same-repo PRs only | `plan` |
| Push to `main` | same path filter | `plan`, then `apply` |
| Manual | `action=plan` | `plan` |
| Manual | `action=apply`, on `main` | `plan`, then `apply` |
| Manual | `action=destroy`, on `main` | approval 1 -> `plan -destroy` -> approval 2 -> `destroy` |

Docs-only changes never trigger it. A concurrency group (`terraform-shared`) serializes runs. Pins: Terraform 1.7.5 in CI (`required_version >= 1.7`), providers `digitalocean ~> 2.40`, `cloudflare ~> 4.0`, `http ~> 3.4` (lock file committed).

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
