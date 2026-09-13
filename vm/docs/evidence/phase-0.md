# Phase 0 evidence: repository split

Status: implemented; local repository checks pass. The live-container
continuity check requires the user's running Docker environment and was not
performed by this repository-only change.

## Commands

```powershell
git mv Dockerfile docker-compose.yml docker-compose.gpu.yml .dockerignore scripts hermes-serve setup-sandbox.ps1 setup-sandbox.sh update-image.ps1 update-image.sh backup.ps1 backup.sh restore.ps1 restore.sh authorized_keys.example .env.example README.md NO_SYSTEMD.md BUGS.md PLAN-hermes-webui.md handoff.md legacy\
git grep -n "frozen-container-marker" -- vm/
```

The split is mechanical: moved files retain their content, while the root
README and four forwarding shims are new files. Ignored `.env`,
`authorized_keys`, and `backups/` were not moved.

The root shims resolve the frozen container directory from `$PSScriptRoot`, change into that
directory for relative Compose operations, pass all arguments, and preserve
the child exit code. The no-legacy-refs workflow checks the clean sibling
boundary on push and pull request.

## Outstanding runtime proof

- `git log --follow` is to be rerun after the mechanical split is committed.
- `.\setup-sandbox.ps1 -WhatIf` is not claimed as a dry run because the
  legacy script does not implement `-WhatIf`.
- Docker container ID and uptime before/after remain a user-owned check; no
  container command was run.
