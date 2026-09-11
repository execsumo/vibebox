# Vibebox

Vibebox has two editions while the VM transition is under way:

- **Legacy edition:** the current daily-driver container lives in `legacy/`.
  Its root entry points remain as forwarding shims for compatibility.
- **VM edition:** the clean Ubuntu/Hyper-V implementation is being built in
  `vm/`. Start with [`vm/README.md`](vm/README.md) for its current status.

The transition decision record and executable work order are in
[`docs/vm-transition-plan.md`](docs/vm-transition-plan.md) and
[`docs/vm-work-orders.md`](docs/vm-work-orders.md).

Until the VM reaches Gate A, use the legacy edition and do not migrate real
data. The VM work order defines the validation gates and the points where user
approval is required.
