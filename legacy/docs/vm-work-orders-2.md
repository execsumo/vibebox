# Vibebox VM edition — work orders, part 2

**Migration, cutover, and retirement (Phases 7–9)**

Status: Ready, blocked on Gate A
Last updated: 2026-09-11
Companion to: [`vm-transition-plan.md`](./vm-transition-plan.md) ·
[`vm-work-orders.md`](./vm-work-orders.md) (Phases 0–6)

---

## 0. How to use this document

Part 1 built a machine and proved it behaves like a VPS, using synthetic data
only. It ends parked at **Gate A**.

This document covers everything after that: moving the user's real data,
cutting over, and retiring the container edition. Its defining property is that
**the user's working environment is now in scope.** Part 1 could fail
harmlessly — the worst case was a wasted VM. From here, mistakes cost real
work.

Everything in part 1's §1 (execution model), §2.0 (config file), §3 (interface
contracts), §7 (evidence) still applies. This document adds what changes.

---

## 1. Preconditions

Do not start until **all** of these are true:

- [ ] Part 1 Phases 0–6 complete, every DoD box checked.
- [ ] The Gate A report was delivered and the user **explicitly approved
      proceeding**. Silence is not approval.
- [ ] The user approved a specific **data inventory** — a list of paths, not a
      category description.
- [ ] The user chose the **compatibility repo suite** (from the Gate A
      candidates).
- [ ] Accepted exceptions E1 and E2 (§3.2) are still what the user wants —
      reconfirm, because they were decided well before cutover.
- [ ] Tailscale **Services** confirmed available (risk A12), or the fallback
      design confirmed, and the tailnet policy permits every name in the
      registry (§3.4).
- [ ] `vibebox status` is green and the conformance suite passes on a VM
      rebuilt within the last 7 days.

If any box is unchecked, stop and ask. Do not infer approval from enthusiasm in
an earlier message.

---

## 2. What changes about the execution model

### 2.1 Legacy is now live *and* in scope

Part 1's standing constraint was "never touch the legacy container." That
relaxes to a narrower rule, and the narrowing is the dangerous part:

> **Legacy may be read. Legacy may not be written, stopped, reconfigured, or
> rebuilt — until Phase 8, in the agreed window, with the user present.**

The read path is the **existing legacy backup**, not direct volume access:

```powershell
.\legacy\backup.ps1 -Label pre-migration
```

Use it because it is the project's own supported read path, it does not require
stopping the container, and it exercises the exact mechanism the Phase 8 final
backup depends on. Reaching into `sandbox_home` with an ad-hoc
`docker run -v` is not authorized — it bypasses the thing you most need to know
works.

### 2.2 The split-brain rule

Two Vibebox machines will exist simultaneously for the whole of Phase 7. This
is the single largest risk in part 2, and it is a *human* risk, not a technical
one: work done in the VM during Phase 7 can be silently destroyed by the Phase 8
delta sync.

> **Legacy is authoritative for all real work until cutover.** The VM is under
> evaluation. Anything created in the VM during Phase 7 is disposable.

The one exception: the user may explicitly declare a specific project
VM-authoritative. If they do, record it in `vm/docs/evidence/phase-7.md` and
**exclude that path from the Phase 8 delta sync**, or the sync will overwrite
newer VM work with older legacy state.

The agent must state this rule to the user at the start of Phase 7, in plain
words, and confirm they have understood it. Do not assume they read it here.

### 2.3 Dual-run hazards

| Hazard | Rule |
|---|---|
| Both boxes on the tailnet | VM keeps its temporary names (`vibebox-vm`, `hermes-vm`) for all of Phase 7 |
| Both boxes authed to GitHub | Never run agents against the same repo *and* branch from both boxes concurrently |
| Both boxes backing up | Separate destinations. Legacy keeps `./backups/<name>`; VM uses `BACKUP_DEST`. Never share a path. |
| Both boxes claiming a name | A tailnet name can only be held once. During Phase 7 every VM registry entry uses a `-vm` suffix (`hermes-vm`), swapped to the real name at cutover. |
| Host resource pressure | VM + legacy container + WSL2 + Docker Desktop all resident. If the host degrades, reduce `VM_CPUS`/`VM_MEMORY` (§2.0 of part 1) — do **not** stop legacy. |

