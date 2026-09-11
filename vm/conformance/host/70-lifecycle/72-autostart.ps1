param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    Write-Output "not ok 72-autostart - exact Hyper-V VM exists"
    exit 1
}
if ([string]$vm.AutomaticStartAction -ne "Start") {
    Write-Output "not ok 72-autostart - Hyper-V automatic start is enabled"
    Write-Error "AutomaticStartAction: $($vm.AutomaticStartAction)"
    exit 1
}
if ([string]$vm.AutomaticStopAction -notin @("ShutDown", "Shutdown")) {
    Write-Output "not ok 72-autostart - Hyper-V stop action is ACPI shutdown"
    exit 1
}
Write-Output "ok 72-autostart - automatic start and ACPI shutdown are configured"
exit 0
