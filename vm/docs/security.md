# VM security boundary

The Windows host is the control plane. The Ubuntu guest owns its filesystem,
kernel, Docker daemon, Tailscale identity, and service state. The VM receives
no Windows drive, clipboard, device, SSH agent, Docker socket, or backup
destination mount.

## Access

- `dev` is the working account and uses SSH keys only.
- `ubuntu` remains the Multipass rescue account. Its password is generated
  after first boot, stored in the ignored host state directory with a Windows
  ACL, and shown once. It is intended for the Hyper-V console, not network
  login.
- Tailscale enrollment is explicit. The node should use the `tag:vibebox` tag
  and a least-privilege tailnet policy that permits only the user's required
  SSH and service paths.
- The host firewall should treat guest traffic as untrusted. Permit only the
  local management and tailnet flows that the user has chosen.

## Backup boundary

`vibebox backup` pulls a guest-owned tar stream to a host path outside the
virtual disk. Its dedicated key is restricted in `authorized_keys` with a
forced command and `no-pty`, `no-port-forwarding`, `no-agent-forwarding`, and
`no-X11-forwarding`. It cannot open a shell.

Archives are crash-consistent unless executable hooks in
`/etc/vibebox/backup.d/pre` and `post` quiesce the relevant application. A
failing hook fails the backup; it is not hidden.

## Secret handling

`vibebox.env` contains policy and resource values only. `vibebox doctor`
rejects key-shaped values and names the variable. Tailscale, GitHub, and
Hermes credentials enter through `vibebox enroll`, one secret at a time, and
are never written to cloud-init or host logs.

This is not described as a clean credential boundary after migration. The
approved migration plan carries `~/.claude` in full, including its credentials
(E1), and copies the existing SSH private key (E2). Those are deliberate,
recorded exceptions, not secrets placed in `vibebox.env`. Tailscale state
remains excluded because duplicating the machine identity is unsafe.

Rotate a Tailscale key by revoking the old key in the tailnet admin console,
running `vibebox enroll tailscale`, and checking `vibebox status`. Rotate the
backup key by removing its restricted `authorized_keys` line and deleting the
ignored host files `vm/state/backup/<name>-ed25519` and `.pub`, then running
`vibebox backup` once to generate and install a new key.

Tailnet Services also require an administrator to permit each registry name in
the tailnet policy/grants. The guest can reconcile an allowed service but
cannot grant itself permission.

## Mount drift

Multipass mounts are forbidden. `vibebox status` reports the configured mount
list, and a non-empty list sets `ok: false` and exits with validation code 5.
Do not treat the absence of a mount as proof that a Windows administrator
cannot alter the VM; host administrator compromise remains outside this
boundary.

## Recovery

When SSH is broken, stop using network credentials and launch
`vibebox console`. The rescue password is the console credential. After
repair, rotate any credential that may have been exposed.
