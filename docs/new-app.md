# Adding a new app

The generic process for putting an app on `shared-apps-1` through Coolify, from a GitHub repo to `https://<app>.novaej.com`. Placeholders: `<app>` (name), `<ip>`, `<pg>` (Postgres container name). Per-database commands live in [new-app-database.md](new-app-database.md).

**Where:** ☁️ Coolify UI · 🐙 GitHub · 💻 laptop · 🖥️ droplet shell (Coolify's server Terminal).

## 0. What the app repo must provide

- A **Dockerfile** that listens on one port (`EXPOSE` + the app binds `0.0.0.0`). Coolify builds it on the droplet; the build should fit in about 1 GB of RAM plus 2G swap (cap the Node heap, for example `NODE_OPTIONS=--max-old-space-size=1024`).
- **Every path the Dockerfile `COPY`s must be tracked in Git.** Git ignores empty folders, so a `COPY public ./public` of an empty `public/` fails on the droplet with `"/app/public": not found` even though it works locally. Add a `.gitkeep`.
- **Migrations run on start** (an entrypoint script, for example `prisma migrate deploy`) and a failed migration **exits**, so Coolify keeps the previous version running. Never `migrate dev`/`reset` in production.
- **No secrets in the image.** Runtime config comes from environment variables (step 4). A `.dockerignore` should exclude `.env*`, dumps and `node_modules`.

## 1. GitHub source (once per GitHub account or organization)

A GitHub App belongs to one account and is installed per repo, so one App serves every repo you pick for that account. A personal account and an organization need **two** sources.

1. ☁️ Sources -> add GitHub. Name the App something unique across GitHub (for example `coolify-<account>`). For an organization, enter its name in the **Organization** field (you must be an owner).
2. Click **Register Now** -> GitHub opens a prefilled form -> **Create GitHub App** -> back in Coolify click **Install Repositories** -> **Only select repositories** -> pick the repo.
3. For later repos: 🐙 Settings -> Applications -> Installed GitHub Apps -> the App -> Configure -> add the repo.
4. Check: the source shows **Connected**; **Test Connection** works; the repo appears in New Resource.

## 2. Database

Give the app its own role and database and add it to the backup: [new-app-database.md](new-app-database.md) steps 4-8. If the app has existing data, also load the dump (the optional restore section there, steps R1-R4) before the backup step. Result: a URL `postgresql://<app>_app:<password>@<pg>:5432/<app>`.

## 3. Create the application

☁️ Project -> the same environment as `shared-postgres` (same server and Docker network) -> **+ New** -> **Private Repository (with GitHub App)**. Do **not** use the deploy-key option: it fails with `Permission denied (publickey)` unless a deploy key is added to the repo, and it has no push webhooks.

Pick the source and repo, branch `main`, server `shared-apps-1`, **Build Pack: Dockerfile**, the app's port, and domain `https://<app>.novaej.com`. No DNS work is needed: the wildcard `*.novaej.com` already points every name at the droplet (proxied). If an explicit record for that name exists (an old host's CNAME), delete or repoint it, because explicit records win over the wildcard.

## 4. Environment variables

☁️ App -> Environment Variables -> bulk "Developer view": paste the runtime variables (never commit them).

- **Turn off "Build Variable"** for anything secret (API keys, `DATABASE_URL`). Coolify passes build variables as `--build-arg`, which is readable in the image history and triggers `SecretsUsedInArgOrEnv`. Dockerfiles that need a variable just to build should set their own placeholder.
- `DATABASE_URL` exactly as in step 2: no quotes, no trailing space, URL-encode special characters in the password.
- A changed variable applies on the next deploy.

## 5. Settings

- **Auto-deploy:** on. With the GitHub App, a push to `main` triggers a deploy through its webhook.
- **Server cleanup (once, not per app):** Servers -> `shared-apps-1` -> Docker Cleanup: frequency `0 4 * * *`, application images *delete all old images*, networks delete, **unused volumes keep** (deleting them can destroy a stopped database's data). Each deploy leaves an image on the droplet's disk until the next cleanup; check with `docker system df` and `df -h /`.
- **Rollback:** app -> Rollback -> *Images to keep* (2) works only if the server's *Application images* option keeps retained images; otherwise it shows *Disabled by the server* and you roll back with a git revert and a redeploy. Rollback doesn't undo database migrations.

## 6. Deploy and verify

Click Deploy (or push to `main`). Watch the build log, then the container log. Expect: build passes, the entrypoint's migration step reports nothing pending (or applies cleanly), the app starts, Traefik gets a Let's Encrypt certificate on the first request (a few seconds), and `https://<app>.novaej.com` loads. Check that data from the database shows up.

## 7. After the first deploy

1. Confirm the app's database is in the backup selection; **Backup now**; find its `pg-dump-<app>-...dmp` in Spaces.
2. When replacing an old host, remove or repoint its DNS record only after the new app works, and keep the old host and its data for a few days.
3. Record the app in the apps table in [deployment-reference.md](deployment-reference.md#apps).

## 8. Policies for the app's own repo

Auto-deploy does **not** wait for CI: whatever lands on `main` deploys. So protect `main` in the app repo (Settings -> Rules -> Rulesets), like [git-flow.md](git-flow.md#github-repository-settings): require a pull request (squash only), **require the CI status check**, block force pushes and deletion, empty bypass list, delete head branches on merge. Approvals can stay at 0 while you are the only reviewer.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Permission denied (publickey)` during `git ls-remote` | App was created with the deploy-key option. Recreate it with **Private Repository (with GitHub App)**. |
| Repo missing from the list | The App isn't installed on that repo (step 1.3), or you picked the wrong account's source. |
| `failed to calculate checksum ... "/app/public": not found` | An empty folder isn't in Git; add `.gitkeep` (step 0). |
| `P1000: Authentication failed` | Wrong password in `DATABASE_URL`. Reset with `\password <app>_app` in `psql -U postgres` and update the variable ([new-app-database.md](new-app-database.md)). |
| `SecretsUsedInArgOrEnv` warning | A secret is a Build Variable; turn that off (step 4). |
| Build killed or `Killed`/OOM | 1 GB droplet. Cap the heap, or build in CI and deploy an image, or resize the droplet. |
| Certificate warning for a minute | Normal on the first request while Traefik fetches the certificate. A persistent one: Cloudflare must be Full (strict) and the record proxied. |
| `526` from Cloudflare | Origin certificate not issued yet or invalid; check the proxy logs. |
| Site unreachable by IP or hosts-file entry | By design: the firewall only accepts Cloudflare on 80/443. Test on a real hostname (for example `<app>-test.novaej.com`). |
| Push doesn't deploy | Auto-deploy is off, or the webhook isn't delivered: GitHub App -> Advanced -> Recent Deliveries. |