---

## 3. Resolved parameters

### 3.1 Data inventory tiers

The Gate A report proposed specific paths; the user approved specific paths.
These tiers are the *policy* those paths were sorted into, and they govern
anything discovered later.

**Tier 1 — Migrate.** Copied to the VM, verified by checksum.
- Project/repo directories, including bare repos used as local git remotes
  (e.g. `~/projects/*-origin.git`) — these look like plumbing and are easy to
  misclassify as Tier 3, but they are other repos' `origin`
- Git worktree directories (`~/projects/*-worktrees/`)
- `~/.claude` **in full**, credentials included — accepted exception E1 (§3.2)
- SSH private keys — accepted exception E2 (§3.2)
- Non-secret tool configuration (editor settings, per-tool prefs)
- Shell history
- Explicitly named application state the user asked for

**Tier 2 — Re-enroll, never copy.** What remains here is either trivial to
re-establish or *must not* be duplicated for technical reasons.
- `~/.config/gh` — `gh auth login` takes seconds
- **Tailscale state — never copy.** This is machine identity, not a
  credential. A duplicated node conflicts with the legacy node and breaks the
  cutover identity handover (§3.4). This one is not negotiable.
- The legacy `.env` **as a file**. Its key *values* are re-enrolled via
  `vibebox enroll`; what does not come across is the mechanism — bulk
  forwarding of every variable into every shell. The data survives, the
  anti-pattern does not.
- `~/.vibebox` internals — container-era machine state with no VM meaning

**Tier 3 — Never migrate.** Regenerated by provisioning or the user's tooling.
- `node_modules`, `.venv`, `__pycache__`, build outputs
- `~/.cache`, apt/npm/pip caches
- `~/.claude.json.*.bak` (25 files at survey time) and similar rotated backups
- Anything in `/usr/local/bin` or other machine binaries
- Legacy supervisors, PID files, stub scripts

Dotfiles are **not** Tier 1: they come from their own git repo via the dotfiles
tool, exactly as they do today. Copying materialized dotfiles would import
container-era symlinks and defeat the tool.

**Worktree path binding.** Git worktrees record *absolute* paths. They survive
this migration only because the working user stays `dev` and home stays
`/home/dev`. If either ever changes, every worktree breaks. Assert the path
invariant before migrating and verify `git -C <worktree> status` works after —
it is a DoD item, not an assumption.

### 3.2 Accepted exceptions

The user was shown the trade-off for each of these and chose it. They are
recorded here so the exception is explicit and auditable, and so a delegated
agent does not stop on an apparent contradiction with plan D7.

| # | Exception | Rationale | Consequence |
|---|---|---|---|
| **E1** | `~/.claude` migrated in full, including credentials | ~129 MB of accumulated settings, agents, skills, memory, and session history whose value is in being continuous; splitting it risks dropping state that is hard to notice missing | Live agent auth tokens cross into the VM. The VM inherits whatever trust the container held. |
| **E2** | The existing SSH private key is copied rather than regenerated | Git works on first boot; no GitHub key rotation needed | A private key crosses the boundary the migration exists to establish. |

**What these two together actually mean:** the plan's default of "clean
migration with fresh authentication" (plan D7) no longer describes this
migration. Enough credential material now crosses that the VM should be
treated as inheriting the container's trust, not starting fresh. That is a
legitimate choice for a single-user convenience box — it is the same posture
as the legacy edition's passwordless `sudo` — but it must not be *described*
as a clean boundary afterward.

Two things follow, and both are DoD items:

