# Setup guide

How to bring `shared-infra` up from this repo. It explains **what to configure and where**, in order. The exact names and values of every secret, variable and setting are in [docs/deployment-reference.md](docs/deployment-reference.md); this guide doesn't repeat them.

Detailed procedures for each manual step are in [docs/manual-configuration.md](docs/manual-configuration.md), and the branching/PR rules in [docs/git-flow.md](docs/git-flow.md).

The repo already exists on GitHub with the workflow in place. What's left is the accounts, keys and settings around it, then a first apply, then Coolify.

**Order:** DigitalOcean -> Cloudflare -> Coolify key -> GitHub -> first deploy -> verify -> Coolify server -> Postgres.

Conventions: bucket `shared-infra-storage` (state in `tfstate/`, Postgres backups under `data/`, written by Coolify), DO Project `Shared Apps`, droplet `shared-apps-1`, domain `novaej.com`, apps at `<name>.novaej.com` (wildcard `*.novaej.com`; hyphens only, underscores aren't valid in hostnames).

---

## 1. DigitalOcean

You need four things, all created by hand (Terraform can't create the bucket that holds its own state):

- **An API token** (API -> Tokens, read+write). It becomes the GitHub secret `DO_TOKEN`.
- **A Project named `Shared Apps`.** Terraform looks it up by name and fails the plan if it's missing or spelled differently.
- **A Spaces bucket `shared-infra-storage` in nyc3**, private, no CDN. Leave it empty; Terraform writes `tfstate/` itself and Coolify writes the backups. Optionally enable versioning so an overwritten state file is recoverable.
- **Two limited Spaces keys.** They are *not* in the bucket's file browser. Go to the account-level API page, **Spaces Keys** tab (https://cloud.digitalocean.com/account/api/spaces), **Generate New Key**, choose **Limited Access**, select `shared-infra-storage`, grant Read/Write/Delete. The secret is shown once. Create:
  - `shared-infra-terraform-state` -> GitHub secrets `SPACES_ACCESS_KEY_ID` / `SPACES_SECRET_ACCESS_KEY` (Terraform reads them as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).
  - `shared-infra-coolify-backups` -> only ever pasted into Coolify (section 8).

  Keys are scoped per bucket, not per prefix, so both can technically reach `tfstate/` and `data/`. Two keys just let you revoke one independently.

## 2. Cloudflare

- **An API token** with `Zone : DNS : Edit` on the `novaej.com` zone -> GitHub secret `CLOUDFLARE_TOKEN`. Terraform needs it to create the wildcard record. You may reuse a token from another project if it covers this zone; a separate token per project limits the damage if one leaks.
- **The zone ID** (zone Overview page, right sidebar, API section) -> GitHub variable `CLOUDFLARE_ZONE_ID`. Not secret.
- **SSL/TLS -> Overview -> Full (strict).** The wildcard is proxied and Coolify's proxy serves real Let's Encrypt certificates, so strict is correct; Flexible causes redirect loops and Full skips validation. The mode is zone-wide: before switching, make sure other proxied sites on `novaej.com` have valid origin certificates, or they'll return 526.
- Nothing to do for the edge certificate: Universal SSL covers `*.novaej.com`, exactly the one-level `<name>.novaej.com` pattern. (A two-level pattern like `<name>.apps.novaej.com` would need paid Advanced Certificate Manager.)

Existing records (`www`, `api`, MX, other projects) keep working; explicit records win over the wildcard. Unclaimed names resolve to the droplet and get a 404 from Traefik.

**Let's Encrypt vs the firewall.** By default only Cloudflare's ranges can reach 80/443. HTTP-01 certificate issuance still works while the app's record is proxied, because the validator talks to Cloudflare. If you ever create a **DNS-only** record, issuance fails: set the GitHub variable `RESTRICT_HTTP_TO_CLOUDFLARE=false` (or `restrict_http_to_cloudflare = false` locally) and apply, which opens 80/443 to everyone. Port 22 is open to the world either way, since Coolify Cloud has no fixed IPs.

## 3. Coolify Cloud: the SSH key

Coolify connects to the droplet as **root** with a key it generates. Terraform only ever receives the public half; never generate keys in Terraform (the private key would land in state).

In Coolify Cloud: Keys & Tokens -> Private Keys -> Add -> generate an ED25519 key (name it `shared-apps-1`). Copy the **public key** (one line, `ssh-ed25519 AAAA...`) into the GitHub variable `COOLIFY_SSH_PUBLIC_KEY`. Don't paste the private key anywhere; the Terraform variable validates the format and rejects private keys.

DigitalOcean rejects a public key already registered in the account. If apply reports a duplicate, delete the stale key in Settings -> Security.

## 4. GitHub

The repo is https://github.com/pandc19/shared-infra. Configure it under Settings.

- **Secrets and variables -> Actions**, repository level (not inside Environments, because the jobs run in two environments and repository-level values are visible to both). The full list with values is in the [reference](docs/deployment-reference.md#github---secrets-variables-environments): secrets `DO_TOKEN`, `CLOUDFLARE_TOKEN`, `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY`; variables `COOLIFY_SSH_PUBLIC_KEY`, `CLOUDFLARE_ZONE_ID`, `BASE_DOMAIN`, and optionally `RESTRICT_HTTP_TO_CLOUDFLARE`.
- **Environments:** `shared-infra` with no reviewers (plan/apply), and `shared-infra-destroy` with required reviewers and deployment branches limited to `main`. Create the destroy one first and check its rule: if GitHub auto-creates it on first use, it has no reviewers and a destroy would run ungated. Neither environment holds secrets.
- **Variable `TERRAFORM_ENABLED`:** the kill switch. Every job is skipped unless it is `true`, so keep it `false` (or unset) until you want the workflow to run, and set it back to `false` when parking the project.

**When the workflow runs** once enabled: a PR or push to `main` that changes `modules/**`, `environments/**` or the workflow file (docs-only changes never trigger it). PR -> plan only. Push to `main` -> plan, then apply. Manual (Actions -> Terraform -> Run workflow) -> `plan`, `apply` or `destroy`, which ignores the path filter. Destroy needs two approvals: one before the `-destroy` plan, one after you've read it.

## 5. Running Terraform locally instead (optional)

Everything above works through GitHub. To run from a laptop instead, see "Running Terraform locally" in the reference: copy `environments/shared/terraform.tfvars.example` to `terraform.tfvars`, export `TF_VAR_do_token`, `TF_VAR_cloudflare_token`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, then `terraform init && terraform plan`. `terraform.tfvars` is git-ignored and never used by the workflow. Don't apply from both places at once.

## 6. First deploy

1. Set `TERRAFORM_ENABLED=true`.
2. Open a PR that touches a file under `modules/` or `environments/` (a comment is enough). The `plan` job runs and creates nothing. Read it: the expected plan is **7 to add, 0 to change, 0 to destroy** (SSH key, droplet, reserved IP, assignment, firewall, project resources, DNS record).
3. Merge. `plan` runs again, then `apply` builds everything. (Or run the workflow manually with `apply` on `main`.) The end of the `apply` log prints `reserved_ip` and `coolify_server_settings`.

If it fails:

| Symptom | Cause |
|---|---|
| `init` fails | wrong Spaces key, or bucket not in nyc3 (endpoint in `backend.tf`) |
| project lookup error | DO Project name isn't exactly `Shared Apps` |
| Cloudflare auth error | token doesn't cover the `novaej.com` zone |
| `422 Size is not available in this region` | DigitalOcean has no capacity for that size in that region right now. Wait, or change `region` / `droplet_size` in `environments/shared/variables.tf`. Changing the region replaces the reserved IP (free, automatic). This happened on 2026-10-18 with `s-1vcpu-1gb` in `nyc1`; the default is now `lon1`. |
| public key duplicate | see section 3 |

A failed apply leaves the resources that did get created (SSH key, reserved IP, DNS record) in state; re-running `apply` continues from there. To remove them instead, use the destroy path ([DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md)).

## 7. Verify the box

Wait 3-5 minutes for cloud-init. The simplest check is Coolify's *Validate Server* (next section), which proves SSH as root and Docker. For a direct check you need the matching private key locally (viewable in Coolify -> Keys & Tokens; load it with `ssh-add`, never commit it):

```sh
ssh root@<reserved-ip> 'cloud-init status --wait; ls /var/lib/cloud/shared-infra-provisioned; docker --version; docker compose version; swapon --show; sysctl vm.swappiness; systemctl is-active fail2ban; sshd -T | grep -E "^(permitrootlogin|passwordauthentication|allowusers|maxauthtries|logingracetime)"'
```

Expected: `done`, Docker and Compose present, 2G swap, swappiness 10, fail2ban `active`, `permitrootlogin prohibit-password`, `passwordauthentication no`, `allowusers root`, `maxauthtries 3`, `logingracetime 30`. If something looks wrong: `ssh root@<ip> 'tail -n 100 /var/log/cloud-init-output.log'`.

## 8. Coolify: add the server, then Postgres

**Server.** Servers -> Add, with the values from `terraform output coolify_server_settings` (the apply log): name `shared-apps-1`, IP = the reserved IP, port 22, user `root`, the key from section 3, wildcard domain `https://novaej.com` (only seeds default app domains; each app can use any `<name>.novaej.com`), build server off. Run **Validate Server & Install Docker Engine**; it should find Docker already installed. Confirm the proxy (Traefik) starts. Smoke test with a trivial app on `hello.novaej.com` over HTTPS; certificate trouble points back at the SSL mode in section 2.

**S3 destination.** Storages (S3) -> Add: endpoint `https://nyc3.digitaloceanspaces.com`, region `nyc3`, bucket `shared-infra-storage`, the `shared-infra-coolify-backups` key. Validate.

**shared-postgres.** New Resource -> Database -> PostgreSQL on `shared-apps-1`, name `shared-postgres`, a pinned major version (not `latest`), persistent storage on, not publicly exposed (apps on the same Coolify network use the internal URL). Under Backups, add a schedule (for example daily `0 3 * * *`), enable Save to S3 with the destination above, and set retention. Coolify has no prefix field: it writes its own folders at the bucket root, verified on 2026-10-18 as `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<db>-<timestamp>-<id>.dmp` (custom-format `pg_dump`). Run **Backup now** and confirm a non-empty file appears there. In Coolify the backup must have Save to S3 on **and** the destination selected on that schedule, otherwise it shows as local and nothing reaches Spaces. Suggested retention: keep 2 backups / 7 days locally (the droplet disk is small) and 14 backups / 30 days on S3.

**Restore test (before any real data).** Create a table with a row, back up, drop the table, restore, and check the row is back:

1. In the DB (Coolify terminal or `docker exec -it <pg-container> psql -U <user> -d <db>`): `CREATE TABLE restore_check (id int, note text); INSERT INTO restore_check VALUES (1, 'before backup');`
2. Backup now; confirm the new file in Spaces.
3. `DROP TABLE restore_check;`
4. Restore: use Coolify's Restore action on the backup if your version has one. Otherwise download the file and run `docker exec -i <pg-container> pg_restore -U <user> -d <db> --clean --if-exists < dump.dmp` (Coolify's dumps are typically `pg_dump` custom format; use `psql ... < file.sql` for plain SQL, check the extension).
5. `SELECT * FROM restore_check;` returns the row; then drop the table.
6. Write the exact working restore commands into [DESTROY_AND_REBUILD.md](DESTROY_AND_REBUILD.md) section 5 so you don't discover them during an outage.

## Done when

`https://hello.novaej.com` loads with a valid certificate, `shared-postgres` has a successful S3 backup, and the restore test passed.
