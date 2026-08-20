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
# Home is either the named Docker volume (default) or, when SANDBOX_HOME_HOST_PATH
# is set in .env, a host folder bind-mounted into the sandbox.
$HostHomePath = Get-EnvValue -Name "SANDBOX_HOME_HOST_PATH" -Default ""
$HomeMountSource = if ($HostHomePath) { $HostHomePath } else { "$SandboxName-home" }
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
Write-Host "Home:        $HomeMountSource" -ForegroundColor Yellow
Write-Host "Backup File: backups\$SandboxName\$Filename" -ForegroundColor Yellow
Write-Host "Retention:   $RetentionDays days" -ForegroundColor Yellow

try {
    # Mount home (named volume, or host folder when SANDBOX_HOME_HOST_PATH is set)
    # at its real path under a staging root (/stage) so the archive is root-relative
    # (home/<user>/...) and matches the in-container `backup` command. restore.ps1
    # extracts it back. .vibebox holds onboard marker files that should re-run after
    # a restore, and SSH host keys live on their own volume — so it is excluded.
    $SshVolume = "${SandboxName}-ssh-keys"
    docker volume inspect $SshVolume *>$null
    $VolumeExists = $LASTEXITCODE -eq 0

    $DockerArgs = @(
        "--rm",
        "-v", "${HomeMountSource}:/stage/home/${Username}:ro",
        "-v", "${BackupsDir}:/backup"
    )
    if ($VolumeExists) {
        $DockerArgs += "-v", "${SshVolume}:/stage/ssh-identity:ro"
    }

    $TarArgs = @(
        "czf", "/backup/$Filename",
        "--exclude=home/${Username}/.cache",
        "--exclude=home/${Username}/.npm",
        "--exclude=home/${Username}/go/pkg/mod",
        "--exclude=home/${Username}/.cargo/registry",
        "--exclude=home/${Username}/.cargo/git",
        "--exclude=home/${Username}/.vibebox",
        "-C", "/stage",
        "home/${Username}"
    )
    if ($VolumeExists) {
        $TarArgs += "ssh-identity"
    }

    $AllArgs = @("run") + $DockerArgs + @("alpine", "tar") + $TarArgs
    & docker @AllArgs

    if (-not (Test-Path $BackupPath)) {
        throw "Backup file was not created successfully."
    }

    # Prune only timestamped backups (-backup-YYYYMMDD-HHMMSS.tar.gz), so labeled
    # safety snapshots (before-refactor, pre-restore) are kept.
    Get-ChildItem -Path $BackupsDir -Filter "$SandboxName-backup-*.tar.gz" |
        Where-Object { $_.Name -match '-backup-\d{8}-\d{6}\.tar\.gz$' } |
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