1. `vm/docs/security.md` states plainly that agent credentials and the SSH key
   were carried over, so the boundary is documented accurately rather than
   aspirationally.
2. If any of that credential material is ever rotated, it is rotated in the VM
   only — the stopped legacy box still holds copies for the whole rollback
   window. Note this in the Phase 9 retirement checklist.

Tier 2 still holds the line where it is cheap (`gh`) or technically required
(Tailscale state).

### 3.3 Delta sync

Phase 7 does a bulk copy. Phase 8 does a **delta** covering everything that
changed in legacy since then. The delta must:

- run `-DryRun` first and show the user the file list before touching anything;
- exclude any path declared VM-authoritative under §2.2;
- never delete on the destination (no `--delete` semantics) — a delta that can
  remove files is a delta that can lose work.

### 3.4 Tailnet names — node-to-service conversion

Plan D15 settled the design: the VM runs **one node and advertises N Tailscale
Services**, declared in the git-tracked registry (part 1 §3.3). The legacy
approach — one Tailscale sidecar container per name — does not come across.

That makes cutover a **conversion, not a move**, and the distinction matters:

| | Legacy | VM |
|---|---|---|
| `vibebox` | A node | A node (unchanged in kind) |
| `hermes` | A **node** (second sidecar) | A **service** on the `vibebox` node |
| Admin console | Both under *Machines* | `vibebox` under *Machines*, `hermes` under *Services* |
| Adding a name | New sidecar container | `vibebox tailnet add <name>` |

The DNS name and URL survive — `https://hermes.<tailnet>.ts.net` still works —
but the object behind it changes. Two consequences for cutover:

1. **Order still matters, once per name.** The legacy `hermes` node must be
   removed before the VM advertises the `hermes` service, or the name is taken
   and you get a silent suffix. Same trap as `vibebox-1`, multiplied by however
   many names exist.
2. **The tailnet policy file must permit the service before step 13 runs.**
   This is an admin-console action the guest cannot perform. Do it at Gate B
   preparation, not in the middle of the cutover window.

Every name in the registry at cutover time gets its own row in the runbook.
Today that is `hermes`; write the runbook against the registry, not against
that one name.

### 3.5 Other parameters

| Parameter | Value |
|---|---|
| Rollback window | 30 days from cutover, confirmed at Gate B |
| Legacy state during the window | Stopped but **intact** — image, volumes, and `legacy/` all present |
| Cutover duration budget | 2 hours, including verification |
| Point of no return | **Phase 9**, not Phase 8. Everything in cutover is reversible while legacy volumes exist. |

---

## 4. Phase 7 — Side-by-side migration with real data

### Deliverables

- `vm/host/lib/migrate.ps1` — extracts the approved inventory from a legacy
  backup archive and pushes it to the VM. Source is an archive, never the live
  container.
- `vm/docs/evidence/phase-7.md` — per-path record: source, size, checksum
  before, checksum after, tier.
- Compatibility results for each user-chosen repo.
- A written record of any VM-authoritative path declared under §2.2.

### Sequence

1. Tell the user the split-brain rule (§2.2) and confirm they understand it.
2. Take a labeled legacy backup: `.\legacy\backup.ps1 -Label pre-migration`.
   Verify the archive opens and contains what you expect.
3. Extract only Tier 1 paths from that archive.
4. Push to the VM; restore with name-based ownership mapping (plan D9).
5. Verify every path by checksum against the archive.
6. Run `vibebox enroll` for each Tier 2 item: GitHub, Tailscale, Hermes, and
   the API keys that previously lived in the legacy `.env`. Agent auth is not
   in this list — it came across under E1.
7. Build and test each compatibility repo in the VM.
8. Re-prove backup and restore, now on real data.

### Validation

