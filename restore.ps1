# PowerShell script to restore the sandbox home directory from a backup.
# Usage:
#   .\restore.ps1                 # Interactively select a backup
#   .\restore.ps1 "before-llm"    # Restores '<sandbox>-backup-before-llm.tar.gz'

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

function Resolve-BackupName {
    param(
        [string]$SandboxName,
        [string]$SpecifiedName
    )

    if ($SpecifiedName -match '[\\/]' -or $SpecifiedName -match '\.\.') {
        throw "Backup name must not contain path separators or parent-directory references."
    }

    if ($SpecifiedName -like "$SandboxName-backup-*.tar.gz") {
        return $SpecifiedName
    }

    if ($SpecifiedName -like "backup-*.tar.gz") {
        return "$SandboxName-$SpecifiedName"
    }

    return "$SandboxName-backup-$SpecifiedName.tar.gz"
}

$SandboxName = Get-EnvValue -Name "SANDBOX_NAME" -Default "vibebox"
$Username = Get-EnvValue -Name "SANDBOX_USERNAME" -Default "dev"
$VolumeName = "$SandboxName-home"
$EtcVolume = "$SandboxName-etc"
$OptVolume = "$SandboxName-opt"
$UsrLocalVolume = "$SandboxName-usr-local"
$BackupsDir = Join-Path $PSScriptRoot "backups\$SandboxName"
$EscapedSandboxName = [regex]::Escape($SandboxName)

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         Restoring Sandbox Home State         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Sandbox: $SandboxName" -ForegroundColor Yellow
Write-Host "Volume:  $VolumeName" -ForegroundColor Yellow

if (-not (Test-Path $BackupsDir)) {
    Write-Host "No backups folder found at $BackupsDir." -ForegroundColor Yellow
    Write-Host "Use .\backup.ps1 to create one first." -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Cyan
    exit
}

$SelectedFile = $null
$SpecifiedName = $args[0]

if ($SpecifiedName) {
    $Filename = Resolve-BackupName -SandboxName $SandboxName -SpecifiedName $SpecifiedName
    if ($Filename -notmatch "^$EscapedSandboxName-backup-[a-zA-Z0-9_-]+\.tar\.gz$" -and
        $Filename -notmatch "^$EscapedSandboxName-backup-\d{8}-\d{6}\.tar\.gz$") {
        throw "Backup filename is not valid for this sandbox."
    }

    $SelectedFile = Join-Path $BackupsDir $Filename
    if (-not (Test-Path $SelectedFile)) {
        Write-Host "ERROR: Backup file not found at $SelectedFile" -ForegroundColor Red
        Write-Host "==============================================" -ForegroundColor Cyan
        exit
    }
} else {
    $Backups = Get-ChildItem -Path $BackupsDir -Filter "$SandboxName-backup-*.tar.gz" | Sort-Object LastWriteTime -Descending

    if ($Backups.Count -eq 0) {
        Write-Host "No backups found in $BackupsDir." -ForegroundColor Yellow
        Write-Host "Use .\backup.ps1 to create one first." -ForegroundColor Yellow
        Write-Host "==============================================" -ForegroundColor Cyan
        exit
    }

    Write-Host ""
    Write-Host "Available backups for '$SandboxName' (newest first):" -ForegroundColor Yellow
    for ($i = 0; $i -lt $Backups.Count; $i++) {
        $Size = $Backups[$i].Length / 1MB
        $Date = $Backups[$i].LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        Write-Host "  [$($i + 1)] $($Backups[$i].Name) ($($Size.ToString('F2')) MB - $Date)" -ForegroundColor Cyan
    }

    Write-Host ""
    $Selection = Read-Host "Select a backup number to restore (1-$($Backups.Count)) or press Enter to cancel"

    if (-not $Selection -or $Selection -match '[^0-9]') {
        Write-Host "Cancelled." -ForegroundColor Yellow
        Write-Host "==============================================" -ForegroundColor Cyan
        exit
    }

    $Index = [int]$Selection - 1
    if ($Index -lt 0 -or $Index -ge $Backups.Count) {
        Write-Host "Invalid selection. Cancelled." -ForegroundColor Red
        Write-Host "==============================================" -ForegroundColor Cyan
        exit
    }

    $SelectedFile = $Backups[$Index].FullName
}

