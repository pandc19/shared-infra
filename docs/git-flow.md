# Git flow

How changes reach the droplet. This repo has **one environment**, so unlike a staging/production project there is **one long-lived branch: `main`**. A merge to `main` *is* the deploy: the workflow plans and applies it.

## Model

| Branch | Purpose | Who touches it |
|---|---|---|
| `main` | The truth. What is on `main` is what Terraform applies. | Only via a merged PR. Nobody pushes to it directly. |
| `feat/*`, `fix/*`, `chore/*`, `docs/*` | Short-lived working branches off `main`. | You. Deleted after merge. |

There is deliberately **no `production` or `staging` branch** and no release tags. Comprobify needs those to promote a tested build from staging to production; here there is nothing to promote, and a second branch would only add a promotion step with nothing behind it. If a second environment is ever added (`environments/<name>/`), revisit this: the usual answer is still one branch, with a separate path and a separate approval-gated GitHub Environment.

Commit and PR titles use a conventional prefix like Comprobify: `feat:`, `fix:`, `chore:`, `docs:`, `ci:`. PRs are **squash-merged**, so `main` stays one commit per change.

## Daily flow

```sh
git checkout main && git pull
git checkout -b chore/describe-the-change
# edit, then
terraform fmt -recursive            # the plan job fails on unformatted files
git add -A && git commit -m "chore: describe the change"
git push -u origin chore/describe-the-change
gh pr create --fill                 # or the GitHub UI
```

1. The PR runs the **`plan`** job (fmt check, validate, `terraform plan`). It changes nothing.
2. **Read the plan in the job log.** This is the review step. Check for `must be replaced` on `digitalocean_droplet` (wipes Postgres) and unexpected `destroy` lines. The PR template has the checklist.
3. Squash-merge. The push to `main` re-runs `plan`, then **`apply`** runs automatically (if the files under `modules/**`, `environments/**` or the workflow changed).
4. Read the end of the `apply` log. Delete the branch (GitHub can do this automatically, see the settings below).

Docs-only PRs also run `plan` (it's a no-op) so the required check always reports; on `main` a docs-only push does **not** apply.

## What each trigger does

| Event | Result |
|---|---|
| PR from a branch in this repo | `plan` only |
| PR from a fork | skipped (forks get no secrets) |
| Merge/push to `main` touching `modules/**`, `environments/**` or the workflow | `plan`, then `apply` |
| Merge/push to `main` touching only docs | nothing |
| Manual run, `plan` / `apply` | on `main` for `apply`; ignores path filters |
| Manual run, `destroy` | two approvals, see [DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) |

Everything is skipped while the repository variable `TERRAFORM_ENABLED` is not `true`.

## Rolling back

Terraform has no undo button; you revert the change and apply it.

- **A bad merge that already applied:** `git revert` the merge commit on a branch, open a PR, read the plan (it should show the opposite of what happened), merge. If the bad change *replaced the droplet*, reverting recreates it but **the data is gone**; restore from Spaces ([DESTROY_AND_REBUILD.md](../DESTROY_AND_REBUILD.md) section 5).
- **An apply that failed halfway:** state already records what was created. Fix the cause and run the workflow (`apply` on `main`), or re-merge. Do not hand-delete resources in the DigitalOcean/Cloudflare consoles; that makes state and reality disagree.

## Emergencies and exceptions

- **Urgent fix:** there is no bypass. Branch, PR, wait for `plan` (about a minute), merge. If you truly need a change *now* and the workflow is down, run Terraform locally (reference doc, "Running Terraform locally") and open the PR right after so `main` matches reality. Never apply from two places at once.
- **Deliberate droplet replacement:** `terraform apply -replace=...` is **local only** (CI can't pass `-replace`). Take a Postgres backup first.
- **Manual changes in Coolify/Cloudflare/DO consoles** that Terraform manages will show up as drift in the next plan. Change those things in code.
- **Dependency updates:** provider versions are pinned by `.terraform.lock.hcl`. To upgrade, run `terraform init -upgrade` on a branch and commit the lock file in the PR.

## GitHub repository settings

The repo is **public**. That matters: Actions logs are publicly readable, so plan and apply output (resource IDs, the reserved IP, zone ID, domain) is public. Secrets are masked in logs; variables are not. Nothing sensitive is in those, but never print a secret in a workflow step.

### Branches to create

None beyond `main`, which already exists. Working branches are created per change and deleted after merge.

### Ruleset for `main` (Settings -> Rules -> Rulesets -> New branch ruleset)

Rulesets are GitHub's current replacement for classic branch protection.

- **Name:** `protect-main`. **Enforcement:** Active. **Target:** default branch (`main`).
- **Bypass list:** empty. With no bypass even you can't push straight to `main`, which is the point; emergencies go through a fast PR.
- Restrict deletions: on.
- Block force pushes: on.
- Require linear history: on (goes with squash merging).
- Require a pull request before merging: on.
  - Required approvals: **0**. You are the only reviewer, and a required approval you can't give would block every merge. The human gate is you reading the plan. If a second person joins, raise this to 1 and turn on "Dismiss stale approvals".
  - Allowed merge methods: **Squash** only.
  - Require conversation resolution: on.
- Require status checks to pass: on.
  - Add the check **`plan`** (the job in the `Terraform` workflow).
  - **Require branches to be up to date before merging:** on. A plan computed against a stale `main` can be wrong, and this forces a fresh plan.
  - A skipped `plan` (fork PR, or `TERRAFORM_ENABLED` off) counts as passing.

### Repository settings (Settings -> General)

- Pull Requests: allow **squash merging** only; untick merge commits and rebase merging.
- **Automatically delete head branches:** on.
- Default squash commit message: pull request title.

### Actions settings (Settings -> Actions -> General)

- Workflow permissions: **Read repository contents** (the workflow also declares `contents: read`). Leave "Allow GitHub Actions to create and approve pull requests" off.
- Fork pull request workflows: **Require approval for all outside collaborators**.
- Allowed actions: optionally restrict to GitHub-authored plus the pinned `hashicorp/setup-terraform`.

### Environments (Settings -> Environments)

| Environment | Reviewers | Deployment branches |
|---|---|---|
| `shared-infra` | none | any (PR `plan` jobs run from feature branches) |
| `shared-infra-destroy` | yourself (and a second person if available) | `main` only |

### Security (Settings -> Code security)

On a public repo these are free: enable **secret scanning** and **push protection** (blocks a pushed token before it lands), Dependabot alerts, and optionally Dependabot version updates for `github-actions` and `terraform`.

### Tags

No release tags are used. If you later tag milestones, add a tag ruleset so tags can't be deleted or moved.
