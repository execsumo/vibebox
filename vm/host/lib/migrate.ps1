Set-StrictMode -Version Latest

# Phase 7: bring a legacy home directory into the VM.
#
# Read-only at the source. The archive is never modified, and nothing is run
# against the legacy container -- the input is a tarball the legacy box already
# produced, which is why it carries real POSIX modes, ownership and symlinks
# that a Windows-side copy of the same tree would have lost.
#
# Regenerable caches are skipped by default. They dominate the archive size and
# rebuild themselves on first use; -IncludeCaches copies them anyway.

# The exclusion list lives in guest/regenerable.conf so the guest-side backup
# producer and this host-side migration cannot drift apart.
function Get-VibeboxRegenerablePaths {
    $list = Join-Path (Get-VibeboxRepoRoot) "vm/guest/regenerable.conf"
    if (-not (Test-Path -LiteralPath $list -PathType Leaf)) {
        throw "Missing $list; it defines what counts as regenerable."
    }
    return @(Get-Content -LiteralPath $list |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith("#") })
}

function Invoke-VibeboxMigrate {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Archive,
        [Parameter(Mandatory)][string]$SourceUser,
        [switch]$IncludeCaches,
        [switch]$DryRun
    )

    $resolved = (Resolve-Path -LiteralPath $Archive -ErrorAction Stop).Path
    $targetUser = $Config.Values.GUEST_USER
    if ($SourceUser -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw "Source user is not a valid Linux login name."
    }
    $archiveItem = Get-Item -LiteralPath $resolved
    $sizeGb = [math]::Round($archiveItem.Length / 1GB, 2)

    Write-Host "Migration plan"
    Write-Host "  archive     : $resolved ($sizeGb GB, written $($archiveItem.LastWriteTime.ToString('yyyy-MM-dd')))"
    Write-Host "  source home : /home/$SourceUser"
    Write-Host "  target      : ${Name}:/home/${targetUser}"
    $excludes = if ($IncludeCaches) { @() } else { Get-VibeboxRegenerablePaths }
    if ($excludes.Count -gt 0) {
        Write-Host "  skipping    : $($excludes -join ', ')  (regenerable; use -IncludeCaches to copy)"
    }
    if ($DryRun) {
        Write-Host "Dry run: nothing was transferred or extracted."
        return
    }

    Assert-VibeboxManagedTarget -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { throw "Managed instance '$Name' was not found." }
    if ($info.State -ne "RUNNING") {
        throw "Instance '$Name' must be running to migrate into it."
    }

    $remoteArchive = "/tmp/vibebox-migrate.tar.gz"
    Write-Host "Transferring archive to the guest (this is the slow part)..."
    Invoke-VibeboxMultipass -Arguments @("transfer", $resolved, "${Name}:$remoteArchive") -TimeoutSeconds 3600 | Out-Null

    $excludeArgs = ($excludes | ForEach-Object {
        if ($_.StartsWith("*/")) { "--exclude='$($_.Substring(2))'" }
        else { "--exclude='home/$SourceUser/$_'" }
    }) -join " "

    # Extract into a staging directory rather than /, so nothing can land
    # outside the tree and the result is inspectable before it becomes $HOME.
    $script = @'
set -Eeuo pipefail
stage=/var/tmp/vibebox-migrate-stage
rm -rf "$stage"; mkdir -p "$stage"

tar --extract --gzip --file '__ARCHIVE__' --directory "$stage" --no-same-owner \
    __EXCLUDES__

src="$stage/home/__SRC__"
[ -d "$src" ] || { echo "archive does not contain home/__SRC__" >&2; exit 1; }

dest=/home/__DST__
mkdir -p "$dest"

# Copy into the existing home rather than replacing it: the provisioned
# account already has shell state and tool directories worth keeping.
#
# rsync --force, not cp -a. Provisioning and the archive can disagree about an
# entry's *type* -- e.g. the hermes installer creates ~/.hermes as a real
# directory, while the archive has it as a symlink into ~/.dotfiles. cp cannot
# replace a directory with a symlink and aborts the whole migration partway.
# The archive is the user's actual state, so it wins.
if command -v rsync >/dev/null 2>&1; then
    rsync -a --force "$src/" "$dest/"
else
    # Fall back to cp, clearing type conflicts first so it cannot abort.
    while IFS= read -r -d "" srcpath; do
        rel=${srcpath#"$src/"}
        dstpath="$dest/$rel"
        if [ -e "$dstpath" ] || [ -L "$dstpath" ]; then
            if [ -L "$srcpath" ] && [ -d "$dstpath" ] && [ ! -L "$dstpath" ]; then
                rm -rf "$dstpath"
            elif [ -d "$srcpath" ] && [ ! -L "$srcpath" ] && [ -L "$dstpath" ]; then
                rm -f "$dstpath"
            fi
        fi
    done < <(find "$src" -mindepth 1 -maxdepth 2 -print0)
    cp -a "$src/." "$dest/"
fi

chown -R '__DST__:__DST__' "$dest"

# Absolute symlinks still point at the old home; retarget them or every
# dotfile link silently dangles.
retargeted=0
while IFS= read -r link; do
    target=$(readlink "$link")
    case "$target" in
        /home/__SRC__/*)
            ln -sfn "/home/__DST__/${target#/home/__SRC__/}" "$link"
            chown -h '__DST__:__DST__' "$link"
            retargeted=$((retargeted + 1))
            ;;
    esac
done < <(find "$dest" -type l)

# The archive carries the legacy ~/.ssh, which overwrites the authorized_keys
# cloud-init installed -- locking the host out of the box it just migrated
# into. Re-assert the managed key rather than losing access.
install -d -m 700 -o __DST__ -g __DST__ "$dest/.ssh"
touch "$dest/.ssh/authorized_keys"
grep -qF '__MANAGED_KEY__' "$dest/.ssh/authorized_keys"     || echo '__MANAGED_KEY__' >> "$dest/.ssh/authorized_keys"
chown __DST__:__DST__ "$dest/.ssh/authorized_keys"
chmod 600 "$dest/.ssh/authorized_keys"

rm -rf "$stage" '__ARCHIVE__'

echo "migrated into $dest"
echo "retargeted $retargeted absolute symlink(s) from /home/__SRC__"
'@
    $managedKey = (Get-VibeboxSshKey).PublicKey
    $script = $script.Replace("__MANAGED_KEY__", $managedKey).
        Replace("__ARCHIVE__", $remoteArchive).
        Replace("__EXCLUDES__", $excludeArgs).
        Replace("__SRC__", $SourceUser).
        Replace("__DST__", $targetUser)

    Write-Host "Extracting and reconciling ownership in the guest..."
    $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", $script) -TimeoutSeconds 3600
    $result.Output | ForEach-Object { Write-Host "  $_" }

    # Verification is a separate call with its own budget: walking a large home
    # is slow, and a slow count must not be reported as a failed migration.
    $verify = @'
dest=/home/__DST__
echo "entries: $(find "$dest" -mindepth 1 | wc -l)"
echo "size: $(du -sh "$dest" | cut -f1)"
echo "dangling symlinks: $(find "$dest" -xtype l | wc -l)"
echo "not owned by __DST__: $(find "$dest" ! -user __DST__ | wc -l)"
'@.Replace("__DST__", $targetUser)
    $check = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", $verify) -TimeoutSeconds 1800 -AllowFailure
    if ($check.ExitCode -eq 0) {
        $check.Output | ForEach-Object { Write-Host "  $_" }
    } else {
        Write-Warning "Migration finished, but verification did not complete. Check the guest manually."
    }
    Write-Host "Migration complete."
}
