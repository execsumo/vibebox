param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
$json = multipass info $Name --format json | ConvertFrom-Json
$instance = $json.info.$Name
# Multipass reports no mounts as an empty object, and an empty PSCustomObject
# is truthy -- count its properties, not its truthiness.
$mounts = @()
if ($null -ne $instance.mounts) {
    $mounts = @($instance.mounts.PSObject.Properties | ForEach-Object { $_.Name })
}
if ($mounts.Count -ne 0) {
    Write-Output "not ok 60-mounts - no host directories are mounted"
    Write-Error ($mounts -join "; ")
    exit 1
}
Write-Output "ok 60-mounts - no host directories are mounted"
exit 0
