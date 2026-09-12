param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path
. (Join-Path $root "vm\host\lib\config.ps1")
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
if (-not $vm.DynamicMemoryEnabled) {
    Write-Output "not ok 70-state - Hyper-V dynamic memory is enabled"
    exit 1
}
if ([uint64]$vm.MemoryMinimum -gt [uint64]$vm.MemoryStartup -or
    [uint64]$vm.MemoryStartup -gt [uint64]$vm.MemoryMaximum) {
    Write-Output "not ok 70-state - dynamic memory bounds are ordered"
    Write-Error "Minimum: $($vm.MemoryMinimum); Startup: $($vm.MemoryStartup); Maximum: $($vm.MemoryMaximum)"
    exit 1
}
$config = Get-VibeboxConfig
$bounds = Get-VibeboxMemoryBounds -Config $config
if ([uint64]$vm.MemoryMinimum -ne $bounds.MinimumBytes -or
    [uint64]$vm.MemoryStartup -ne $bounds.StartupBytes -or
    [uint64]$vm.MemoryMaximum -ne $bounds.MaximumBytes) {
    Write-Output "not ok 70-state - dynamic memory matches Vibebox configuration"
    Write-Error "Expected: $($bounds.MinimumBytes) / $($bounds.StartupBytes) / $($bounds.MaximumBytes); actual: $($vm.MemoryMinimum) / $($vm.MemoryStartup) / $($vm.MemoryMaximum)"
    exit 1
}
Write-Output "ok 70-state - exact Hyper-V generation 2 VM exists"
exit 0
