Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lifecycle.ps1")

function Get-VibeboxBackupDirectory {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)
    $root = [Environment]::ExpandEnvironmentVariables($Config.Values.BACKUP_DEST)
    $directory = Join-Path $root $Name
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function Get-VibeboxBackupKey {
    param([Parameter(Mandatory)][string]$Name)
    $directory = Join-Path (Get-VibeboxPath -Name State) "backup"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $private = Join-Path $directory "$Name-ed25519"
    $public = "$private.pub"
    if (-not (Test-Path -LiteralPath $private -PathType Leaf)) {
        & ssh-keygen -t ed25519 -N "" -C "vibebox-backup-$Name" -f $private | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not generate the restricted backup key." }
    }
    & icacls.exe $private /inheritance:r /grant:r "${env:USERNAME}:(R)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    & icacls.exe $public /inheritance:r /grant:r "${env:USERNAME}:(R)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    return [pscustomobject]@{ PrivateKey = $private; PublicKey = (Get-Content -LiteralPath $public -Raw).Trim() }
}

function Install-VibeboxBackupKey {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$User)
    if ($User -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "Backup user is not a valid Linux login name." }
    $key = Get-VibeboxBackupKey -Name $Name
    $publicPath = Join-Path (Get-VibeboxPath -Name State) "backup\$Name.pub"
    [System.IO.File]::WriteAllText($publicPath, ($key.PublicKey.Trim() + "`n"), [System.Text.UTF8Encoding]::new($false))
    Invoke-VibeboxMultipass -Arguments @("transfer", $publicPath, "${Name}:/tmp/vibebox-backup.pub") | Out-Null
    $remote = @'
set -Eeuo pipefail
install -d -m 0700 -o __VIBEBOX_USER__ -g __VIBEBOX_USER__ /home/__VIBEBOX_USER__/.ssh
touch /home/__VIBEBOX_USER__/.ssh/authorized_keys
chmod 0600 /home/__VIBEBOX_USER__/.ssh/authorized_keys
sed -i 's/$//' /home/__VIBEBOX_USER__/.ssh/authorized_keys
pub=$(tr -d '' < /tmp/vibebox-backup.pub)
line='command="VIBEBOX_BACKUP_USER=__VIBEBOX_USER__ /usr/local/sbin/vibebox-backup-producer",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc '"$pub"
grep -Fqx "$line" /home/__VIBEBOX_USER__/.ssh/authorized_keys || printf '%s\n' "$line" >> /home/__VIBEBOX_USER__/.ssh/authorized_keys
rm -f /tmp/vibebox-backup.pub
'@
    $remote = $remote.Replace("__VIBEBOX_USER__", $User)
    $remote = $remote -replace "`r`n", "`n"
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", $remote) | Out-Null
    return $key
}

function Invoke-VibeboxHooks {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet("pre", "post")][string]$Phase
    )
    $command = 'set -Eeuo pipefail; for hook in /etc/vibebox/backup.d/' + $Phase + '/*; do if [[ -x $hook ]]; then "$hook"; printf "vibebox-hook-ran\n"; fi; done'
    return Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", $command)
}

