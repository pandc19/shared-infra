# Manual configuration, step by step

Everything in this project that Terraform does **not** do, with the exact steps. [SETUP.md](../SETUP.md) gives the order for a first bring-up; this file is the detailed procedure for each manual piece, so you can repeat or audit it. Names and values are in [deployment-reference.md](deployment-reference.md).

Coolify's screens change between versions and I wrote some labels from memory, so treat button names as approximate.

---

## 1. DigitalOcean

### Spaces bucket
Spaces Object Storage -> Create Bucket: name `shared-infra-storage`, region **NYC3**, **Restrict File Listing** (private), no CDN. Leave it empty. `tfstate/` is written by Terraform and `data/` by Coolify's backups.

### Spaces keys
Not in the bucket's file browser. Control panel -> **API** -> **Spaces Keys** tab -> **Generate New Key** -> **Limited Access**, bucket `shared-infra-storage`, **Read/Write/Delete**. The secret is shown once. Make two keys:
`shared-infra-terraform-state` (GitHub secrets) and `shared-infra-coolify-backups` (Coolify only).

### API token and Project
API -> Tokens -> Generate New Token (read+write) -> GitHub secret `DO_TOKEN`. Projects -> New Project named exactly `Shared Apps`.

### Region and size
If the apply fails with `422 Size is not available in this region`, DigitalOcean is out of capacity for that size there. The default is `lon1` (London) because `nyc1` was out on 2026-10-18. Change `region` or `droplet_size` defaults in `environments/shared/variables.tf` through a PR. Changing the region later replaces the droplet and reserved IP and wipes the box.

## 2. Cloudflare

1. **API token:** My Profile -> API Tokens -> Create Token -> template "Edit zone DNS", zone `novaej.com` only -> GitHub secret `CLOUDFLARE_TOKEN`.
2. **Zone ID:** zone Overview page -> right sidebar, API section -> GitHub variable `CLOUDFLARE_ZONE_ID`.
3. **SSL/TLS -> Overview -> Full (strict).** Zone-wide. Other proxied sites on `novaej.com` must have valid origin certificates (Render issues its own) or they return 526.
4. Free Universal SSL covers `*.novaej.com`, which is the one-level `<name>.novaej.com` pattern used here. Nothing to do.
5. The wildcard `*.novaej.com` is created by Terraform. An explicit record for a name (for example a leftover CNAME to Render) **wins over the wildcard**, so remove or repoint it at cutover.

## 3. GitHub

Settings -> Secrets and variables -> Actions, **repository level** (not in Environments):

| Type | Name |
|---|---|
| secret | `DO_TOKEN`, `CLOUDFLARE_TOKEN`, `SPACES_ACCESS_KEY_ID`, `SPACES_SECRET_ACCESS_KEY` |
| variable | `COOLIFY_SSH_PUBLIC_KEY`, `CLOUDFLARE_ZONE_ID`, `BASE_DOMAIN`, `TERRAFORM_ENABLED`, optional `RESTRICT_HTTP_TO_CLOUDFLARE` |

