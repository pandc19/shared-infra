# First-time setup

Do these in order. Tick each box as you go. Terraform only builds the box; everything in
Coolify (sections 7-9) is manual by design.

**Status so far:** code pushed to GitHub; DO token, Project, Spaces bucket (nyc3, empty) and both Spaces keys done; Cloudflare token set; Cloudflare zone ID and Coolify public key set as GitHub variables; GitHub secrets/variables are in place except `BASE_DOMAIN` (verify) and `TERRAFORM_ENABLED` (deliberately unset, so the workflow does nothing yet). Still to do: Cloudflare SSL mode, GitHub environments, first apply (section 6), then Coolify (sections 7-9).

Two ways to run Terraform; pick one and don't mix them:
- **GitHub Actions** (sections 8 and 6A): values come from GitHub secrets/variables, no `terraform.tfvars` needed.
- **Local** (sections 5 and 6B): values come from `terraform.tfvars` plus exported env vars.

Values used throughout: bucket `shared-infra-storage` (state in `tfstate/`, Postgres backups in
`pg-backups/`), DO Project `Shared Apps`, droplet `shared-apps-1`, domain `novaej.com`,
apps at `<name>.novaej.com` (wildcard `*.novaej.com`; use hyphens, not underscores - underscores aren't valid in hostnames).

---

## 1. Accounts and local tools

- [x] DigitalOcean account, Cloudflare account (with `novaej.com` as an active zone), Coolify Cloud account, GitHub repo `pandc19/shared-infra`.
- [ ] Terraform >= 1.7 (`terraform version`). Only needed for the local route.
- [ ] `git`, `ssh`. Optional: `doctl` and `s3cmd`/`aws` CLI for poking at Spaces.
- [x] Code is pushed to https://github.com/pandc19/shared-infra (branch `main`). The workflow is disabled until `TERRAFORM_ENABLED=true`.
      Someone setting this up again later would `git clone` it.

## 2. DigitalOcean

- [x] **API token** - already created; GitHub secret `DO_TOKEN` already set. (Control Panel -> API -> Tokens, read+write.)
- [ ] Local route only: env var `TF_VAR_do_token` (same token value).
- [x] **DO Project** `Shared Apps` already exists. Terraform only looks it up by name and fails if it is missing or misspelled.
- [x] **Spaces bucket** `shared-infra-storage` already exists in **nyc3** and is empty. Nothing to create: Terraform doesn't manage it (it can't create the bucket that holds its own state).
      `backend.tf` already points at `https://nyc3.digitaloceanspaces.com`. Keep the bucket private, no CDN. Optionally enable versioning on the bucket so an overwritten state file is recoverable.
