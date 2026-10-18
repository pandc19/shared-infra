# Destroy and rebuild runbook

## What a destroy loses

Destroying the droplet deletes its disk. **Everything on the box is gone**, including:

- the `shared-postgres` data (all databases) and every app's Docker volumes,
- Coolify's proxy config on the box, deployed containers and images, local logs.

What survives: the Spaces bucket and its backups (not managed by Terraform), the
Terraform state, your Coolify Cloud account and its server/app/database *definitions*, the DO Project,
the Cloudflare zone, and the SSH key in Coolify.

`terraform destroy` also removes the reserved IP and the wildcard DNS record. If you only want a new
droplet but the **same IP**, do a replace (section 6) instead of a destroy.

## 1. Before you destroy: final backup

- [ ] In Coolify: `shared-postgres` -> Backups -> **Backup now** with Save to S3 enabled. Wait for success.
- [ ] Open Spaces (`shared-infra-storage`) and confirm the new file's timestamp and non-zero size. Download a copy to your laptop too.
- [ ] Stop writes first if apps are live (stop the apps in Coolify) so the dump is final.
- [ ] Back up anything else with state: app volumes (Coolify -> the app -> Persistent Storage; copy out what matters), and record env vars/secrets for each app (Coolify keeps definitions, but export a copy of anything you can't regenerate).
- [ ] Optional paranoia: `ssh root@<ip> 'docker exec <pg-container> pg_dumpall -U <user>' > shared-postgres-final.sql`

## 2. Destroy

Locally: `cd environments/shared && terraform plan -destroy`, read it, then `terraform destroy`.

Or via GitHub: Actions -> Terraform -> Run workflow -> action `destroy`. Approve the `plan-destroy` job,
read the plan in its log, then approve `apply-destroy`. Only run it from `main`.

Not touched by destroy: the DO Project (only looked up), the bucket, Cloudflare zone and other DNS records.

## 3. Recreate

- [ ] `terraform apply` (or run the workflow with `apply`). A destroy+apply gives a **new reserved IP**; the wildcard record is recreated pointing at it.
- [ ] Reuse the same Coolify key. `coolify_ssh_public_key` is unchanged. If DigitalOcean complains the key already exists, delete the stale entry in Settings -> Security.
- [ ] Wait for cloud-init and run the verification command in SETUP.md section 6.
- [ ] Note the new IP: `terraform output reserved_ip`.

## 4. Re-add the server in Coolify

Two options:

- **Same Coolify server entry (preferred if the IP stayed the same, e.g. after a replace):** the entry still works. Open it and press **Validate Server**, which reinstalls the proxy.
  If the IP changed, edit the server's IP to the new one first. Also clear the old host key if prompted. The new droplet has a different SSH host key.
- **New entry:** delete the old server in Coolify (after moving or removing its resources) and add a new one as in SETUP.md section 7.

Then: Validate, check Traefik is running, and **redeploy** each app. Their definitions are in Coolify, but the containers and volumes are gone.
Recreate `shared-postgres` if it was tied to the old server (Coolify may need a fresh database resource on the new server).

## 5. Restore Postgres from Spaces

- [ ] Make sure the S3 storage entry (`shared-infra-storage`) still validates in Coolify.
- [ ] Recreate `shared-postgres` on the new server with the **same major version and the same DB user/name** as before, and wait until it is running.
- [ ] Get the dump: the latest file in `shared-infra-storage` (under `pg-backups/` or wherever Coolify placed it, see SETUP.md section 9). Download it to the droplet (`scp`, or `curl` a pre-signed URL) or to your laptop.
- [ ] Restore:
  - If Coolify offers Restore on the backup/S3 file, use it.
  - Otherwise: `docker exec -i <pg-container> pg_restore -U <user> -d <db> --clean --if-exists < dump.dmp` (or `psql -U <user> -d <db> < dump.sql` for plain SQL).
  - Fill in the exact commands you verified during the SETUP.md restore test here: `____`
- [ ] Verify row counts or a known record in each database before pointing apps at it.
- [ ] Re-enable the backup schedule on the new database resource and run **Backup now** once to confirm S3 still works.
- [ ] Redeploy apps, check each URL over HTTPS.

## 6. Replace the droplet but keep the IP

For rebuilding the box without changing the IP or DNS:

```sh
cd environments/shared
terraform apply -replace='module.shared.digitalocean_droplet.this'
```

The reserved IP, firewall, DNS record and project attachment survive (only the droplet and the reserved IP assignment change), and the Coolify server entry keeps working. The data on the disk is still lost, so do sections 1, 4 and 5 around it.

**Why edits don't rebuild automatically:** the droplet has `ignore_changes = [user_data, ssh_keys]`. Without that, any edit to `cloud-init.yaml.tftpl` or the Coolify public key would make Terraform plan a
destroy+create of the droplet and wipe Postgres. Cloud-init changes only take effect on a droplet you deliberately replace as above.

### Rotating the Coolify SSH key without a rebuild

Add the new public key to `/root/.ssh/authorized_keys` on the droplet (via an existing key), switch the server to the new key in Coolify and validate, remove the old line, then update `coolify_ssh_public_key`.
(The `ignore_changes` on `ssh_keys` means Terraform won't try to replace the droplet.)
