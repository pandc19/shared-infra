# Destroy and rebuild runbook

Tear the box down, bring it back, restore Postgres and apps. Values: [docs/deployment-reference.md](docs/deployment-reference.md). First-time setup: [SETUP.md](SETUP.md).

## What a destroy loses

The droplet's disk, so **everything on it**: all `shared-postgres` databases, app volumes, containers, images, Coolify's proxy config on the box.

Survives: the Spaces bucket and its backups, Terraform state, Coolify's server/app/database *definitions*, the DO Project, Cloudflare zone and other records, the Coolify key, GitHub config.

A full destroy also removes the reserved IP and the wildcard record, so the rebuilt box gets a **new IP**. To keep the IP, replace only the droplet (last section).

## 1. Before you destroy: final backup

**Do not destroy until a final backup is confirmed in Spaces and you've downloaded a copy.** The data exists nowhere else.

1. Stop the apps in Coolify so nothing writes.
2. On `shared-postgres` -> Backups, **Backup now** (Save to S3). Check the new file in Spaces: fresh timestamp, non-zero size. **Every app database must have its own `pg-dump-<db>-...` file**; download them.
3. Optional second copy: `docker exec <pg> pg_dumpall -U postgres > all.sql` over SSH.
4. Copy out any app volumes that matter (Coolify -> app -> Persistent Storage) and any env vars you can't regenerate; Coolify keeps definitions, not volume contents.

## 2. Destroy

Actions -> Terraform -> Run workflow, branch `main`, action `destroy`. Approve `plan-destroy` (gate 1), read its `Plan: 0 to add, 0 to change, N to destroy` line, then approve `apply-destroy` (gate 2).

It runs only from `main`, only manually, and only while `TERRAFORM_ENABLED=true`. The two approvals exist only if the `shared-infra-destroy` environment has required reviewers; without them it runs ungated, so check first. Locally: `terraform plan -destroy`, then `terraform destroy`.

Untouched: the DO Project, the bucket, the Cloudflare zone and other records, GitHub config. Afterwards the state is empty; set `TERRAFORM_ENABLED=false` while parked so a push can't re-apply.

## 3. Recreate

Set `TERRAFORM_ENABLED=true`, run the workflow with `apply` on `main`. The new reserved IP and wildcard are created together; `COOLIFY_SSH_PUBLIC_KEY` is unchanged, so the same Coolify key works (delete a stale duplicate key in DigitalOcean if it complains). Read `reserved_ip` from the log, wait for cloud-init, verify per [SETUP.md](SETUP.md) section 6. Capacity errors: SETUP.md section 5.

## 4. Re-add the server in Coolify

Same IP (after a replace): open the server entry and **Validate Server**. New IP: edit the IP first and accept the new SSH host key, or delete the entry and add a new one ([manual-configuration.md](docs/manual-configuration.md#4-coolify-cloud)). Then start the proxy and **redeploy** every app: definitions survive, containers and volumes don't. Recreate `shared-postgres` as a fresh resource if needed.

## 5. Restore Postgres

1. Check the S3 destination still validates. Recreate `shared-postgres` with the **same major version** (or newer) and wait until it runs.
2. Recreate each app's role and database ([new-app-database.md](docs/new-app-database.md) steps 4-6). Roles and databases live inside Postgres, so they are not recreated by Terraform.
3. For each app, restore its latest file from `data/coolify/backups/databases/<team>/shared-postgres-<id>/` in Spaces: Coolify's Restore action if your version has one, otherwise download the `.dmp` and use steps R1-R4 of [new-app-database.md](docs/new-app-database.md) (`pg_restore` over SSH).
4. Verify tables and row counts per database, re-enable the backup schedule, run **Backup now**, redeploy the apps, and check each URL over HTTPS.

Verified once (2026-10-18): a custom-format dump from Postgres 18 restored into `shared-postgres` 18.6; it printed nothing and every table came back owned by the app role.

## Moving to another region (for example `lon1` -> `nyc1`)

Region is a force-new attribute: the droplet **and** the reserved IP are replaced, so you get a new IP, an empty disk, and downtime. The firewall, SSH key, project attachment and the wildcard record are updated in the same apply (the record points at the new IP). Do it when little is running, and treat it like a destroy and rebuild:

1. **Back up** every database and download the files (section 1). Stop the apps in Coolify so nothing writes.
2. **Change the default** `region` in `environments/shared/variables.tf` through a PR. The `plan` must show `digitalocean_droplet` and `digitalocean_reserved_ip` as `must be replaced` and nothing else surprising; confirm a `s-1vcpu-1gb` is available there first (DigitalOcean's Create Droplet page).
3. **Merge.** The apply replaces the droplet and IP and prints the new `reserved_ip`. Terraform **destroys the old droplet before creating the new one**, so if the new region has no capacity you are left with no droplet (the same `422 Size is not available` you hit before). That is why step 2 says to confirm availability first and step 1 to have the dumps downloaded. If it does fail, revert the region in a PR (or wait) and re-run `apply`.
4. **Rebuild on top of it:** wait for cloud-init and verify ([SETUP.md](SETUP.md) section 6), edit the Coolify server's IP and **Validate** it (accept the new host key), start the proxy, re-add your laptop SSH key ([new-app-database.md](docs/new-app-database.md) steps 1-3), then restore each database (section 5), recreate roles first, and redeploy each app ([new-app.md](docs/new-app.md)).
5. Check each app's URL, run a **Backup now**, and re-check cleanup settings and any cron you added by hand (they are lost with the old disk).

A droplet in a farther region adds latency to Spaces backups (the bucket stays in nyc3), which is fine.

## Replacing the droplet but keeping the IP

Replace only the droplet; the reserved IP, DNS, firewall and project attachment stay and the Coolify entry keeps working. The disk is still wiped: do sections 1, 4 and 5 around it. Run it **locally** (CI can't pass `-replace`):

```sh
cd environments/shared
terraform apply -replace='module.shared.digitalocean_droplet.this'
```

This is also the only way cloud-init changes take effect: the droplet has `ignore_changes = [user_data, ssh_keys]` on purpose, so an innocent cloud-init or key edit in a PR can't plan a destroy-and-recreate and wipe Postgres.

**Rotating the Coolify key without a rebuild:** add the new public key to `/root/.ssh/authorized_keys`, switch the server to it in Coolify and validate, remove the old line, then update `COOLIFY_SSH_PUBLIC_KEY`. Your own extra laptop keys are outside Terraform and are lost on a rebuild; add them again.