```powershell
# Legacy untouched: same container, continuous uptime, no restarts
docker inspect <legacy-id> --format '{{.State.StartedAt}} {{.RestartCount}}'
```
```bash
# In the VM: ownership, modes, git state
find /home/dev -not -user dev -print | head        # must be empty
cd /home/dev/projects/<repo> && git status --porcelain && git log -1
```

### DoD

- [ ] Every approved path migrated and checksum-verified.
- [ ] **Nothing outside the approved inventory was copied** — including nothing
      copied "temporarily to test."
- [ ] No Tier 2 credential exists in the VM: specifically no `~/.config/gh`,
      no copied Tailscale state, no legacy `.env` file. E1/E2 material is
      expected and is not a finding.
- [ ] `~/.claude` migrated whole and the agent works without re-login (E1).
- [ ] Git worktrees resolve: `git -C <each worktree> status` succeeds, proving
      the `/home/dev` path invariant held.
- [ ] Bare origin repos (`*-origin.git`) migrated, and a repo that uses one as
      its remote can still fetch from it.
- [ ] All restored files owned by `dev` **by name**; `find -not -user dev` is
      empty.
- [ ] Each compatibility repo builds and tests with **zero** Vibebox-specific
      changes. Any change required is a defect to fix, not a note to write.
- [ ] Node, Python, Go, Compose, localhost-server, and systemd workflows behave
      as ordinary Ubuntu.
- [ ] File watchers fire on native edits; bind mounts and volume paths are
      native Linux paths.
- [ ] Backup → rebuild → restore re-proven on real data.
- [ ] Legacy container: unchanged `StartedAt`, `RestartCount` unchanged, still
      the user's daily driver.
- [ ] The split-brain rule was stated to the user and acknowledged.

---

## 🛑 Gate B — Schedule cutover with the user

Present the runbook below and get agreement on every row. Do not pick a date.

| Item | Needs from the user |
|---|---|
| Window | A specific date and time they choose. Not a default, not a Friday, not mid-sprint. |
| Presence | Confirm they are reachable during the window |
| Tailnet names | The registry contents, and confirmation the tailnet policy permits each one (§3.4) |
| Devices to update | Every machine with a `known_hosts` entry or saved SSH config for `vibebox` |
| Abort trigger | Agreed **before** starting (§6.1) |
| Rollback window | 30 days, confirmed |
| Delta preview | Show the `-DryRun` file list; get sign-off on it |

Deliver as `vm/docs/evidence/gate-b-plan.md`. Then wait.

---

## 5. Phase 8 — Cutover runbook

Execute only in the agreed window. Every step has a verification; if a
verification fails, stop at that step and consult §6.

### T-1 day

| # | Step | Verify |
|---|---|---|
| 1 | Full legacy backup, labeled `final-pre-cutover` | Archive exists, opens, size is plausible |
| 2 | **Restore-test that archive** into a throwaway VM | Data present and correct. A backup that has not been restored is a hope, not a backup. |
| 3 | VM conformance suite | Green |
| 4 | Confirm the tailnet policy permits every registry name (§3.4) | Policy shows each service; this is an admin-console action, done **now** not mid-window |
| 5 | Confirm the user still wants the window | Explicit yes |

### Cutover window

| # | Step | Verify | Reversible? |
|---|---|---|---|
| 6 | Announce start; confirm the user has no unsaved work in legacy | Explicit yes | — |
| 7 | Delta sync `-DryRun`, show the file list | User signs off | Yes |
| 8 | Delta sync for real | Checksums match; no deletions occurred | Yes |
| 9 | Stop the legacy container (`docker compose stop`) — **stop, never `down -v`** | Container stopped; **volumes intact** | Yes — `start` |
| 10 | In the Tailscale admin console, remove the legacy `vibebox` node | Node gone from the tailnet | Yes — re-auth |
| 11 | Remove the legacy `hermes` node — **and one row per additional legacy name** | Each node gone | Yes |
| 12 | Rename the VM instance and set its Tailscale hostname to `vibebox` | **Admin console shows `vibebox`, not `vibebox-1`** | Yes |
| 13 | Drop the `-vm` suffix from every registry entry, then `vibebox tailnet apply` | `vibebox tailnet list` shows registry and live in agreement, no suffixes; each name resolves and serves a valid cert | Yes |
| 14 | MagicDNS check from a **second device** | `ssh dev@vibebox` connects to the VM | — |
| 15 | Update `known_hosts` on every device from the Gate B list | Each connects without a host-key warning | — |
| 16 | Reboot the VM | All-green `vibebox status` within the readiness budget | — |
| 17 | Restart the Windows host | VM autostarts; SSH and tailnet both work | — |
| 18 | Promote `vm/README.md` to root; update docs to describe only the VM | Root README has no container instructions | Yes |
| 19 | Rollback rehearsal: start legacy, confirm it runs, stop it again | Legacy started cleanly | — |

