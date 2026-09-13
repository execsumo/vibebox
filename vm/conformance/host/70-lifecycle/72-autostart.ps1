param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"

# Vibebox no longer sets Hyper-V AutomaticStartAction (see
# vm/docs/evidence/deviations.md, D-1). Multipass restores instances that were
# running when the host shut down, so this check verifies that contract is at
# least observable, and reports honestly when it cannot see Hyper-V.
$vm = $null
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    try { $vm = Get-VM -Name $Name -ErrorAction Stop } catch { $vm = $null }
}
if ($null -eq $vm) {
    Write-Output "skip 72-autostart - Hyper-V start/stop policy needs an elevated shell; host-restart behaviour is covered by the soak instead"
    exit 77
}
if ([string]$vm.AutomaticStopAction -notin @("ShutDown", "Shutdown")) {
    Write-Output "not ok 72-autostart - Hyper-V stop action is ACPI shutdown, not Save"
    Write-Error "AutomaticStopAction: $($vm.AutomaticStopAction)"
    exit 1
}
Write-Output "ok 72-autostart - Hyper-V stop action is ACPI shutdown"
exit 0
