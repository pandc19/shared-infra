# shared-infra

Terraform for **one** DigitalOcean droplet (`shared-apps-1`) that is managed by **Coolify Cloud**.
Terraform builds a clean Ubuntu 24.04 box (Docker, 2G swap, SSH hardening, fail2ban,
unattended-upgrades), a reserved IP, a Cloudflare-restricted firewall, and a proxied wildcard DNS
record `*.<base_domain>`. Everything above that (apps, `shared-postgres`, backups) is created
in Coolify. Terraform never touches Coolify.

**Status:** running. Droplet in London (`lon1`) since 2026-10-18, a stopgap while `nyc1` was out of capacity (moving later: [DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md#moving-to-another-region-for-example-lon1---nyc1)). Coolify manages the server, `shared-postgres` with daily S3 backups, and the first app. Details in the reference.

- **[SETUP.md](SETUP.md)** - guide to bringing it up from this repo: what to configure where, first deploy, Coolify server, Postgres and a tested restore.
- **[docs/git-flow.md](docs/git-flow.md)** - branching, PR flow, rollbacks, and the exact GitHub settings and rulesets.
- **[docs/manual-configuration.md](docs/manual-configuration.md)** - step-by-step for everything done by hand: DO, Cloudflare, GitHub, Coolify, backups, restore test, DBeaver over SSH, deploying an app.
- **[docs/new-app.md](docs/new-app.md)** - the generic process for adding an app: GitHub source, database, Coolify application, variables, deploy, repo policies, troubleshooting.
- **[docs/new-app-database.md](docs/new-app-database.md)** - ordered, short procedure (with where to run each step) for creating an app database and backing it up, plus an optional section for loading an existing dump over SSH.
- **[docs/deployment-reference.md](docs/deployment-reference.md)** - every name, secret, variable, setting and trigger in one place, plus current status.
- **[DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md)** - what a destroy loses, final backup, rebuild, re-add to Coolify, restore.

## Layout

```
modules/droplet/        droplet, SSH key, reserved IP, firewall, project attachment, DNS, cloud-init
environments/shared/    backend (DO Spaces), providers, variables, outputs, terraform.tfvars.example
.github/workflows/      plan on PR, apply on main, manual destroy (two approvals)
docs/                   deployment-reference.md (all names, secrets, variables, settings)
```

A second box later = a new `environments/<name>/` calling the same module with a different name and backend key.

## Quick use

```sh
cd environments/shared
export TF_VAR_do_token=... TF_VAR_cloudflare_token=... AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...
cp terraform.tfvars.example terraform.tfvars   # fill it in
terraform init && terraform plan
```

Repo: https://github.com/pandc19/shared-infra
