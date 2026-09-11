param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
$json = multipass info $Name --format json | ConvertFrom-Json
$instance = $json.info.$Name
$mounts = @($instance.mounts | Where-Object { $_ })
if ($mounts.Count -ne 0) {
    Write-Output "not ok 60-mounts - no host directories are mounted"
    Write-Error ($mounts -join "; ")
    exit 1
}
Write-Output "ok 60-mounts - no host directories are mounted"
exit 0
