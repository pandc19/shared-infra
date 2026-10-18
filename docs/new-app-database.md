# New app database: create it, load a dump, back it up

The ordered procedure used for poketrain, with where to run each step. Replace the example names (`poketrain`, `poketrain_app`, `poketrain.dump`) for another app. Background and reasoning: [manual-configuration.md](manual-configuration.md) sections 6, 6a and 7.

**Where:** 💻 = your laptop terminal. 🟦 = Coolify's terminal (Servers -> `shared-apps-1` -> Terminal; a root shell on the droplet). 🖥️ = a shell on the droplet (Coolify's terminal, or after SSH). ☁️ = Coolify web UI.

`<ip>` = the reserved IP (`terraform output reserved_ip`, or the `apply` log). `<pg>` = the Postgres container name (step 4).

---

## One-time: laptop SSH access (skip if already done)

The Coolify key stays in Coolify, so your laptop needs its own key to stream files to the droplet.

**1. 💻 Create a key pair.** The private half stays on the laptop; the public `.pub` half goes to the server.
```sh
ssh-keygen -t ed25519 -C "laptop-shared-apps" -f ~/.ssh/shared_apps_ed25519
cat ~/.ssh/shared_apps_ed25519.pub     # copy this one line
```

**2. 🟦 Authorize it on the droplet.** Paste your line between the quotes. Use `>>` (append) and spell `authorized_keys` with the final **s**: `>` overwrites and locks Coolify out; a typo creates a useless file.
```sh
echo 'ssh-ed25519 AAAA... laptop-shared-apps' >> /root/.ssh/authorized_keys
awk '{print $1, $NF}' /root/.ssh/authorized_keys     # expect 2 lines: Coolify's + yours
```

**3. 💻 Test.** `IdentitiesOnly` stops SSH offering other keys (the server allows 3 tries). Type `yes` at the host prompt, then `exit`.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip>
```
Run `ssh` from the laptop only. Running it inside the droplet makes the droplet SSH to itself (undo with `ssh-keygen -R <ip>` on the droplet).

---

## Per app

**4. 🟦 Find the Postgres container name.** It's the long random ID; it also appears in the backup path in Spaces and is the app's database host.
```sh
docker ps --format '{{.Names}}'     # e.g. ekvtijwonqbkqkf2jyu7bcbj (the others are coolify-proxy / coolify-sentinel)
```

**5. 🖥️ Check the Postgres version.** It must be >= the version the dump came from (a Postgres 18 dump needs 17+, ideally 18).
```sh
docker exec <pg> psql -U postgres -tAc "select version()"
```

**6. 💻 Generate a password** and save it in your password manager. This strips characters that break connection URLs.
```sh
openssl rand -base64 24 | tr -d '/+='
```

**7. 🖥️ Create the role and database.** Open a superuser session with `docker exec -it <pg> psql -U postgres`, then:
```sql
CREATE ROLE poketrain_app LOGIN PASSWORD '<generated>'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION;
CREATE DATABASE poketrain OWNER poketrain_app;
REVOKE ALL ON DATABASE poketrain FROM PUBLIC;   -- only the owner (and superusers) can connect
```
Once per older database (for example `postgres`), so app roles can't reach each other: `REVOKE CONNECT ON DATABASE postgres FROM PUBLIC;`. Leave psql with `\q`. Check: `docker exec <pg> psql -U postgres -c "\l poketrain"` shows owner `poketrain_app`.

**8. 💻 Check the dump.** `pg_restore --list` only reads the file; it creates nothing. You want `Format: CUSTOM`.
```sh
pg_restore --list poketrain.dump | head
```
If it errors, it's plain SQL: use the `psql` variant below.

**9. 💻 Restore.** Streams the file over SSH, nothing is left on the droplet. Silence means success; `--exit-on-error` stops at the first problem. It runs as the superuser (so extensions can install) but makes `poketrain_app` own everything.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip> \
  'docker exec -i <pg> pg_restore -U postgres -d poketrain --no-owner --no-privileges --role=poketrain_app --clean --if-exists --exit-on-error' \
  < poketrain.dump
```
Plain SQL instead: `... 'docker exec -i <pg> psql -U postgres -d poketrain -v ON_ERROR_STOP=1' < poketrain.sql`

**10. 💻 Verify.** All tables present, owner `poketrain_app`, row counts match the source.
```sh
ssh -o IdentitiesOnly=yes -i ~/.ssh/shared_apps_ed25519 root@<ip> \
  'docker exec -i <pg> psql -U postgres -d poketrain -c "\dt"'
```
Then `ANALYZE;` in the database (fresh statistics after a bulk load).

**11. ☁️ Back it up.** On `shared-postgres` -> Backups: add `poketrain` to the databases to back up, confirm **Save to S3** and the destination are set on the schedule, then **Backup now**. In Spaces, find `data/coolify/backups/databases/<team>/shared-postgres-<id>/pg-dump-poketrain-...dmp` with a non-zero size.

**12. ☁️ Connect the app.** In the app's environment variables set the database URL, using the container name as host. The app and database must be on the same Coolify network (the default on one server).
```
postgresql://poketrain_app:<password>@<pg>:5432/poketrain
```
Prisma apps: deploy with `prisma migrate deploy` (applies pending migrations only), never `migrate dev` or `migrate reset`.

---

## Connecting a GUI (DBeaver)

Use the same laptop key. Main tab: host `<pg container IP>` (find it with `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' <pg>` on the droplet), port `5432`, the app user and database. SSH tab: enable the tunnel, host `<ip>`, port 22, user `root`, auth Public Key, private key `~/.ssh/shared_apps_ed25519`. The container IP can change after a restart.

## When something goes wrong

| Symptom | Cause / fix |
|---|---|
| Only one line in `authorized_keys` | The `echo` targeted `authorized_key` (no `s`). Re-run step 2; remove the stray file with `rm /root/.ssh/authorized_key`. |
| `Too many authentication failures` | SSH offered several keys. Keep `-o IdentitiesOnly=yes -i <key>`. |
| Connection refused/timeouts after repeated failures | fail2ban banned your IP (about an hour), or the droplet isn't up yet. |
| `unsupported version (1.16) in archive` | `shared-postgres` is older than the dump's source. Recreate it on the same or newer major version. |
| `role "..." does not exist` while restoring | Add `--no-owner --no-privileges` (already in step 9). |
| `permission denied for database` as the app role | The `REVOKE` in step 7 removed access from everyone but the owner: make sure the app connects as `poketrain_app`, not another role. |
| Coolify terminal stops working | Coolify's line was lost from `authorized_keys` (a `>` overwrite). Re-add its public key from Keys & Tokens. |
