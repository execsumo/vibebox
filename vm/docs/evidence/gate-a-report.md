# Gate A report

Status: **Gate A evidence complete except the A2 console proof.**
Date: 2026-09-13

The user authorized migration directly (2026-09-13) rather than after reading
this report, so this document is a record rather than a request. §7 lists what
that means in practice — in particular the two things I did **not** do while
the user was away.

## 1. Conformance results

16 pass, 1 fail, 5 skip. Full table and analysis in
[`phase-6-conformance.md`](./phase-6-conformance.md).

The single failure (`41-tailnet`) is Tailscale enrollment, which needs a
secret only the user can supply. **No exception is proposed**; it is a real
gap that closes when the auth key is provided.

Running the suite for the first time found four bugs in the suite itself and
one real product defect (guest config shipped with CRLF line endings, so any
naive consumer parsed `GUEST_USER` as `herwin\r`). Details in that file.

## 2. Soak findings

**Not performed.** A reduction from the specified 7-day soak is proposed in
[`deviations.md`](./deviations.md) D-4 and has not been accepted. What has
been demonstrated instead:

- Full destroy → create → provision cycles completed in **4.2 minutes**.
- Two independent VMs built from the same definition, both reaching an
  all-green status apart from Tailscale.
- Clock offset 0 s, `synced: true`, on every `vibebox status` run.

Not demonstrated: host reboots, sleep/resume cycles, multi-day stability.
**This is the largest untested area.** See §7.

## 3. Data inventory

Source: `backups/vibebox/vibebox-backup-migrate.tar.gz` — 12 GB, written
**2026-08-20**, produced by the legacy box's own backup path, so it carries
real POSIX modes, ownership and symlinks.

| Path | What it is | Size | Credentials? | Migrated |
|---|---|---:|---|---|
| `projects/` | working repositories | 401 M | possibly (`.env` files) | yes |
| `.dotfiles/` | shell/tool config, symlink targets | 339 M | possibly | yes |
| `.local/` | user binaries and shared data | 530 M | no | yes |
| `.claude/` | Claude Code state | 35 M | **yes** (E1) | yes |
| `workspace/` | scratch working tree | 20 M | no | yes |
| `.config/` | XDG config | 19 M | possibly | yes |
| `vault/` | notes | 5.1 M | no | yes |
| `.ssh/` | SSH keys | small | **yes** (E2) | yes |
| `.agents/`, `.codex/`, `.factory/`, `.gemini/` | agent state | varies | likely | yes |
| `.cache/` | regenerable caches | **9.7 G** | no | **no** |
| `.npm/` | npm cache | 997 M | no | **no** |
| `go/pkg/` | Go module cache | ~1.4 G | no | **no** |
| `.cargo/registry`, `.cargo/git` | Rust caches | 391 M | no | **no** |

**The table above is a partial accounting, not a full one.** The legacy home
is **23 GB on disk** (11.55 GB compressed, 392,520 entries, gzip verified
intact). The rows listed sum to roughly 14 GB; the remainder is spread across
agent-state directories not itemised here (`.agents`, `.codex`, `.factory`,
`.gemini`, `.harnessam`, `.infisical`) plus a nested `backups/` tree (244 MB).
All of it migrates except the excluded caches — the gap is in the reporting,
not in what gets copied.

Every excluded path rebuilds itself on first use. `-IncludeCaches` copies them
if that judgement was wrong.

### The staleness problem — read this

**The migrated data is a 2026-08-20 baseline. It is roughly three and a half
weeks old, and a delta sync is owed.**

The live legacy home is inside the Docker volume, whose VHDX was last written
2026-09-12. Reaching it requires starting Docker Desktop, and the legacy
container is declared `restart: unless-stopped`, so starting the daemon would
start the legacy container — the one action the work order's standing
constraints forbid (§1.1, §8.7). With the user AFK and unable to consent, I
took the baseline and stopped.

`C:/vibebox` holds the same vintage (nothing newer than 2026-08-25) and is
worse as a source: it is an NTFS view, so POSIX modes and executable bits are
already lost there.

## 4. Deliberate exclusions

Not migrated, and the re-authentication each implies:

- **Tailscale machine state** — never copied. The VM must enroll as its own
  node.
- **Regenerable caches** — see the table.
- **Docker images, volumes and containers** — the VM has its own engine.

Carried deliberately, as the work order's recorded exceptions:
- **E1**: `~/.claude` including credentials.
- **E2**: the existing SSH private key.

Both were pre-recorded as exceptions and are reconfirmed by the user's
explicit migration instruction.

## 5. Resource assessment

| | |
|---|---|
| Host RAM | 31.77 GB |
| VM allocation | 4 GB (`vibebox`) |
| Host disk C: | 176.8 GB free |
| VM disk | 64 GB, dynamically allocated (raised from 32 GB for real data) |
| Guest usage after provisioning | ~12 GB of tools |

Not measured with the legacy container and Docker Desktop running
concurrently, because neither was started.

## 5a. GPU workload inventory

**Not collected.** No GPU workload was inspected and the user has not been
asked which workloads matter. The VM is CPU-only; Multipass exposes no GPU
option at all (`multipass launch --help` has no GPU flag), which settles it
for this adapter regardless of host capability.

Phase 9 still must extract a standalone `gpu/` project before `legacy/` is
deleted, or the user's GPU capability disappears with it.

## 6. Compatibility repo candidates

Not proposed — this would mean reading the user's repositories to pick
candidates, and the migration instruction did not extend to selecting test
repos. Once the delta sync lands, pick 2–3 from `projects/` that exercise
Node, Python and Docker Compose respectively.

## 7. Honest risk list

Ordered by how much they would actually cost.

1. **The A2 rescue console is still unproven.** Nobody has confirmed that
   `vmconnect.exe` reaches a login prompt with `sshd` stopped. This is the
   work order's hard gate (§8.4) and it now guards a box with real data in it.
   If SSH ever breaks, the recovery path is untested. **This is the single
   most important open item.**
2. **The data is a three-week-old baseline.** A delta sync is owed and cannot
   run without starting Docker Desktop.
3. **Tailscale is not enrolled, and the name `vibebox` is still held by the
   legacy node.** The VM cannot claim it while legacy holds it — it would
   become `vibebox-1`. The work order calls this the most likely cutover-day
   failure (Gate B). Releasing the legacy node is a decision, not a step.
4. **No host reboot or sleep/resume has been tested.** Post-resume clock skew
   and Tailscale reconnection are exactly the failures a soak exists to catch.
5. **Backup and restore have not been exercised against this data.** The
   restore path gained cross-account rename support today; its symlink
   retargeting is used by the migration but the full backup → rebuild →
   restore loop has not been run end to end.
6. **Two VMs now exist** (`vibebox` and `vibebox-vm`). The old one is a
   synthetic test box and should be destroyed once `vibebox` is confirmed,
   but destroying it is not urgent and it is a useful fallback.
7. **`GUEST_USER` UID landed on 1000**, which the work order specifically
   wanted to avoid so that name-based mapping would be exercised rather than
   assumed. The rename path exercises it deliberately instead.