Then Environments (`shared-infra`, `shared-infra-destroy` with reviewers) and the `main` ruleset, merge settings and security settings, all in [git-flow.md](git-flow.md#github-repository-settings).

## 4. Coolify Cloud

### SSH key
Keys & Tokens -> Private Keys -> Add -> **Generate new ED25519 SSH key**, name `shared-apps-1`. Copy the **public** line (`ssh-ed25519 AAAA...`) into GitHub variable `COOLIFY_SSH_PUBLIC_KEY`. Never put the private key anywhere else.

### Add the server
After the apply, take `reserved_ip` from the `apply` job log. Servers -> Add: name `shared-apps-1`, IP, port `22`, user `root`, the key above, wildcard domain `https://novaej.com` (only seeds default domains), build server off. Click **Validate Server & Install Docker Engine**. Docker is already installed by cloud-init; the success message just reports it. (Validate only after cloud-init finishes, 3-5 minutes after creation, or Coolify may race it and install Docker itself.)

### Start the proxy
Validation leaves the server flagged "attention required". Server -> **Proxy** -> **Start Proxy** (Traefik). The status turns Running and the flag clears.

### S3 destination
Storages (S3) -> Add: endpoint `https://nyc3.digitaloceanspaces.com`, region `nyc3`, bucket `shared-infra-storage`, the `shared-infra-coolify-backups` key. **Validate.**

### Postgres
In a project and environment: New Resource -> Database -> PostgreSQL, **select server `shared-apps-1`** when asked (a database is bound to one server), default destination network. Name `shared-postgres`, a pinned major version, persistent storage on, **Make it publicly available: off**, SSL: off for now. Start it.

Why SSL is off: apps on the same server reach it over the internal Docker network and the traffic never leaves the droplet. Enable `require` later together with `ssl` in each app's connection settings; a one-sided change breaks connections. SSL becomes mandatory if the database is ever published.

### Backups
On `shared-postgres` -> Backups -> add a schedule:

| Setting | Value |
|---|---|
| Frequency | `0 3 * * *` (daily, server time = UTC, which is 22:00 Ecuador the evening before) |
| Save to S3 | **on, and the `shared-infra-storage` destination selected on this schedule** |
| Databases to back up | every app database (see section 6); not only `postgres` |
| Local retention | 2 backups / 7 days (the droplet disk is small) |
| S3 retention | 14 backups / 30 days |

Gotcha: a backup row that says **local** was not uploaded. Save to S3 and the destination must both be set on the schedule itself; having the destination under Storages is not enough. Run **Backup now** and confirm the file in Spaces at `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<db>-<timestamp>-<id>.dmp`. Check again after the first scheduled run that old files are pruned.

## 5. Restore test (per database)

Do this with throwaway data before any real data matters (and before DNS cutover of any app).

1. Create a database `restore_test` (section 6 steps 1-3) and add it to the backup selection.
2. In it: `CREATE TABLE t (id int, note text); INSERT INTO t VALUES (1, 'before backup');`
3. **Backup now**; confirm a `pg-dump-restore_test-...` file in Spaces.
4. `DROP TABLE t;`
5. Restore. Use Coolify's Restore action if your version has one; otherwise get the file onto the droplet and run
   `docker exec -i <pg-container> pg_restore -U <user> -d restore_test --clean --if-exists < file.dmp`
   (a `pg_dump` custom-format file holds **one** database, so each database is restored with its own file and its own `-d`; create the target database first with `createdb` if it doesn't exist).
6. `SELECT * FROM t;` returns the row. Drop the `restore_test` database.
7. Write the command that worked into [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) section 5.

## 6. One database and one role per app

Every app gets its **own database and its own login role**, so a bug or leaked password in one app can't read another's data. Coolify's default user (`postgres`) is a superuser and is for admin work only; apps never use it. Naming: role `<app>_app`, database `<app>`.

1. **Generate the password on your laptop** and save it in a password manager. This strips characters that break connection URLs:
   `openssl rand -base64 24 | tr -d '/+='`
2. **Open a superuser session**: Coolify's terminal on the `shared-postgres` page, then `psql -U postgres`; or DBeaver (section 7); or `ssh ... 'docker exec -it <container> psql -U postgres'`.
3. **Create the role and database** (example for poketrain):

   ```sql
   CREATE ROLE poketrain_app LOGIN PASSWORD '<generated>'
     NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;

   CREATE DATABASE poketrain OWNER poketrain_app;

   -- nobody but the owner (and superusers) can connect to this DB
   REVOKE ALL ON DATABASE poketrain FROM PUBLIC;
   ```

4. **Lock down the databases that already exist.** Postgres lets any role connect to any database by default, so without this each app role could reach the others. Run once for each pre-existing database (`postgres`, and any made before this procedure):
   `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;`
   Every new database created with step 3 is already locked.
5. **Add the database to the backup selection** on `shared-postgres` -> Backups, so it gets its own `pg-dump-<db>-...` file. Verify it appears in Spaces after the next run.
6. **Give the app its connection settings** in Coolify's environment variables: host = the Postgres **internal** host Coolify shows for the database (the container's name), port `5432`, user `poketrain_app`, the generated password, database `poketrain`. URL-form: `postgresql://poketrain_app:<password>@<internal-host>:5432/poketrain`. The app must be on the same Coolify destination network as the database (the default for apps on the same server).
7. **Record it** in the list of databases and owning apps in [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) so a rebuild knows what to recreate. Roles and databases live inside Postgres, so they are recreated by repeating these steps, or come back with a restore only if the backup includes them.

Restoring a dump into an app database is in section 6a.

## 6a. Restoring a dump from your laptop into an app database

For a dump file on your laptop (a migration from Render, or a downloaded Spaces backup). The Coolify terminal can't take file uploads, so stream the file over SSH using the laptop key from section 7; nothing is left on the droplet.

1. **Check the format and version.**
   - `pg_restore --list poketrain.dump | head` works for custom-format dumps (made with `pg_dump -Fc`, and what Coolify's `.dmp` files are). If it errors, it is probably plain SQL (`head poketrain.dump` shows `CREATE TABLE`/`COPY` text).
   - The dump's source Postgres version must be **<= `shared-postgres`'s major version**, or the restore may fail.
2. **Make sure the target exists and is empty** (section 6, steps 3-4), and find the container name on the droplet with `docker ps --format '{{.Names}}'`.
3. **Custom-format dump, run from your laptop:**

   ```sh
   ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<reserved-ip> \
     'docker exec -i <pg-container> pg_restore -U postgres -d poketrain --no-owner --no-privileges --role=poketrain_app --clean --if-exists --exit-on-error' \
     < poketrain.dump
   ```

   It connects as the superuser (extensions like `pgcrypto` or `uuid-ossp` need that), but `--no-owner --role=poketrain_app` makes every restored object owned by the app role instead of the source database's owner (Render's role names won't exist here). `--no-privileges` skips source GRANTs.
   **Plain SQL dump:**

   ```sh
   ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<reserved-ip> \
     'docker exec -i <pg-container> psql -U postgres -d poketrain -v ON_ERROR_STOP=1' < poketrain.sql
   ```

   If a plain dump has owner statements, regenerate it with `pg_dump --no-owner --no-acl`, or fix ownership afterward with `REASSIGN OWNED BY <old-role> TO poketrain_app;`.
4. **Verify** as the app role, not just as the superuser:
   `ssh ... 'docker exec -it <pg-container> psql -U poketrain_app -d poketrain -c "\dt"'` (you may be prompted for the password), then compare row counts of a few tables against the source.
5. Run `ANALYZE;` in the database so query plans are right after a bulk load, and run **Backup now** to capture the restored state.

If you'd rather not use SSH, upload the file to a private Spaces path, download it on the droplet with a pre-signed URL (`s3cmd signurl` or the DO console), and run the same `pg_restore` with `< file` on the droplet. Delete the file afterward.

## 7. Connecting from your laptop (DBeaver)

The database has no public port and the firewall only allows 22, 80 and 443, so you go **through SSH**. The Coolify private key stays in Coolify, so your laptop needs its own key.

**What "the public key step" means.** An SSH key is a pair. The *private* half stays secret on your laptop; the *public* half is a line of text you put on the server, which then lets anyone holding the private half log in. So: make a pair on your laptop, copy the public line into the droplet's `authorized_keys`.

1. On your laptop make a dedicated key (use a new one, not your Comprobify keys):
   `ssh-keygen -t ed25519 -C "laptop-shared-apps" -f ~/.ssh/shared_apps_ed25519`
   Print the public half: `cat ~/.ssh/shared_apps_ed25519.pub` (one line starting `ssh-ed25519`).
2. Put it on the droplet using something that already has access, Coolify's server **Terminal**: `echo 'ssh-ed25519 AAAA... laptop-shared-apps' >> /root/.ssh/authorized_keys`. The DigitalOcean web console won't work: password login is off.
3. Test from the laptop (the `-o IdentitiesOnly=yes` stops your agent offering other keys; sshd allows only 3 tries and fail2ban bans repeated failures):
   `ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<reserved-ip>`
4. Find the database container's internal IP (on the droplet):
   `docker ps --filter name=<database-uuid> --format '{{.Names}}'` then
   `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <container>`
5. In DBeaver: new PostgreSQL connection. **Main** tab: host = that container IP, port `5432`, the app's user/password/database. **SSH** tab: enable "Use SSH Tunnel", host = reserved IP, port 22, user `root`, auth "Public Key", private key `~/.ssh/shared_apps_ed25519`. Test connection.

Notes: the container IP can change when the database restarts; if DBeaver stops connecting, repeat step 4. Your extra key is outside Terraform and is lost if the droplet is replaced, so add it again after a rebuild. For a quick shell without DBeaver: `ssh -t root@<ip> 'docker exec -it <container> psql -U <user> -d <db>'`. Don't switch on "publicly available" as a shortcut.

## 8. Deploying an app (example: poketrain)

1. Coolify -> Sources -> add a GitHub App and grant it the app's repo.
2. Create the app's database and role (section 6).
3. New Resource -> Application -> from the GitHub source, repo and branch `main`, server `shared-apps-1`, build pack (Dockerfile or Nixpacks), domain `https://poketrain.novaej.com`.
4. Environment Variables -> bulk "Developer view" -> paste the app's `.env` (never commit it). Runtime variables live in Coolify, not GitHub; mark build-time ones as build variables.
5. Turn on **auto-deploy**; with the GitHub App a push to `main` triggers it. Make the app repo's checks required in its own `main` ruleset so only reviewed, tested code reaches `main`.
6. Test before changing DNS: Coolify's temporary URL, or a hosts-file entry pointing the hostname at the reserved IP.
7. Migrate data (`pg_dump` from the old host, `pg_restore` into the app database), complete the restore test (section 5), then **cut over**: delete or repoint the old CNAME (Render) so `poketrain.novaej.com` resolves through the wildcard, proxied. Keep the old host a few days as a fallback.
8. Watch the first scheduled backup and confirm the app's database is in it.

A 1 GB droplet builds Docker images slowly and can run out of memory (2G swap helps). If builds fail with OOM, resize the droplet or build elsewhere.
