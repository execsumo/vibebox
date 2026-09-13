# Proposed deviations from the work order

Status: **proposed, awaiting user acceptance**
Raised: 2026-09-13
Against: [`docs/vm-work-orders.md`](../../../docs/vm-work-orders.md)

Work order §8.9 requires proposing a change rather than silently deviating.
Each item below states what the work order specified, what was done instead,
and why. None of these were accepted unilaterally as permanent.

---

## D-1. `vibebox config diff|apply` removed; resources are create-time only

**Work order says** (§2.0, §3.1, Phase 2 DoD): `config apply` reconciles
`VM_CPUS`, memory bounds, and `VM_DISK` against a running Hyper-V VM, with a
grow-only disk path and a `-Restart` guard.

**Done instead**: `config show` kept. `diff` and `apply` removed. CPU, memory
and disk are set at `create` time by Multipass and changed by `rebuild`.

**Why**:

1. It forced elevation on the whole CLI. `Set-VMMemory`/`Set-VMProcessor`
   require an elevated shell, and the preflight therefore hard-failed
   `administrator` — which is what blocked Phases 1-6 for two days. Multipass
   itself needs no elevation; its daemon runs as LocalSystem.
2. It reported drift that did not exist. The live check compared a configured
   `32G` against a VHDX reporting `30.92` GiB — the same disk in different
   units — so `status` returned `ok: false` and exit 5 permanently.
3. A rebuild is minutes. The reconciler existed to avoid a destroy/recreate
   cycle that is no longer expensive.

**Cost of the deviation**: changing CPU/RAM/disk now requires `vibebox rebuild`
plus a restore, rather than a stop/apply/start. For a box whose home directory
is backed up and whose provisioning is idempotent, this is a fair trade. If it
proves wrong, the reconciler can return as an explicitly elevated subcommand.

**Also removed as a consequence**: `VM_MEMORY_MIN`, `VM_MEMORY_STARTUP`,
`VM_AUTOSTART`, `VM_STOP_ACTION`, `VM_NESTED_VIRT`. Nothing applied them once
`config apply` was gone, and §2.5 sets the precedent that a knob which cannot
work is worse than its absence.

---

## D-2. Hyper-V identity is corroboration, not a gate

**Work order says** (§1 standing constraint 2): never destroy anything you did
not create.

**Done instead**: the constraint is unchanged and still enforced. Ownership is
proven by the Vibebox state marker plus a verified Multipass image hash. The
Hyper-V VM id is still compared **when the shell can read it**, and a positive
mismatch still refuses. Its *absence* no longer refuses.

**Why**: `Get-VM` needs elevation, so its absence is evidence of nothing. As
written, `destroy` and `rebuild` were impossible unelevated — the safety check
blocked the safe path rather than the unsafe one.

---

## D-3. Conformance is tiered; `20-vps` is opt-in

**Work order says** (Phase 6): run the full suite, including unmodified
upstream installs of PostgreSQL, nginx, NodeSource, Python venv, timers and
sysctl.

**Done instead**: no check was deleted. `run.ps1` skips the `20-vps` group by
default and runs it under `-Full`.

**Why**: that group installs packages into the guest, so it both takes minutes
and leaves the box mutated. It is Gate A evidence, not a per-loop check. The
Gate A run uses `-Full`; the fast loop does not.

---

## D-4. The 7-day soak is proposed for reduction

**Work order says** (§2.6): 7 consecutive days, ≥3 host reboots, ≥5
sleep/resume cycles, ≥1 rebuild.

**Proposed instead**: keep every *event* requirement (reboots, sleep/resume
cycles, rebuild, clock tolerance) and drop the 7-day calendar, running the
cycles back to back instead.

**Why**: the calendar was a proxy for "has this survived real use," but the
events are what actually detect the failures — clock skew after resume,
Tailscale not reconnecting, services not coming back. Nothing in the design
degrades as a function of wall-clock time specifically.

