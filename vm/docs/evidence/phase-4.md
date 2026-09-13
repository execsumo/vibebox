# Phase 4 evidence: security and enrollment

Status: implementation present; live secret and console checks are pending.

Cloud-init contains only a public working-user key and bootstrap code. Secret
enrollment is interactive and uses stdin without writing credentials to
metadata or logs. Rescue password generation is post-boot and host-state ACL
restricted. Backup access is forced-command and forwarding-disabled.

The updated migration decision records two later, deliberate exceptions:
`~/.claude` is carried with its credentials (E1), and the existing SSH private
key is copied (E2). Tailscale machine state remains excluded. These exceptions
are not exercised during Phases 0–6.

Do not run enrollment during repository validation. The proof VM must verify
empty secret searches in instance metadata, no mounts, the backup key's lack
of shell access, and a deliberate mount-drift failure.