function Invoke-VibeboxBackup {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [string]$Label
    )

    Assert-VibeboxManagedTarget -Name $Name
    $key = Install-VibeboxBackupKey -Name $Name -User $Config.Values.GUEST_USER
    $directory = Get-VibeboxBackupDirectory -Config $Config -Name $Name
    $safeLabel = if ([string]::IsNullOrWhiteSpace($Label)) {
        (Get-Date -Format "yyyyMMdd-HHmmss")
    } else {
        $Label -replace "[^A-Za-z0-9_-]", ""
    }
    if ([string]::IsNullOrWhiteSpace($safeLabel)) { throw "Backup label must contain a letter, number, underscore, or dash." }
    $archive = Join-Path $directory "$Name-backup-$safeLabel.tar.gz"
    $hooksRan = $false
    $startedForBackup = $false
    try {
        $preResult = Invoke-VibeboxHooks -Name $Name -Phase pre
        $hooksRan = @($preResult.Output | Where-Object { [string]$_ -eq "vibebox-hook-ran" }).Count -gt 0
        # A scheduled backup fires on a clock, not on the VM's state. Start a
        # stopped instance rather than failing the night's backup, and put it
        # back afterwards so the schedule does not silently leave it running.
        $info = Get-VibeboxInstanceInfo -Name $Name
        if ($null -eq $info) { throw "Managed instance '$Name' was not found." }
        if ($info.State -ne "RUNNING") {
            Write-Host "Starting '$Name' for the backup; it will be stopped again afterwards."
            $info = Start-VibeboxInstance -Name $Name -Config $Config
            $startedForBackup = $true
        }
        $sshHost = $info.IPv4
        if ([string]::IsNullOrWhiteSpace($sshHost)) { throw "The VM has no reachable local IP." }
        $sshArgs = @(
            "-i", $key.PrivateKey,
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=$(Join-Path (Get-VibeboxPath -Name State) 'backup-known-hosts')",
            "$($Config.Values.GUEST_USER)@$sshHost"
        )
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = (Get-Command ssh -ErrorAction Stop).Source
        $startInfo.UseShellExecute = $false
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($arg in $sshArgs) { $startInfo.ArgumentList.Add($arg) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $null = $process.Start()
        $stream = [IO.File]::Open($archive, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $process.StandardOutput.BaseStream.CopyTo($stream)
        } finally {
            $stream.Dispose()
        }
        $null = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            throw "The restricted backup stream failed."
        }
        $metadata = [ordered]@{
            name = $Name
            archive = (Split-Path $archive -Leaf)
            createdAt = (Get-Date).ToUniversalTime().ToString("o")
            consistency = if ($hooksRan) { "hook-quiesced" } else { "crash-consistent" }
            ownership = "recorded by name; restore maps to configured guest user"
        }
        $metadata | ConvertTo-Json | Set-Content -LiteralPath "$archive.json" -Encoding utf8
    } finally {
        Invoke-VibeboxHooks -Name $Name -Phase post
        if ($startedForBackup) {
            Write-Host "Stopping '$Name' again; it was not running before the backup."
            Stop-VibeboxInstance -Name $Name -Config $Config | Out-Null
        }
    }

    Get-ChildItem -LiteralPath $directory -Filter "$Name-backup-*.tar.gz" -File |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-[int]$Config.Values.BACKUP_RETENTION_DAYS) -and $_.Name -notmatch "-safety-" } |
        Remove-Item -Force
    Write-Host "Backup created: $archive"
    return $archive
}

function Test-VibeboxArchive {
    param(
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [string]$SourceUser
    )
    if ([string]::IsNullOrWhiteSpace($SourceUser)) { $SourceUser = $User }
    if ($SourceUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "Source user is not a valid Linux login name." }
    if (-not (Test-Path -LiteralPath $Archive -PathType Leaf)) { throw "Archive not found: $Archive" }
    if ($User -notmatch '^[a-z_][a-z0-9_-]{0,31}$') { throw "Guest user is not a valid Linux login name." }
    if ((Split-Path -Leaf $Archive) -notmatch "^$([regex]::Escape($Name))-backup-[A-Za-z0-9_-]+\.tar\.gz$") {
        throw "Archive name does not belong to instance '$Name'. Restore is name-bound and refused."
    }
    $list = & tar.exe -tzf $Archive 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Archive could not be read." }
    foreach ($entry in $list) {
        $path = [string]$entry
        if ($path.StartsWith("/") -or $path -match "(^|/)\.\.(?:/|$)" -or $path -notmatch "^home/$([regex]::Escape($SourceUser))(?:/|$)") {
            throw "Archive contains an unsafe or differently-named path: $path"
        }
    }
    return @($list)
}

