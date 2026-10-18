# Git flow

One environment, so **one long-lived branch: `main`**. A merge to `main` *is* the deploy: the workflow plans and applies it.

## Model

| Branch | Purpose |
|---|---|
| `main` | What Terraform applies. Changes arrive only through a merged PR; nobody pushes to it. |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Short-lived, off `main`, deleted after merge. |

There is deliberately no `production`/`staging` branch and no release tags: there's nothing to promote between environments. If a second environment is added (`environments/<name>/`), keep one branch and separate it by path plus an approval-gated GitHub Environment.

Titles use a conventional prefix (`feat:`, `fix:`, `chore:`, `docs:`, `ci:`). PRs are squash-merged.

## Daily flow

```sh
git checkout main && git pull
git checkout -b chore/describe-the-change
terraform fmt -recursive           # the plan job fails on unformatted files
git add -A && git commit -m "chore: describe the change"
git push -u origin chore/describe-the-change
gh pr create --fill
```

1. The PR runs **`plan`** (fmt check, validate, `terraform plan`); it changes nothing.
2. **Read the plan.** That is the review. Look for `must be replaced` on `digitalocean_droplet` (wipes Postgres) and unexpected `destroy` lines. The PR template has the checklist.
3. Squash-merge. If `modules/**`, `environments/**` or the workflow changed, `plan` re-runs and `apply` follows. Read the end of the `apply` log.

## Triggers

| Event | Result |
|---|---|
| PR from a branch in this repo | `plan` only (runs on every PR so the required check always reports) |
| PR from a fork | skipped (no secrets) |
| Push to `main` touching `modules/**`, `environments/**` or the workflow | `plan`, then `apply` |
| Push to `main`, docs only | nothing |
| Manual `plan` / `apply` | `apply` only on `main`; ignores path filters |
| Manual `destroy` | two approvals: [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) |

All jobs are skipped unless the repository variable `TERRAFORM_ENABLED` is `true`.

## Rolling back

Terraform has no undo; revert and apply.
- **Applied a bad change:** `git revert` the merge on a branch, PR it, read the plan (it should show the opposite), merge. If the bad change replaced the droplet, reverting recreates it **without the data**: restore from Spaces.
- **Apply failed midway:** state records what exists. Fix the cause and re-run `apply`. Don't hand-delete resources in the consoles; that desynchronizes state.

## Exceptions

- **Urgent fix:** no bypass. Branch, PR, wait for `plan` (about a minute), merge. If the workflow is down, run Terraform locally and open the PR right after so `main` matches reality. Never apply from two places at once.
- **Replacing the droplet** (`-replace`) is local-only; back up Postgres first.
- **Console changes** to Terraform-managed resources show up as drift in the next plan; change them in code.
- **Provider upgrades:** `terraform init -upgrade` on a branch; commit the lock file.

## GitHub repository settings

The repo is **public**: Actions logs are public. Secrets are masked; variables and plan output (IP, zone ID, domain) are visible. Never print a secret in a step.

**Branches:** none to create; `main` exists.

**Ruleset on `main`** (Settings -> Rules -> Rulesets -> New branch ruleset): name `protect-main`, Active, target the default branch, **empty bypass list**.
- Restrict deletions, block force pushes, require linear history.
- Require a pull request: **0 approvals** (you can't approve your own PRs; reading the plan is the review; raise to 1 when a second person joins), **squash only**, require conversation resolution.
- Require status check **`plan`**, with *branch up to date before merging* on. A skipped `plan` (fork PR, or `TERRAFORM_ENABLED` off) counts as passing.

**General:** squash merging only; delete head branches on merge.

**Actions:** read-only workflow permissions; "Allow Actions to create and approve pull requests" off; require approval for fork PR workflows from all outside collaborators.

**Environments:**

| Environment | Reviewers | Deployment branches |
|---|---|---|
| `shared-infra` | none | any (PR plans run from feature branches) |
| `shared-infra-destroy` | you (plus a second person if available) | `main` only |

**App repos:** the repos you deploy through Coolify need their own `main` ruleset (PR required, CI check required, no bypass), because auto-deploy doesn't wait for CI: see [new-app.md](new-app.md#8-policies-for-the-apps-own-repo).

**Security:** secret scanning and push protection (free on public repos), Dependabot alerts, optionally Dependabot updates for `github-actions` and `terraform`.
