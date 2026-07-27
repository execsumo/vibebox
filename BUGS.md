# Known Bugs

No known bugs at this time!

## Fixed Bugs

### `dotfiles`: "Permission denied" inside the container

**Root cause:** When Docker's `ADD` instruction fetches a remote URL, it creates the
file with `600` permissions (read/write for owner only, which is `root` here). The
previous `chmod +x` only added the execute bit, giving `711` (`-rwx--x--x`). Since
`dotfiles` is a bash script, a non-root user needs both execute *and* read
permission — bash cannot run a script it cannot read, so it failed with
"Permission denied".

**Where it reproduced:** on the tree before `1badfab`, where `/usr/local/bin/dotfiles`
stayed owned by `root`. That commit added `RUN chown -R ${USERNAME}:${USERNAME}
/usr/local /opt` (Dockerfile:247), which makes the sandbox user the *owner* — and
`711` grants the owner `rwx`. So on current `main` the symptom no longer appears
even without this fix.

**Fix applied:** `chmod 755 /usr/local/bin/dotfiles` (Dockerfile:244). Kept
deliberately: it states the intended mode directly instead of depending on a
`chown -R` three lines later that exists for unrelated reasons, and it keeps the
script readable for any user, not just uid 1000.