function Invoke-VibeboxRestore {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Archive,
        [string]$SourceUser,
        [switch]$DryRun
    )

    $resolved = (Resolve-Path -LiteralPath $Archive -ErrorAction Stop).Path
    $targetUser = $Config.Values.GUEST_USER
    if ([string]::IsNullOrWhiteSpace($SourceUser)) { $SourceUser = $targetUser }
    $entries = Test-VibeboxArchive -Archive $resolved -Name $Name -User $targetUser -SourceUser $SourceUser
    if ($SourceUser -ne $targetUser) {
        Write-Host "Restoring archive owned by '$SourceUser' into account '$targetUser'; home paths are rewritten."
    }
    if ($DryRun) {
        $entries | ForEach-Object { Write-Host $_ }
        Write-Host "Dry run: no VM files changed."
        return
    }
    Assert-VibeboxManagedTarget -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { throw "Managed instance '$Name' was not found." }
    $wasRunning = $info.State -eq "RUNNING"
    $remoteArchive = "/tmp/$(Split-Path -Leaf $resolved)"
    try {
        if (-not $wasRunning) {
            Write-Host "Starting '$Name' temporarily for restore transfer."
            Start-VibeboxInstance -Name $Name -Config $Config | Out-Null
        }
        Invoke-VibeboxMultipass -Arguments @("transfer", $resolved, "${Name}:$remoteArchive") -TimeoutSeconds 3600 | Out-Null
        $extract = @'
set -Eeuo pipefail
# docker.socket too: stopping docker.service alone lets socket activation
# start it again in the middle of the extract.
units=(docker.socket docker.service vibebox-tailnet.service vibebox-hermes-gateway@__VIBEBOX_USER__.service vibebox-droid-daemon@__VIBEBOX_USER__.service vibebox-hermes-webui@__VIBEBOX_USER__.service)
for unit in "${units[@]}"; do systemctl stop "$unit" || true; done
# Restart the units and drop the multi-GB archive copy whether or not the
# restore succeeds; a failed run must not leave either behind.
archive='__VIBEBOX_ARCHIVE__'
root=/
home="${root%/}/home/__VIBEBOX_USER__"
trap 'for unit in "${units[@]}"; do systemctl start "$unit" || true; done; rm -f "$archive"' EXIT

# Provisioning can create a real directory where the backup holds a symlink
# or a file -- a dotfiles-managed ~/.hermes, for one. tar cannot replace a
# non-empty directory, so move each such directory aside first (kept, never
# deleted) and let the archive's entry take the path.
stamp=$(date +%Y%m%d-%H%M%S)
while IFS= read -r name; do
  case "$name" in */) continue ;; esac
  dest="$home${name#home/__VIBEBOX_SOURCE_USER__}"
  if [ -d "$dest" ] && [ ! -L "$dest" ]; then
    mv -- "$dest" "$dest.pre-restore-$stamp"
    echo "moved aside $dest -> $dest.pre-restore-$stamp (the archive has a non-directory there)"
  fi
done < <(tar --list --gzip --file "$archive")

status=0
tar --extract --gzip --file "$archive" --directory "$root" --no-same-owner   --transform 's|^home/__VIBEBOX_SOURCE_USER__$|home/__VIBEBOX_USER__|'   --transform 's|^home/__VIBEBOX_SOURCE_USER__/|home/__VIBEBOX_USER__/|' || status=$?
# Re-own even after a partial extract: --no-same-owner leaves root owning
# everything tar wrote, and a root-owned home locks the user out of it.
chown -R '__VIBEBOX_USER__:__VIBEBOX_USER__' "$home"
# A cross-account restore leaves absolute symlinks pointing at the old home.
# Retarget them, or every dotfile link silently dangles.
if [ '__VIBEBOX_SOURCE_USER__' != '__VIBEBOX_USER__' ]; then
  retargeted=0
  while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
      /home/__VIBEBOX_SOURCE_USER__/*)
        newtarget="/home/__VIBEBOX_USER__/${target#/home/__VIBEBOX_SOURCE_USER__/}"
        ln -sfn "$newtarget" "$link"
        chown -h '__VIBEBOX_USER__:__VIBEBOX_USER__' "$link"
        retargeted=$((retargeted + 1))
        ;;
    esac
  done < <(find "$home" -type l)
  echo "retargeted $retargeted absolute symlink(s) to /home/__VIBEBOX_USER__"
fi
if [ "$status" -ne 0 ]; then
  echo "tar exited $status; entries it could extract were restored and re-owned" >&2
  exit "$status"
fi
'@
        $extract = $extract.Replace("__VIBEBOX_SOURCE_USER__", $SourceUser).
            Replace("__VIBEBOX_USER__", $targetUser).
            Replace("__VIBEBOX_ARCHIVE__", $remoteArchive)
        $extract = $extract -replace "`r`n", "`n"
        # Extracting and re-owning a multi-GB home outlasts the 300s default.
        $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", $extract) -TimeoutSeconds 3600
        # Surface what moved aside and what was retargeted; both matter.
        $result.Output | ForEach-Object { Write-Host "  $_" }
        Write-Host "Restored $(($entries | Measure-Object).Count) archive entries into '$Name' as '$targetUser'."
    } finally {
        if (-not $wasRunning) {
            Invoke-VibeboxMultipass -Arguments @("stop", $Name) | Out-Null
        }
    }
}
