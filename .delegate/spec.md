# OBJECTIVE

Make the sandbox's SSH host identity (the `<SANDBOX_NAME>-ssh-keys` Docker volume)
recoverable from a backup, without reintroducing the identity-clobbering behaviour that
excluding it was meant to prevent.

# CONTEXT

Repo: vibebox — a Dockerised dev sandbox. You are in your own git worktree; work only there.

Background you need:
- SSH host keys used to live in `~/.vibebox/ssh` inside the **home** volume. Commit 2c7d22c
  moved them to a dedicated volume `<SANDBOX_NAME>-ssh-keys` (mounted at `/opt/vibebox/ssh`).
- That move means a *restore* no longer overwrites them — the sandbox keeps its identity and
  clients don't get "host key changed" warnings. **This is desirable. Do not break it.**
- But the consequence is that **nothing backs them up at all**. `backup.sh:71` explicitly
  excludes `.vibebox` and notes the keys live elsewhere. If that volume is deleted or the
  user moves to a new host, the identity is gone permanently.

Files you will change (and ONLY these):
- `backup.sh`      (bash, Linux/macOS host)
- `backup.ps1`     (PowerShell, Windows host)
- `restore.sh`     (bash)
- `restore.ps1`    (PowerShell)
- `scripts/backup` (the in-container `backup` command)

Do NOT touch: `Dockerfile`, `docker-compose.yml`, `scripts/entrypoint`, `README.md`,
`handoff.md`, `BUGS.md`. Another agent is editing those concurrently — touching them
guarantees a merge conflict.

The bash and PowerShell scripts are deliberate mirrors of each other. Whatever you do in one,
do the equivalent in the other, matching that file's existing style, colour-output helpers,
and error-handling conventions. Read all five files before editing.

# REQUIRED DESIGN

Do not invent a different approach; this design is chosen deliberately.

**Backup side** (`backup.sh`, `backup.ps1`, and `scripts/backup` if reachable):
- Additionally archive the ssh-keys volume into the *same* tarball, under a distinct
  top-level directory `ssh-identity/`.
- Mount the volume read-only into the staging root alongside home, e.g. add
  `-v "${SandboxName}-ssh-keys:/stage/ssh-identity:ro"` and add `ssh-identity` to the
  `tar` argument list after `home/${Username}`.
- Leave the existing `home/<user>` path and the `--exclude=home/<user>/.vibebox` behaviour
  exactly as they are.
- If the ssh-keys volume does not exist (fresh setup, or a user who never upgraded),
  the backup must still succeed — degrade gracefully, don't hard-fail.
- For `scripts/backup`: it runs *inside* the container, where the volume is already mounted
  at `/opt/vibebox/ssh`. Apply the equivalent change if it can reach that path. If it
  genuinely cannot, leave the file alone and say so in your final summary — do not force it.

**Restore side** (`restore.sh`, `restore.ps1`):
- **Default behaviour must not change**: `ssh-identity/` is NOT restored. The existing
  identity is preserved. This is the whole point — do not regress it.
- Add an opt-in flag: `--restore-identity` (bash) / `-RestoreIdentity` (PowerShell switch).
  When passed, also extract `ssh-identity/` back into the `<SandboxName>-ssh-keys` volume.
- Print a clear one-line message in BOTH cases, so the behaviour is never a surprise:
  - default: that the existing SSH host identity was kept, and that `--restore-identity`
    exists for migrating to a new host.
  - with the flag: that the host identity was replaced, and that clients will warn once
    about a changed host key.
- Archives created before this change have no `ssh-identity/` entry. Restoring one with
  `--restore-identity` must not error — detect its absence and print a clear message.
- Keep the flag out of the way of the existing positional backup-name argument: `./restore.sh
  before-llm --restore-identity` and `./restore.sh --restore-identity before-llm` should both
  work. Update the usage comment block at the top of each script.

# DEFINITION OF DONE

Every one of these must pass when run from the root of your worktree. I will run these myself.

1.  `bash -n backup.sh && bash -n restore.sh && bash -n scripts/backup` exits 0.
2.  `grep -q 'ssh-keys\|ssh-identity' backup.sh && grep -q 'ssh-keys\|ssh-identity' backup.ps1` exits 0.
3.  `grep -q 'restore-identity' restore.sh && grep -qi 'RestoreIdentity' restore.ps1` exits 0.
4.  `git diff --name-only` lists ONLY files from the allowed list above. Nothing else.
5.  Reading `restore.sh` and `restore.ps1`, the default path provably does not extract
    `ssh-identity/` — be ready to point at the exact lines that guarantee it.
6.  Both restore scripts handle an archive with no `ssh-identity/` entry without erroring.

Note: Docker is NOT running in this environment and you cannot execute the scripts
end-to-end. Do not fake a test run or claim you verified runtime behaviour. Static checks
plus careful reading are the bar. If you want to sanity-check tar/flag-parsing logic in
isolation with a scratch script in /tmp, that's fine — just don't claim more than you did.

# ESCALATION

Stop and ask me if:
- The mirrored bash/PowerShell behaviour can't be made equivalent without a design change.
- You find a reason the required design above is wrong or unsafe.
- Any DoD check can't be made to pass without touching a file outside the allowed list.
- You hit the same failure 3 times.

# REVERSE CHANNEL

To reach me, run ONE command from your worktree:
  ./.delegate/notify needs-input "the question or decision you need answered"
  ./.delegate/notify blocked     "what you are stuck on"
  ./.delegate/notify done        "summary of what you finished"
then STOP AND WAIT in your pane — do not exit, do not continue.
I will review your work and either confirm you're done or send corrections.
After I reply, run:
  ./.delegate/notify resume
BEFORE continuing — otherwise your status stays stuck.

# OUTPUT

On finish: run `./.delegate/notify done "<summary>"`, then STOP AND WAIT at your prompt.
Do not exit. In the summary, state explicitly what you did to `scripts/backup` and whether
DoD check 6 required special handling.

# SCOPE BOUNDARY

Stay in your worktree. Do not commit, do not push, do not open PRs, do not run
`docker` commands, do not modify files outside the allowed list.
