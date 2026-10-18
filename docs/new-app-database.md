# New app database: create it, load a dump, back it up

Ordered procedure with where to run each step. Placeholders: `<app>` (app name), `<app>_app` (its DB role), `<ip>` (reserved IP: `terraform output reserved_ip`), `<pg>` (Postgres container name, step 4), `<dump>` (your dump file).

**Where:** 💻 laptop terminal · 🟦 Coolify terminal (Servers -> `shared-apps-1` -> Terminal; root shell on the droplet) · 🖥️ any shell on the droplet · ☁️ Coolify web UI.

---

## One-time: laptop SSH access

The Coolify key stays in Coolify, so your laptop needs its own key to reach the droplet.

**1. 💻 Create a key pair.** Private half stays on the laptop; the `.pub` half goes to the server.
```sh
ssh-keygen -t ed25519 -C "laptop-shared-apps" -f ~/.ssh/shared_apps_ed25519
cat ~/.ssh/shared_apps_ed25519.pub     # copy this one line
```

**2. 🟦 Authorize it.** Use `>>` (append; `>` overwrites and locks Coolify out) and spell `authorized_keys` with the final **s**.
```sh
echo 'ssh-ed25519 AAAA... laptop-shared-apps' >> /root/.ssh/authorized_keys
awk '{print $1, $NF}' /root/.ssh/authorized_keys     # expect 2 lines: Coolify's + yours
```

**3. 💻 Test.** `IdentitiesOnly` stops SSH offering other keys (the server allows 3 tries). Type `yes` at the host prompt, then `exit`.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip>
```
Run `ssh` from the laptop only; inside the droplet it SSHes to itself (undo: `ssh-keygen -R <ip>`).

---

## Per app

**4. 🟦 Find the Postgres container.** It's the long random ID (also in the backup path in Spaces, and the app's DB host). Others: `coolify-proxy`, `coolify-sentinel`.
```sh
docker ps --format '{{.Names}}'
```

**5. 🖥️ Check the version.** It must be >= the dump's source version (a Postgres 18 dump needs 17+, ideally 18).
```sh
docker exec <pg> psql -U postgres -tAc "select version()"
```

**6. 💻 Generate a password** and save it in a password manager (strips characters that break URLs).
```sh
openssl rand -base64 24 | tr -d '/+='
```

**7. 🖥️ Create the role and database.** Open `docker exec -it <pg> psql -U postgres`, then:
```sql
CREATE ROLE <app>_app LOGIN PASSWORD '<generated>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE <app> OWNER <app>_app;
REVOKE ALL ON DATABASE <app> FROM PUBLIC;   -- only the owner (and superusers) can connect
```
Once per older database, so app roles can't reach each other: `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;`. Exit with `\q`. Check: `docker exec <pg> psql -U postgres -c "\l <app>"`.

**8. 💻 Check the dump.** `--list` only reads the file, it creates nothing. You want `Format: CUSTOM`; if it errors, it's plain SQL (use the variant in step 9).
```sh
pg_restore --list <dump> | head
```

**9. 💻 Restore.** Streams the file over SSH; nothing is left on the droplet. Silence means success, and `--exit-on-error` stops at the first problem. It runs as the superuser (so extensions can install) but `--no-owner --role` makes `<app>_app` own everything.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip> \
  'docker exec -i <pg> pg_restore -U postgres -d <app> --no-owner --no-privileges --role=<app>_app --clean --if-exists --exit-on-error' \
  < <dump>
```
Plain SQL: replace the remote command with `docker exec -i <pg> psql -U postgres -d <app> -v ON_ERROR_STOP=1`.

**10. 💻 Verify.** All tables present, owner `<app>_app`, row counts match the source. Then run `ANALYZE;` in the database.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip> \
  'docker exec -i <pg> psql -U postgres -d <app> -c "\dt"'
```

**11. ☁️ Back it up.** `shared-postgres` -> Backups: add `<app>` to the databases to back up; **Save to S3** and the destination must both be set on the schedule. **Backup now**, then find `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-<app>-...dmp` in Spaces, non-zero size.

**12. ☁️ Connect the app.** Set its database URL in the app's environment variables, with the container name as host (same Coolify network, the default on one server):
```
postgresql://<app>_app:<password>@<pg>:5432/<app>
```
Prisma apps: deploy with `prisma migrate deploy`, never `migrate dev` or `migrate reset`.

---

## Restoring from a Spaces backup

Each database has its own `pg-dump-<db>-...dmp`. Two ways, and one rule:

- **Over SSH (any database):** download the file and use step 9 (`pg_restore ... -d <app>`). Use this for app databases and for dumps from other hosts.
- **Coolify's Import Backups button:** lets you search the S3 files and restores with `pg_restore --single-transaction --clean --if-exists` (all or nothing). The command is **not editable** and targets the container's default database (`POSTGRES_DB`, normally `postgres`), so don't use it for app databases: it would load them into `postgres`. Fine for checking a backup file, or for the default database. Changing `POSTGRES_DB` to redirect it is not worth it: it is also Coolify's default backup database and is used by its health checks.
- **Rule:** a restore only drops and recreates the objects that are in the dump; it does **not** empty the database. Extra tables stay. To make a database exactly match a backup, restore into an empty one (`DROP SCHEMA public CASCADE; CREATE SCHEMA public;` in that database, or drop and recreate it with its owner as in step 7).

## GUI client (DBeaver etc.)

Same laptop key. **SSH tab:** tunnel on, host `<ip>`, port 22, user `root`, auth Public Key, key `~/.ssh/shared_apps_ed25519`. **Main tab:** host = the container's IP (`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <pg>`), port `5432`, the app user and database. The container IP can change after a restart. Don't enable "publicly available" as a shortcut.

## Troubleshooting

| Symptom | Fix |
|---|---|
| One line in `authorized_keys` | The `echo` targeted `authorized_key` (no `s`). Redo step 2; `rm /root/.ssh/authorized_key`. |
| `Too many authentication failures` | Keep `-o IdentitiesOnly=yes -i <key>`. |
| Connection refused after repeated failures | fail2ban banned your IP (about an hour), or the droplet isn't up. |
| `unsupported version (1.16) in archive` | `shared-postgres` is older than the dump's source; recreate it on the same or a newer major version. |
| `role "..." does not exist` | Add `--no-owner --no-privileges` (already in step 9). |
| `permission denied for database` | Connect as `<app>_app`; step 7 removed access for everyone else. |
| Coolify terminal stops working | Its line was lost from `authorized_keys` (a `>` overwrite). Re-add its public key from Keys & Tokens. |
