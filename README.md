# shared-infra

Terraform for **one** DigitalOcean droplet (`shared-apps-1`) that is managed by **Coolify Cloud**.
Terraform builds a clean Ubuntu 24.04 box (Docker, 2G swap, SSH hardening, fail2ban,
unattended-upgrades), a reserved IP, a Cloudflare-restricted firewall, and a proxied wildcard DNS
record `*.<base_domain>`. Everything above that (apps, `shared-postgres`, backups) is created
in Coolify. Terraform never touches Coolify.

- **[SETUP.md](SETUP.md)** - first-time, ordered checklist of every manual step, through to a tested Postgres restore.
- **[DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md)** - what a destroy loses, final backup, rebuild, re-add to Coolify, restore.

## Layout

```
modules/droplet/        droplet, SSH key, reserved IP, firewall, project attachment, DNS, cloud-init
environments/shared/    backend (DO Spaces), providers, variables, outputs, terraform.tfvars.example
.github/workflows/      plan on PR, apply on main, manual destroy (two approvals)
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
