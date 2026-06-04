# PowerShell script to take a backup of the sandbox workspace home directory.
# Usage:
#   .\backup.ps1                 # Creates a timestamped backup
#   .\backup.ps1 "before-llm"    # Creates '<sandbox>-backup-before-llm.tar.gz'

$ErrorActionPreference = "Stop"

function Get-EnvValue {
    param(
        [string]$Name,
        [string]$Default
    )

    $EnvPath = Join-Path $PSScriptRoot ".env"
    if (Test-Path $EnvPath) {
        foreach ($Line in Get-Content $EnvPath) {
            if ($Line -match "^\s*$Name\s*=\s*(.+?)\s*$") {
                return $Matches[1].Trim()
            }
        }
    }

    return $Default
}

$SandboxName = Get-EnvValue -Name "SANDBOX_NAME" -Default "vibebox"
$Username = Get-EnvValue -Name "SANDBOX_USERNAME" -Default "dev"
$VolumeName = "$SandboxName-home"
$EtcVolume = "$SandboxName-etc"
$OptVolume = "$SandboxName-opt"
$UsrLocalVolume = "$SandboxName-usr-local"
$RetentionDays = [int](Get-EnvValue -Name "BACKUP_RETENTION_DAYS" -Default "7")
$BackupsDir = Join-Path $PSScriptRoot "backups\$SandboxName"

if (-not (Test-Path $BackupsDir)) {
    New-Item -Path $BackupsDir -ItemType Directory | Out-Null
}

$Name = $args[0]
if (-not $Name) {
    $Timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $Filename = "$SandboxName-backup-$Timestamp.tar.gz"
} else {
    $Sanitized = $Name -replace '[^a-zA-Z0-9_-]', ''
    if (-not $Sanitized) {
        throw "Backup label must contain at least one letter, number, underscore, or dash."
    }
    $Filename = "$SandboxName-backup-$Sanitized.tar.gz"
}

$BackupPath = Join-Path $BackupsDir $Filename

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         Creating Sandbox Home Backup         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Sandbox:     $SandboxName" -ForegroundColor Yellow
Write-Host "Volume:      $VolumeName" -ForegroundColor Yellow
Write-Host "Backup File: backups\$SandboxName\$Filename" -ForegroundColor Yellow
Write-Host "Retention:   $RetentionDays days" -ForegroundColor Yellow

try {
    # Mount each persisted volume at its real path under a staging root (/s) so the
    # archive is root-relative (home/<user>/..., etc/..., opt/..., usr/local/...) and
    # matches the in-container `backup` command. restore.ps1 distributes it back.
    docker run --rm `
        -v "${VolumeName}:/stage/home/${Username}:ro" `
        -v "${EtcVolume}:/stage/etc:ro" `
        -v "${OptVolume}:/stage/opt:ro" `
        -v "${UsrLocalVolume}:/stage/usr/local:ro" `
        -v "${BackupsDir}:/backup" `
        alpine tar czf "/backup/$Filename" -C /stage "home/${Username}" etc opt usr/local

    if (-not (Test-Path $BackupPath)) {
        throw "Backup file was not created successfully."
    }

    Get-ChildItem -Path $BackupsDir -Filter "$SandboxName-backup-*.tar.gz" |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays) } |
        Remove-Item -Force

    $Size = (Get-Item $BackupPath).Length / 1MB
    Write-Host ""
    Write-Host "Backup created successfully." -ForegroundColor Green
    Write-Host "Location:  $BackupPath" -ForegroundColor Green
    Write-Host "File Size: $($Size.ToString('F2')) MB" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "ERROR: Failed to create backup: $_" -ForegroundColor Red
}

Write-Host "==============================================" -ForegroundColor Cyan
