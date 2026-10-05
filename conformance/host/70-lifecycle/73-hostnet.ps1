param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"

# Multipass reaches a Hyper-V guest by "<name>.mshome.net". After a host reboot
# ICS can keep serving the previous boot's lease for that name alongside the
# new one, and start then hangs on "Starting" forever. Readable without
# elevation, so this is a real check rather than a skip.
. (Join-Path $PSScriptRoot "..\..\..\host\lib\config.ps1")
. (Join-Path $PSScriptRoot "..\..\..\host\lib\lifecycle.ps1")

$health = Get-VibeboxHostNetworkHealth -Name $Name
if (-not $health.Ok) {
    Write-Output "not ok 73-hostnet - $Name.mshome.net resolves only to a live Default Switch address"
    Write-Error $health.Detail
    exit 1
}
if (-not $health.Current) {
    Write-Output "not ok 73-hostnet - $Name.mshome.net has an ICS lease entry while the instance runs"
    exit 1
}

$guard = Get-VibeboxHostNetworkGuardTask
$guardNote = if ($null -eq $guard) { "; boot guard not installed" } else { "; boot guard installed" }
Write-Output "ok 73-hostnet - $Name.mshome.net resolves only to $($health.Current)$guardNote"
exit 0
