param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($null -eq $vm) {
    Write-Output "not ok 70-state - exact Hyper-V VM exists"
    exit 1
}
if ($vm.Generation -ne 2) {
    Write-Output "not ok 70-state - VM is Hyper-V generation 2"
    Write-Error "Generation: $($vm.Generation)"
    exit 1
}
Write-Output "ok 70-state - exact Hyper-V generation 2 VM exists"
exit 0