**This one is genuinely arguable** and is the deviation most worth rejecting:
a multi-day soak does catch slow leaks and cert/token expiry that a compressed
run cannot. Recommend accepting only if you want Gate A sooner, and rejecting
if this box is going to hold real work you would miss.

---

## D-5. `GUEST_USER` changed from `dev` to `herwin`

**Work order says** (§2.2): working user `dev`, matching legacy
`SANDBOX_USERNAME`.

**Done instead**: `GUEST_USER=herwin`, applied by rebuild.

**Why**: user instruction, 2026-09-13. Taken now because the VM held no real
data, so it costs one rebuild. After Phase 7 it would mean rewriting ownership
across a populated home directory.

**Consequence handled**: `vibebox restore` gained `-SourceUser`, so an archive
whose paths are `home/dev/...` restores into `home/herwin/...` with ownership
assigned by name. Phase 7 needs this regardless, because the legacy box's data
is owned by `dev`.

---

## D-6. A2 rescue console: risk accepted by the user

**Work order says** (§8.4, Phase 1 DoD): a working rescue console is a hard
gate. If `vmconnect` cannot reach a login prompt with `sshd` stopped, that
triggers the direct-Hyper-V fallback and a scope change.

**Decided instead** (user, 2026-09-13): skip the test and accept the risk.
Stated reasoning: the home directory is backed up periodically and most
material is in git, so a box that becomes unreachable is a rebuild-and-restore
rather than a loss.

**What this costs**: if SSH breaks, there is no verified way back in. Recovery
becomes `vibebox rebuild` plus a restore, not a repair. The `61-console`
conformance check stays a permanent skip.

**Why it is defensible here**: the argument rests on the data being
reproducible, which the migration design already assumes — ownership maps by
name, provisioning is idempotent, and a full rebuild is ~4 minutes. It is a
weaker position for anything that lives *only* in the VM, so the backup
cadence is now load-bearing and should actually be scheduled rather than
assumed.

---

## D-7. Migration excludes regenerable trees

**Decided** (user, 2026-09-13): copy only non-regenerable data.

Excluded from the live 40.3 GB home: `.cache` (4.6 G), `.npm` (5.5 G),
`.venvs` (5.2 G), `.vscode-server` (3.3 G), `.rustup` (2.9 G), `.swift`
(2.5 G), `.cargo/registry`, `.cargo/git`, `go/pkg`, and every `node_modules`
(6.9 G across 36 directories).

Findings behind the decision:

- `.venvs` is **one** virtualenv (`document-tools`, Python 3.11) carrying
  docling's PyTorch CPU wheels. Large, but a single `pip install` rebuilds it.
- `.swift` was **last written 2024-12-11** — roughly twenty-one months stale.
  This is abandoned rather than cached, and is not worth reinstalling either.
- `.vscode-server` is 2.1 G of `cli` plus multiple `code-<hash>` server builds;
  VS Code reinstalls it on first remote connect.
- `.local/opt/agy-acp-server-1.1.1` is 1.9 G — a single versioned install of an
  optional-tier tool that provisioning reinstalls.
- No duplicate-interpreter problem was found. Three Python trees exist
  (3.11 in the venv, 3.12 in `.local/lib`, system 3.12) but each has a distinct
  role.

**Cost**: first use of any project needs `npm install` / `bun install`, and the
docling venv needs rebuilding.

### D-7a. docling dropped from the toolchain

**Decided** (user, 2026-09-13): "skip document-tools, and let's not install
docling at this time."

`docling` was removed from `TOOLS_OPTIONAL`. Provisioning gates the install on
`enabled_optional docling`, so the list is the only switch needed — verified in
`guest/provision/30-tools`.

Worth noting for later: the provisioning step installs docling with
`pip install --break-system-packages` into the system interpreter, whereas the
legacy box's 5.2 GB `.venvs/document-tools` was a separate hand-built
virtualenv. They were never the same installation, so dropping both removes
roughly 5.2 GB of migration payload and the PyTorch CPU wheel download from
every future provision.

`gws` remains in the optional list.
