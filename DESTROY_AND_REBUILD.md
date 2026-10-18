# Destroy and rebuild runbook

How to tear the box down, bring it back, and get Postgres and the apps running again. Names and values are in [docs/deployment-reference.md](docs/deployment-reference.md); first-time setup is in [SETUP.md](SETUP.md).

## What a destroy loses

Destroying the droplet deletes its disk, so **everything on the box is gone**: the `shared-postgres` data (all databases), every app's Docker volumes, Coolify's proxy config on the box, deployed containers and images, and local logs.

What survives: the Spaces bucket and its backups (Terraform doesn't manage it), the Terraform state, your Coolify Cloud account with its server/app/database *definitions*, the DO Project, the Cloudflare zone and its other records, the SSH key inside Coolify, and the GitHub secrets and variables.

A full destroy also removes the reserved IP and the wildcard DNS record, so the rebuilt box gets a **new IP**. If you only want a fresh droplet on the **same IP**, do a replace instead (last section).

## 1. Before you destroy: take a final backup

**Do not destroy until a final Postgres backup is confirmed in Spaces and you've downloaded a copy.** The data exists nowhere else.

Stop the apps in Coolify first so nothing writes during the dump. Then, on `shared-postgres` -> Backups, run **Backup now** with Save to S3 enabled and wait for it to succeed. Open the `shared-infra-storage` bucket and check that the new file has a fresh timestamp and a non-zero size; download a copy to your laptop as well. If you want a second, independent dump, pull a plain one over SSH with `docker exec <pg-container> pg_dumpall -U <user>` redirected to a local file.

Back up anything else that has state. For each app, copy out whatever matters from its Persistent Storage in Coolify, and keep a copy of any env vars or secrets you can't regenerate: Coolify keeps the definitions, but not the contents of the volumes.

## 2. Destroy

The normal route is the workflow (it was used on 2026-10-18 to clean up a failed first apply). Go to Actions -> Terraform -> Run workflow, pick branch `main`, action `destroy`. You'll be asked to approve twice: first the `plan-destroy` job, then, after reading its log, `apply-destroy`. Check the plan line (`Plan: 0 to add, 0 to change, N to destroy`) matches what you expect before the second approval.

A destroy can only start from `main`, only while the repository variable `TERRAFORM_ENABLED` is `true`, and only through a manual run; pushes and PRs can never trigger one. The two approvals exist only if the `shared-infra-destroy` Environment has its required-reviewer rule. Without the rule the jobs run with no approval at all, so check it before relying on this.

To destroy locally instead, run `terraform plan -destroy` in `environments/shared`, read it, then `terraform destroy`.

The DO Project (only looked up), the bucket, the Cloudflare zone and its other records, and the GitHub configuration are untouched. Afterwards the state is empty. Set `TERRAFORM_ENABLED=false` while the project is parked so an accidental push can't re-apply.

## 3. Recreate

Set `TERRAFORM_ENABLED=true` if you turned it off, then run the workflow with `apply` on `main` (or `terraform apply` locally). The new reserved IP and the wildcard record are created together. The Coolify public key in `COOLIFY_SSH_PUBLIC_KEY` is unchanged, so the new droplet accepts the same Coolify key; if DigitalOcean complains the key already exists, delete the stale entry in Settings -> Security.

When the apply finishes, read the new `reserved_ip` from its log, wait for cloud-init, and run the verification from [SETUP.md](SETUP.md) section 7. If the apply fails on capacity (`Size is not available in this region`), see the failure table in SETUP.md section 6.

## 4. Re-add the server in Coolify

After a replace that kept the IP, the existing Coolify server entry still works: open it and run **Validate Server**, which reinstalls the proxy. After a full destroy the IP changed, so edit the server's IP to the new one first (clear the old SSH host key if Coolify prompts, because the new droplet has a different one), or delete the old entry once its resources are moved or removed and add a new one as in SETUP.md section 8.

Either way, confirm Traefik is running, then redeploy each app: their definitions are in Coolify, but the containers and volumes are gone. `shared-postgres` may need to be recreated as a fresh database resource on the new server.

## 5. Restore Postgres from Spaces

First make sure the S3 storage entry for `shared-infra-storage` still validates in Coolify. Recreate `shared-postgres` on the new server with the **same major version and the same user and database names** as before, and wait until it's running.

Then get the dump: the latest file in `shared-infra-storage`, under `data/coolify/backups/databases/<team>/shared-postgres-<id>/` (files named `pg-dump-<db>-<timestamp>-<id>.dmp`). Restore it with Coolify's Restore action if your version has one for backups and S3 files. Otherwise download the file to the droplet (`scp`, or `curl` a pre-signed URL) or your laptop and run `docker exec -i <pg-container> pg_restore -U <user> -d <db> --clean --if-exists < dump.dmp`. Coolify's `.dmp` files are `pg_dump` custom format, so `pg_restore` is the right tool, not `psql`.

The exact commands you verified in the restore test (SETUP.md section 8) belong here, so you don't have to rediscover them during an outage: `____`

Before pointing apps at the restored database, check row counts or a known record in each database. Then re-enable the backup schedule on the new database resource and run **Backup now** once to confirm S3 still works. Finally redeploy the apps and check each URL over HTTPS.

## Replacing the droplet but keeping the IP

To rebuild just the box, keeping the reserved IP, DNS, firewall and project attachment, replace only the droplet. Only the droplet and the reserved IP assignment change; the Coolify server entry keeps working. The disk is still wiped, so do the backup (section 1), re-add (section 4) and restore (section 5) around it.

```sh
cd environments/shared
terraform apply -replace='module.shared.digitalocean_droplet.this'
```

This has to run locally: a manual workflow `apply` can't pass `-replace`.

This is also the only way cloud-init changes take effect. The droplet has `ignore_changes = [user_data, ssh_keys]` on purpose: without it, any edit to `cloud-init.yaml.tftpl` or the Coolify public key would make Terraform plan a destroy and recreate, wiping Postgres on an innocent PR.

### Rotating the Coolify SSH key without a rebuild

Add the new public key to `/root/.ssh/authorized_keys` on the droplet through the existing key, switch the server to the new key in Coolify and validate it, then remove the old line and update `COOLIFY_SSH_PUBLIC_KEY` (and `coolify_ssh_public_key` if you use tfvars). Because of the `ignore_changes` on `ssh_keys`, Terraform won't try to replace the droplet.
