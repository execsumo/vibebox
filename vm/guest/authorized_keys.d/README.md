# Authorized SSH keys

Drop one public key per file here, named for the device it belongs to:

```
vm/guest/authorized_keys.d/laptop.pub
vm/guest/authorized_keys.d/phone.pub
```

`vibebox provision` installs every `.pub` in this directory into the guest
user's `~/.ssh/authorized_keys`, inside a marker-delimited block that
provisioning owns. Keys you add to that file by hand, outside the markers, are
left alone — so this is additive, not a reconcile, and provisioning cannot lock
you out of your own box.

**Why keys live here rather than only in the guest.** `~/.ssh/authorized_keys`
in the guest is real state, but it is not reproducible: `vibebox rebuild`
without a restore starts from a fresh home and every key you added by hand is
gone. Anything that must survive a rebuild belongs in git, which is the same
reason the tailnet registry lives in `guest/tailnet.d/`.

Public keys are not secrets — they are published to every server you connect
to — so committing them is safe and is the point. Never put a **private** key
here; nothing in `vm/guest/` should ever hold one.

The host's own managed key (`vm/state/ssh/id_ed25519.pub`) is installed
separately by cloud-init and re-asserted by `vibebox migrate`. You do not need
to copy it here.