**Steps 11–13 are the ones that bite,** once per name. If a legacy node still
holds a name, Tailscale silently appends a suffix and every saved address keeps
pointing at the stopped box. Check the admin console UI, not just `tailscale
status` or `vibebox tailnet list` — the VM will cheerfully report the name it
*asked* for. Note that `hermes` moves from *Machines* to *Services* (§3.4), so
look in the right place before concluding it is missing.

**Step 9 is the one that ends the project if you get it wrong.** `docker
compose down -v` destroys the home volume. The rollback path depends on those
volumes surviving for 30 days. Use `stop`.

### DoD

- [ ] Final backup taken **and restore-tested** (step 2), not merely created.
- [ ] Legacy stopped with volumes intact; `docker volume ls` still lists the
      home and ssh-key volumes.
- [ ] **Every** legacy tailnet identity released before the VM claimed it —
      one check per name, not just `vibebox` and `hermes`.
- [ ] Admin console shows `vibebox` with no numeric suffix.
- [ ] Every registry name resolves, serves a valid cert, and carries no `-vm`
      suffix; `vibebox tailnet list` shows registry and live in agreement.
- [ ] SSH works from a second device, over both the tailnet and locally.
- [ ] `known_hosts` updated everywhere on the Gate B device list.
- [ ] VM survives its own reboot **and** a Windows host restart.
- [ ] Root docs describe only the VM path.
- [ ] Rollback rehearsed during the window and demonstrated working.
- [ ] `vm/docs/evidence/phase-8.md` records each step with its verification.

---

## 6. Rollback

### 6.1 Abort triggers

Agreed at Gate B. Recommended defaults — any one of these aborts the cutover:

- The VM is unreachable by SSH from a second device after step 14.
- Any tailnet identity cannot be claimed cleanly (stuck on a `-1` suffix), or
  a service cannot be advertised because the tailnet policy rejects it.
- The delta sync reports checksum mismatches it cannot resolve.
- Any Tier 1 data is missing after the delta.
- A compatibility repo that passed in Phase 7 now fails.
- The window expires with steps outstanding. Time is a trigger: an overrunning
  cutover is aborted, not rushed.

### 6.2 Rollback procedure

Within the 30-day window, rollback is straightforward because nothing was
destroyed:

1. Stop the VM (`vibebox stop`).
2. Release the VM's node identity and withdraw every advertised service
   (`vibebox tailnet` entries), so legacy can reclaim its names.
3. Start legacy (`docker compose start`) — volumes are intact, so state is
   exactly as it was at step 9.
4. Re-authenticate legacy's Tailscale nodes if the keys were expired.
5. Restore `known_hosts` entries on affected devices.
6. Restore the root README from git.
7. Recover any work done in the VM post-cutover: back up the VM first, then
   selectively restore into legacy.

Step 7 is the only lossy part, and its cost grows every day after cutover. That
is the real reason the rollback window is 30 days rather than indefinite: the
longer you wait, the more the two diverge.

### 6.3 What is *not* reversible

