## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Plan review (Terraform changes only)

- [ ] I read the `plan` job output on this PR
- [ ] It adds/changes only what I expect
- [ ] No `must be replaced` on `digitalocean_droplet` (that wipes Postgres) unless intended and a backup was taken
- [ ] No unexpected `destroy` lines

## Docs

- [ ] [docs/deployment-reference.md](../docs/deployment-reference.md) updated if a name, variable, secret or setting changed