$Filename = Split-Path $SelectedFile -Leaf
if ($Filename -notmatch "^$EscapedSandboxName-backup-[a-zA-Z0-9_-]+\.tar\.gz$" -and
    $Filename -notmatch "^$EscapedSandboxName-backup-\d{8}-\d{6}\.tar\.gz$") {
    throw "Backup filename is not valid for this sandbox."
}

Write-Host ""
Write-Host "WARNING: Restoring will completely overwrite the home volume, plus the" -ForegroundColor Red
Write-Host "         persisted /etc, /opt, and /usr/local volumes for this sandbox." -ForegroundColor Red
Write-Host "Target Backup: backups\$SandboxName\$Filename" -ForegroundColor Yellow
$Confirm = Read-Host "Are you absolutely sure you want to restore? (y/N)"

if ($Confirm -ne "y" -and $Confirm -ne "yes") {
    Write-Host "Cancelled." -ForegroundColor Yellow
    Write-Host "==============================================" -ForegroundColor Cyan
    exit
}

try {
    Write-Host ""
    Write-Host "1/4 Creating pre-restore safety backup..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot "backup.ps1") "pre-restore"

    Write-Host "2/4 Stopping the active workspace container..." -ForegroundColor Cyan
    docker compose stop sandbox

    Write-Host "3/4 Wiping current active files, including hidden files, and extracting backup..." -ForegroundColor Cyan
    # Mount each volume at its real path under /s and let the archive layout drive
    # extraction. New (root-relative) archives begin with home/...; legacy archives
    # are home-relative and restore into the home volume only.
    $RestoreScript = @'
set -e
F="$1"
U="$2"
HOME_DIR="/restore-stage/home/$U"
FIRST=$(tar tzf "/backup/$F" 2>/dev/null | head -n 1)
case "$FIRST" in
  home/*)
    echo "Full archive detected; restoring home, /etc, /opt, /usr/local."
    for d in "$HOME_DIR" /restore-stage/etc /restore-stage/opt /restore-stage/usr/local; do
      find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    done
    tar xzf "/backup/$F" -C /restore-stage
    ;;
  *)
    echo "Legacy home-only archive detected; restoring home directory only."
    find "$HOME_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    tar xzf "/backup/$F" -C "$HOME_DIR"
    ;;
esac
'@
    # Strip CR so the script is valid for busybox sh regardless of file line endings.
    $RestoreScript = $RestoreScript -replace "`r", ""
    docker run --rm `
        -v "${VolumeName}:/restore-stage/home/${Username}" `
        -v "${EtcVolume}:/restore-stage/etc" `
        -v "${OptVolume}:/restore-stage/opt" `
        -v "${UsrLocalVolume}:/restore-stage/usr/local" `
        -v "${BackupsDir}:/backup:ro" `
        alpine sh -c $RestoreScript sh "$Filename" "$Username"

    Write-Host "4/4 Restarting the workspace container..." -ForegroundColor Cyan
    docker compose start sandbox

    Write-Host ""
    Write-Host "Restore completed successfully." -ForegroundColor Green
    Write-Host "Sandbox '$SandboxName' has been rewound to: backups\$SandboxName\$Filename" -ForegroundColor Green
} catch {
    Write-Host ""
    Write-Host "ERROR: Restore failed: $_" -ForegroundColor Red
    Write-Host "Attempting to restart the container..." -ForegroundColor Yellow
    docker compose start sandbox | Out-Null
}

Write-Host "==============================================" -ForegroundColor Cyan