Nothing in Phase 8. The point of no return is Phase 9 — deleting `legacy/` and
its volumes. Say this to the user plainly; it is the most reassuring true thing
about cutover day.

---

## 7. Phase 9 — Retirement

Only on the user's explicit decision, after the 30-day window, a stable soak,
and at least one successful real recovery from a VM backup.

### Deliverables

- `gpu/` — the standalone GPU project extracted **before** anything is deleted
  (plan D14, part 1 §2.5): a CUDA base image, a Compose file, and a README for
  running it on Windows against Docker Desktop. It depends on neither `legacy/`
  nor `vm/`.
- `docs/migration-notes.md` — what moved, what was regenerated, what was
  deliberately dropped, and the re-enrollment steps, for future reference.
- Tag `legacy-final` on the last commit containing the container edition.

### Sequence

1. Extract and **test** `gpu/` — run a real GPU job, capture `nvidia-smi` from
   inside the container.
2. Write the migration notes.
3. Push the `legacy-final` tag.
4. Take a final VM backup and restore-test it.
5. Delete `legacy/`, the four root forwarding shims, and the no-legacy-refs CI
   check.
6. Remove the legacy Docker volumes and image — **this is the point of no
   return**; confirm with the user immediately before.

### DoD

- [ ] `gpu/` exists and has run a real GPU job end to end.
- [ ] **Retirement blocked until the box above is checked.** Deleting `legacy/`
      without it silently removes the user's GPU capability.
- [ ] `legacy-final` tag pushed and verified present on the remote.
- [ ] Migration notes written.
- [ ] The user is reminded that the legacy volumes held copies of the E1/E2
      credentials for the whole window; if any were rotated post-cutover, the
      stale copies die with the volumes, which is the desired outcome.
- [ ] Final VM backup restore-tested.
- [ ] `legacy/`, shims, and the CI guard removed.
- [ ] `NO_SYSTEMD.md` deleted, not rewritten — the concept no longer exists.
- [ ] Legacy volumes removed only after explicit, immediate confirmation.
- [ ] Root README, docs, and `vibebox --help` mention no container path.

---

## 8. Stop conditions

Part 1's ten stop conditions still apply. These are additional, and all of them
are absolute:

12. **Any write to legacy** outside Phase 8 step 9 — including "just restarting
    it to check something."
13. **`docker compose down`, `down -v`, `volume rm`, or `image rm` against
    legacy** at any point before Phase 9 step 6.
14. **Data outside the approved inventory** would be copied, for any reason.
15. **A Tier 2 credential** would be copied instead of re-enrolled.
16. **The delta sync would delete or overwrite** anything on the destination.
17. **Any cutover step fails its verification** — stop at that step, consult
    §6, do not improvise forward.
18. **The cutover window expires** with steps outstanding.
19. **The user is unreachable** mid-cutover and a step needs their decision.
20. **Phase 9 step 6** (destroying legacy volumes) — always reconfirm
    immediately before, regardless of prior approval.

---

## 9. Definition of done

Part 2 is complete when:

- [ ] The user's real data lives in the VM, checksum-verified, owned correctly.
- [ ] No container-era credential crossed the boundary; everything was
      re-enrolled.
- [ ] `ssh vibebox` reaches the VM from every device the user uses.
- [ ] Every tailnet name in the registry resolves with a valid cert, and a
      rebuild restores them all via one `vibebox tailnet apply`.
- [ ] The VM survived a 30-day rollback window as the daily driver.
- [ ] A real recovery from a VM backup has been performed at least once.
- [ ] GPU work runs from `gpu/` on the host, unchanged in capability.
- [ ] The container edition exists only as the `legacy-final` tag.
- [ ] No systemctl stub, no init shim, no command wrapper, no sidecar topology,
      and no Docker socket forwarding remains in the supported runtime.

And the test the whole project was for: **a tool installed by its stock Ubuntu
instructions works, with no Vibebox-specific accommodation, and nobody has to
think about it.**
