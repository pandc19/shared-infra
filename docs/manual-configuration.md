# Manual configuration

Everything Terraform does **not** do, with the steps. [SETUP.md](../SETUP.md) gives the order; names and values are in [deployment-reference.md](deployment-reference.md). Button names are from memory and may differ in your Coolify version.

## 1. DigitalOcean

- **Spaces bucket:** Spaces -> Create Bucket `shared-infra-storage`, region **NYC3**, private (restrict file listing), no CDN. Leave empty; Terraform writes `tfstate/`, Coolify writes `data/`.
- **Spaces keys:** control panel -> **API** -> **Spaces Keys** tab (not the bucket's file browser) -> Generate New Key -> **Limited Access**, bucket `shared-infra-storage`, Read/Write/Delete. The secret is shown once. Make two: `shared-infra-terraform-state` (GitHub secrets) and `shared-infra-coolify-backups` (Coolify only).
- **API token:** API -> Tokens, read+write -> GitHub secret `DO_TOKEN`.
- **Project:** a Project named exactly `Shared Apps` (Terraform only looks it up).
- **Capacity errors:** `422 Size is not available in this region` means DigitalOcean has no capacity for that size there. Change the `region`/`droplet_size` default in `environments/shared/variables.tf` via a PR. Changing region later replaces the droplet and wipes it.

## 2. Cloudflare

1. **Token:** My Profile -> API Tokens -> "Edit zone DNS" template, zone `novaej.com` only -> GitHub secret `CLOUDFLARE_TOKEN`.
2. **Zone ID:** zone Overview -> right sidebar -> GitHub variable `CLOUDFLARE_ZONE_ID`.
3. **SSL/TLS -> Overview -> Full (strict).** Zone-wide: other proxied sites on the zone need valid origin certificates or return 526.
4. Free Universal SSL covers `*.novaej.com` (one level, `<name>.novaej.com`); nothing to do. Two levels (`<name>.apps.novaej.com`) would need paid Advanced Certificate Manager.
5. Terraform creates the wildcard `*.novaej.com`. An explicit record (for example a leftover CNAME to an old host) wins over it: delete or repoint it at cutover.

## 3. GitHub

Secrets and variables go at **repository level** (Settings -> Secrets and variables -> Actions), not in Environments:

| Type | Names |
|---|---|
| secret | `DO_TOKEN`, `CLOUDFLARE_TOKEN`, `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY` |
| variable | `COOLIFY_SSH_PUBLIC_KEY`, `CLOUDFLARE_ZONE_ID`, `BASE_DOMAIN`, `TERRAFORM_ENABLED`, optional `RESTRICT_HTTP_TO_CLOUDFLARE` |

Environments, the `main` ruleset and security settings: [git-flow.md](git-flow.md#github-repository-settings).

## 4. Coolify Cloud

1. **SSH key:** Keys & Tokens -> Private Keys -> generate ED25519 (`shared-apps-1`). Copy the **public** line into GitHub variable `COOLIFY_SSH_PUBLIC_KEY`. The private key never leaves Coolify.
2. **Server:** after the apply, Servers -> Add: name `shared-apps-1`, IP = `reserved_ip` (from the `apply` log), port 22, user `root`, that key, wildcard domain `https://novaej.com` (only seeds default domains), build server off. **Validate Server & Install Docker Engine**. Docker is already installed by cloud-init, so the message just reports it. Validate 3-5 minutes after creation, or Coolify may race cloud-init.
3. **Proxy:** validation leaves "attention required". Server -> Proxy -> **Start Proxy** (Traefik).
4. **S3 destination:** Storages (S3) -> Add: endpoint `https://nyc3.digitaloceanspaces.com`, region `nyc3`, bucket `shared-infra-storage`, the `shared-infra-coolify-backups` key -> Validate.
5. **Postgres:** New Resource -> Database -> PostgreSQL, **server `shared-apps-1`** (bound for life), name `shared-postgres`, pinned major version, persistent storage on, **public access off**, SSL off (traffic stays on the droplet's Docker network; enable `require` later together with `ssl` in every app's connection config; mandatory if ever published).
6. **Backups:** on `shared-postgres` -> Backups:

   | Setting | Value |
   |---|---|
   | Frequency | `0 3 * * *` (daily, server time = UTC, 22:00 Ecuador the evening before) |
   | Save to S3 | **on, and the destination selected on this schedule** |
   | Databases | every app database, not only `postgres` |
   | Retention | local 2 backups / 7 days (small disk); S3 14 backups / 30 days |

   A backup labeled **local** was not uploaded: Save to S3 and the destination must both be set on the schedule. File path in Spaces: `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<db>-<timestamp>-<id>.dmp`. After the first scheduled runs, check old files are pruned.

## 5. Databases per app, restores, laptop access

Each app gets its own database and role; you load data by streaming a dump over SSH; backups are per database. All commands, in order and with where to run each: **[new-app-database.md](new-app-database.md)**.

**Restore test (once, before real data):** create a throwaway database, add it to the backup selection, add a row, back up, drop the table, restore that database's `.dmp` with `pg_restore -d <db> --clean --if-exists`, check the row. A `pg_dump` custom file holds **one** database, so each database restores from its own file. Record the working command in [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md).

## 6. GitHub source, cleanup, deploying an app

- **GitHub source (once per GitHub account or organization):** Sources -> add GitHub -> Register Now -> Install Repositories (only selected repos). Personal and organization accounts need separate sources. Details in [new-app.md](new-app.md#1-github-source-once-per-github-account-or-organization).
- **Docker cleanup (once):** Servers -> `shared-apps-1` -> Docker Cleanup: frequency `0 4 * * *`, trigger *Run on every schedule*, unused networks **delete**, application images **delete all old images**, unused volumes **keep**. Never delete unused volumes: the cleanup removes stopped containers first and then their volumes, so a stopped `shared-postgres` would lose its data.
- **Rollback images:** the per-app *Images to keep* (app -> Rollback) only works if the server's *Application images* cleanup option keeps retained images. With "Delete all old images" the page says *Disabled by the server* and you roll back by reverting in git and redeploying. Rolling back does not undo database migrations.
- **Disk watch:** see [Checking disk usage](#checking-disk-usage) below.
- **Adding an app:** follow [new-app.md](new-app.md). Always use *Private Repository (with GitHub App)*, never the deploy-key option; turn **Build Variable off** for secrets; test on a real hostname, not by IP.

## Checking disk usage

Run on the droplet (Coolify's server Terminal) after a few deploys, and whenever a build fails oddly.

```sh
df -h /                  # whole disk: watch the Use% column
docker system df         # what Docker is using, by type
docker system df -v      # per image / volume detail (long)
```

`docker system df` prints four rows:

| Row | Meaning | Action |
|---|---|---|
| Images | app and base images (`RECLAIMABLE` = unused by a running container) | the daily cleanup removes the reclaimable part |
| Containers | running and stopped containers | normally tiny |
| Local Volumes | **data**: `shared-postgres` lives here | never prune; cleanup must stay on *keep unused volumes* |
| Build Cache | BuildKit layer cache from builds on the droplet | the usual culprit if disk keeps growing |

If `df -h /` climbs toward 80% and Build Cache is large, free it (safe: it only makes the next build slower):

```sh
docker builder prune -af --filter until=72h
```

To do that automatically, add a root cron on the droplet (it lives outside Terraform, so re-add it after a rebuild): `0 4 * * * root docker builder prune -af --filter until=72h`. Set a DigitalOcean disk alert too (Monitoring -> Create Alert) so a full disk doesn't surprise you.