- [x] **Limited Spaces keys** (created; `shared-infra-terraform-state` is also in GitHub). You create these by hand; neither Terraform nor GitHub does. They are *not* in the bucket's file browser (the "create folder" screen) - they live under the account-level API page:
      DigitalOcean control panel -> **API** (left sidebar, near the bottom) -> **Spaces Keys** tab (direct link: https://cloud.digitalocean.com/account/api/spaces) -> **Generate New Key**.
      Choose **Limited Access**, pick bucket `shared-infra-storage`, and give it **Read/Write/Delete**; the name is just a label. The secret is shown **once**, so copy both values immediately. Create **two** keys:
  - [x] `shared-infra-terraform-state` for Terraform. Local env vars: `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
        GitHub secrets: `SPACES_ACCESS_KEY_ID` and `SPACES_SECRET_ACCESS_KEY` (the workflow maps them to the `AWS_*` names).
  - [x] `shared-infra-coolify-backups` for Coolify (section 9). Keep it for the Coolify form; it does not go in Terraform or GitHub.

  Spaces keys are scoped per bucket, not per prefix, so both keys can technically read/write `tfstate/` and `pg-backups/`.
  Two keys only let you revoke one without breaking the other. Don't give the Coolify key to anything else.

## 3. Cloudflare

- [x] **API token** - already created; GitHub secret `CLOUDFLARE_TOKEN` already set. It needs `Zone : DNS : Edit` on the `novaej.com` zone.
- [ ] Local route only: env var `TF_VAR_cloudflare_token` (same token value).
- [ ] Terraform needs this token to create the wildcard DNS record, so keep it. If you reuse Comprobify's token, it must cover the `novaej.com` zone; a separate token per project limits the damage if one leaks.
- [x] **Zone ID** - set as GitHub variable `CLOUDFLARE_ZONE_ID`. (Where: zone Overview page, right sidebar, API section.) Local route: also `cloudflare_zone_id` in `terraform.tfvars`. Not secret.
- [ ] **SSL/TLS -> Overview -> mode = Full (strict).** Required: the wildcard record is proxied, and Coolify's proxy (Traefik) serves valid Let's Encrypt certificates on the origin.
      "Flexible" would cause redirect loops and send traffic to the origin unencrypted; "Full" (non-strict) skips cert validation.
- [ ] **Edge certificate:** nothing to do. Cloudflare's free Universal SSL covers `novaej.com` and `*.novaej.com`, which is exactly the one-level `<name>.novaej.com` pattern used here. (A two-level pattern like `<name>.apps.novaej.com` would need paid Advanced Certificate Manager; avoid it.)
- [ ] Existing records in the zone (www, api, MX, other projects' subdomains) are unaffected: explicit records always win over the wildcard. Any name you haven't created explicitly will now resolve to this droplet, which Traefik answers with a 404 until an app claims it.

### Let's Encrypt and the Cloudflare-only firewall

`restrict_http_to_cloudflare = true` (the default) lets only Cloudflare's IPv4 ranges reach ports 80/443. Let's Encrypt HTTP-01 validation
**still works while records are proxied**: the validator connects to Cloudflare, which forwards `/.well-known/acme-challenge/` to your origin from its own ranges.

It breaks if you ever create a **DNS-only** (grey cloud) record for an app: the validator then connects straight to the droplet and the firewall drops it.
In that case set `restrict_http_to_cloudflare = false` (tfvars or GitHub variable `RESTRICT_HTTP_TO_CLOUDFLARE=false`) and apply, which opens 80/443 to everyone.
With the default, hitting the raw IP bypasses Cloudflare's WAF/DDoS layer entirely; the firewall is what prevents that. Port 22 is open to the world in both modes (Coolify Cloud has no fixed IPs).

## 4. Coolify Cloud: generate the SSH key

Coolify SSHes into the droplet **as root** with a key it generates. Terraform only ever receives the **public** half.

- [x] Coolify Cloud -> Keys & Tokens -> Private Keys -> Add. Generate a new ED25519 key (e.g. name `shared-apps-1`).
- [x] Copy the **public key** (one line, `ssh-ed25519 AAAA... coolify`). Done: set as GitHub variable `COOLIFY_SSH_PUBLIC_KEY` (local route: `coolify_ssh_public_key` in tfvars). Not secret.
- [ ] Never paste the private key anywhere. The variable validates the format and rejects private keys.
- [ ] DigitalOcean rejects a public key that is already registered in the account (even under another name). If apply says the key is a duplicate, remove the old one in Settings -> Security.

## 5. Local configuration (local route only; skip if using GitHub Actions)

The GitHub workflow does not use `terraform.tfvars` (it is git-ignored and never reaches the runner). It passes the GitHub secrets/variables to Terraform as `TF_VAR_*` / `AWS_*` env vars.

- [ ] `cd environments/shared && cp terraform.tfvars.example terraform.tfvars` and fill in `coolify_ssh_public_key`, `base_domain = "novaej.com"`, `cloudflare_zone_id`. (`terraform.tfvars` is git-ignored.)
- [ ] Export the secrets in your shell (don't put them in tfvars):

  ```sh
  export TF_VAR_do_token="dop_v1_..."
  export TF_VAR_cloudflare_token="..."
  export AWS_ACCESS_KEY_ID="<shared-infra-terraform-state key id>"
  export AWS_SECRET_ACCESS_KEY="<its secret>"
  ```

## 6. Init, plan, apply

Expected plan: create the SSH key, droplet, reserved IP + assignment, firewall, project resources and one Cloudflare A record (`*.novaej.com`). Nothing destroyed.

### 6A. Via GitHub Actions (finish section 8 first)

- [ ] Open a throwaway PR touching a file under `modules/` or `environments/` (e.g. a comment). The `plan` job runs; read the plan in its log.
- [ ] Merge to `main`. `plan` runs again, then `apply` creates everything. (Or Actions -> Terraform -> Run workflow -> `apply` on `main`.)
- [ ] Read the reserved IP and the Coolify values at the end of the `apply` job log (`reserved_ip`, `coolify_server_settings` outputs).
- [ ] Failure at `init`: wrong Spaces key or endpoint. Failure at `plan` with a project lookup error: the DO Project name doesn't match `Shared Apps`.

### 6B. Locally (needs section 5)

- [ ] `terraform init` (connects to the Spaces backend; failure here = wrong endpoint or wrong key).
- [ ] `terraform plan`
- [ ] `terraform apply`
- [ ] `terraform output coolify_server_settings` and note the reserved IP.

### Verify the box (either route)

- [ ] Wait ~3-5 minutes for cloud-init, then:

  ```sh
  ssh root@<reserved-ip> 'cloud-init status --wait; ls /var/lib/cloud/shared-infra-provisioned; docker --version; docker compose version; swapon --show; sysctl vm.swappiness; systemctl is-active fail2ban; sshd -T | grep -E "^(permitrootlogin|passwordauthentication|allowusers|maxauthtries|logingracetime)"'
  ```

  This needs the matching **private** key on your machine (you can view it in Coolify -> Keys & Tokens; treat it as a secret and load it with `ssh-add`, don't commit it).
  If you'd rather not copy it out, skip this and rely on Coolify's *Validate Server* in section 7, then run the commands from Coolify's server terminal. Expected: `done`, Docker + Compose present, 2G swap, swappiness 10, fail2ban `active`, `permitrootlogin prohibit-password`, `passwordauthentication no`, `allowusers root`, `maxauthtries 3`, `logingracetime 30`.
- [ ] If provisioning looks wrong: `ssh root@<ip> 'tail -n 100 /var/log/cloud-init-output.log'`.

## 7. Add the server in Coolify Cloud

- [ ] Servers -> Add. Use the values from `terraform output coolify_server_settings`: name `shared-apps-1`, IP = reserved IP, port 22, user `root`, the key from section 4, wildcard domain `https://novaej.com` (Coolify only uses this to generate default app domains; you can set any `<name>.novaej.com` per app). Build server off.
- [ ] Click **Validate Server & Install Docker Engine**. It should find Docker already installed. Fix anything it flags.
- [ ] Confirm the proxy (Traefik) starts and ports 80/443 are bound.
- [ ] Smoke test: deploy any trivial app (or a static site), give it a domain like `hello.novaej.com`, and load it over HTTPS. Certificate errors point at section 3 (SSL mode).

## 8. (Optional) GitHub Actions

This is the GitHub route. Skip it if you run Terraform locally, and don't apply from both places.
The workflow is pushed disabled: every job is skipped until the repository variable `TERRAFORM_ENABLED` is `true`.
Do this section before 6A.

**When it runs** (once enabled): PR or push to `main` that changes files under `modules/**`, `environments/**` or the workflow file itself - docs-only changes never trigger it. PR -> plan only. Push to `main` -> plan, then apply. Manual runs (Actions -> Terraform -> Run workflow: `plan`, `apply`, `destroy`) ignore the path filter. The `ignore_changes` on the droplet means cloud-init edits won't rebuild the box.

Put **everything at repository level** (Settings -> Secrets and variables -> Actions). Do **not** put these in the Environments: the jobs run in two environments (`shared-infra`, `shared-infra-destroy`), and repository-level values are visible to both, while environment-level ones would need duplicating.

| Where | Name | Value |
|---|---|---|
| Repository secret | `DO_TOKEN` | DO API token (already set) |
| Repository secret | `CLOUDFLARE_TOKEN` | Cloudflare token (already set) |
| Repository secret | `SPACES_ACCESS_KEY_ID` | key ID of `shared-infra-terraform-state` |
| Repository secret | `SPACES_SECRET_ACCESS_KEY` | its secret |
| Repository variable | `COOLIFY_SSH_PUBLIC_KEY` | public key from Coolify (section 4) |
| Repository variable | `CLOUDFLARE_ZONE_ID` | zone ID |
| Repository variable | `BASE_DOMAIN` | `novaej.com` |
| Repository variable | `RESTRICT_HTTP_TO_CLOUDFLARE` | optional; `false` opens 80/443 to all |
| Repository variable | `TERRAFORM_ENABLED` | `true` only when ready to let the workflow run |

- [x] `DO_TOKEN` and `CLOUDFLARE_TOKEN` are set. Confirm they are *repository* secrets; if you created them inside an Environment, re-add them at repository level.
- [x] `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`, `COOLIFY_SSH_PUBLIC_KEY` and `CLOUDFLARE_ZONE_ID` are set.
- [ ] Add `BASE_DOMAIN` = `novaej.com` if you haven't (leave `TERRAFORM_ENABLED` unset until the environments below exist).
- [ ] Settings -> Environments -> **`shared-infra`**: create it with **no** required reviewers (used by PR plans and push applies). It holds no secrets.
- [ ] Settings -> Environments -> **`shared-infra-destroy`**: add yourself under *Required reviewers* (and a second person if you have one; on a personal repo you can approve your own runs unless you tick "prevent self-review"). Restrict deployment branches to `main`. It holds no secrets.
- [ ] When everything above is done, set `TERRAFORM_ENABLED=true`, then follow 6A.
- [ ] Behavior once enabled: PR -> plan; merge to `main` -> plan then apply; Actions -> Terraform -> Run workflow -> `destroy` -> approval 1, read the `plan -destroy` output, approval 2.

## 9. Create `shared-postgres` with S3 backups

- [ ] In Coolify: Project -> Environment -> New Resource -> Database -> PostgreSQL, on server `shared-apps-1`. Name `shared-postgres`. Pick a pinned major version (not `latest`).
- [ ] Don't enable "Make it publicly available" unless you need it; apps on the same Coolify destination network connect via the internal URL Coolify shows. Enable persistent storage (the default).
- [ ] Add the S3 destination: Coolify -> Storages (S3) -> Add:
  - Endpoint `https://nyc3.digitaloceanspaces.com` (match the bucket's region), Region `nyc3`, Bucket `shared-infra-storage`
  - Access key / secret: the `shared-infra-coolify-backups` key from section 2
  - Press Validate.
- [ ] On `shared-postgres` -> Backups -> Add: schedule (e.g. daily `0 3 * * *`), enable **Save to S3** with the destination above, set retention.
  Target location is `pg-backups/`. If your Coolify version has a path/prefix field, enter `pg-backups`; if it doesn't, Coolify writes its own folder structure at the bucket root. Check where the first backup lands (below) and adjust expectations rather than assuming.
- [ ] Press **Backup now**. In the Spaces UI, confirm a dump file appeared and its size is non-zero.

### Restore test (do this before any real data goes in)

- [ ] Create junk data: connect to the DB (Coolify terminal on the database, or `docker exec -it <pg-container> psql -U <user> -d <db>`) and run
      `CREATE TABLE restore_check (id int, note text); INSERT INTO restore_check VALUES (1, 'before backup');`
- [ ] Run **Backup now**; wait for success; confirm the new file in Spaces.
- [ ] Destroy the evidence: `DROP TABLE restore_check;`
- [ ] Restore the dump:
  - If your Coolify version has a Restore action on the backup, use it.
  - Otherwise download the file from Spaces to the droplet (or your laptop) and restore by hand. Coolify's Postgres dumps are typically `pg_dump` custom-format `.dmp` files:
    `docker exec -i <pg-container> pg_restore -U <user> -d <db> --clean --if-exists < pg-dump-file.dmp`
    (use `psql ... < file.sql` instead if the file is plain SQL; check the extension).
- [ ] Verify: `SELECT * FROM restore_check;` returns the row. Then `DROP TABLE restore_check;`.
- [ ] Note the exact working restore commands for your Coolify version in `DESTROY_AND_REBUILD.md` section 5. You don't want to discover them during an outage.

## Done when

`curl -I https://hello.novaej.com` works with a valid certificate, `shared-postgres` has a successful S3 backup, and the restore test passed.
