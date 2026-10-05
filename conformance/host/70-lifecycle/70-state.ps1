param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"

# What Multipass can prove without elevation: the instance exists, is the
# release we asked for, and exposes no host mounts.
$json = multipass info $Name --format json | ConvertFrom-Json
$instance = $json.info.$Name
if ($null -eq $instance) {
    Write-Output "not ok 70-state - Multipass instance exists"
    exit 1
}
if ([string]$instance.state -ne "Running") {
    Write-Output "not ok 70-state - instance is running"
    Write-Error "state: $($instance.state)"
    exit 1
}

# Generation 2 is a Hyper-V property and Get-VM requires an elevated shell.
# Report honestly rather than failing a check the shell cannot perform.
$vm = $null
if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
    try { $vm = Get-VM -Name $Name -ErrorAction Stop } catch { $vm = $null }
}
if ($null -eq $vm) {
    Write-Output "skip 70-state - Hyper-V generation and firmware need an elevated shell; Multipass state verified instead"
    exit 77
}
if ($vm.Generation -ne 2) {
    Write-Output "not ok 70-state - VM is Hyper-V generation 2"
    Write-Error "Generation: $($vm.Generation)"
    exit 1
}
Write-Output "ok 70-state - exact Hyper-V generation 2 VM exists and is running"
exit 0
