Set-StrictMode -Version Latest

# Scheduled backups.
#
# The backup is host-initiated by design (the host pulls through a restricted,
# forced-command SSH key), so the schedule belongs on the host too -- a timer
# inside the guest could not reach the archive destination.
#
# The task runs as the current user, in their own session, at normal privilege.
# It deliberately does not use "run whether logged on or not", which would
# require storing credentials.

$script:VibeboxTaskName = "Vibebox Backup"

function Get-VibeboxBackupTask {
    return Get-ScheduledTask -TaskName $script:VibeboxTaskName -ErrorAction SilentlyContinue
}

function Enable-VibeboxBackupSchedule {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$At = "12:30"
    )

    if ($At -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') {
        throw "Schedule time must be HH:mm in 24-hour form, for example 02:15."
    }
    $entry = Join-Path (Get-VibeboxRepoRoot) "vm\host\vibebox.ps1"
    if (-not (Test-Path -LiteralPath $entry -PathType Leaf)) {
        throw "Could not locate vibebox.ps1 at $entry."
    }
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue)
    if ($null -eq $pwsh) { throw "PowerShell 7 (pwsh) is required for the scheduled task." }

    $action = New-ScheduledTaskAction -Execute $pwsh.Source `
        -Argument "-NoProfile -NonInteractive -File `"$entry`" backup" `
        -WorkingDirectory (Get-VibeboxRepoRoot)
    $trigger = New-ScheduledTaskTrigger -Daily -At $At
    # A laptop is asleep or on battery at arbitrary times; a backup that only
    # runs on mains power and never catches up is not a backup.
    $settings = New-ScheduledTaskSettingsSet `
        -StartWhenAvailable `
        -DontStopIfGoingOnBatteries `
        -AllowStartIfOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 4) `
        -MultipleInstances IgnoreNew
    $description = "Pulls a Vibebox backup of /home/$($Config.Values.GUEST_USER) to $($Config.Values.BACKUP_DEST). Regenerable paths are excluded per vm/guest/regenerable.conf."

    $existing = Get-VibeboxBackupTask
    if ($null -ne $existing) {
        Set-ScheduledTask -TaskName $script:VibeboxTaskName `
            -Action $action -Trigger $trigger -Settings $settings | Out-Null
        Write-Host "Updated scheduled task '$($script:VibeboxTaskName)' to run daily at $At."
    } else {
        Register-ScheduledTask -TaskName $script:VibeboxTaskName `
            -Action $action -Trigger $trigger -Settings $settings `
            -Description $description | Out-Null
        Write-Host "Registered scheduled task '$($script:VibeboxTaskName)', daily at $At."
    }
    Write-Host "  destination : $($Config.Values.BACKUP_DEST)"
    Write-Host "  retention   : $($Config.Values.BACKUP_RETENTION_DAYS) days (labeled -safety- archives are kept)"
    Write-Host "  excluding   : $((Get-VibeboxRegenerablePaths) -join ', ')"
}

function Disable-VibeboxBackupSchedule {
    $existing = Get-VibeboxBackupTask
    if ($null -eq $existing) {
        Write-Host "No scheduled backup is registered."
        return
    }
    Unregister-ScheduledTask -TaskName $script:VibeboxTaskName -Confirm:$false
    Write-Host "Removed scheduled task '$($script:VibeboxTaskName)'. Existing archives were not touched."
}

function Show-VibeboxBackupSchedule {
    param([Parameter(Mandatory)]$Config)

    $task = Get-VibeboxBackupTask
    if ($null -eq $task) {
        Write-Host "Scheduled backup: not registered. Enable it with 'vibebox schedule enable'."
        return
    }
    $info = Get-ScheduledTaskInfo -TaskName $script:VibeboxTaskName -ErrorAction SilentlyContinue
    Write-Host "Scheduled backup: $($task.State)"
    foreach ($trigger in @($task.Triggers)) {
        if ($trigger.StartBoundary) {
            Write-Host "  runs at     : $(([datetime]$trigger.StartBoundary).ToString('HH:mm')) daily"
        }
    }
    Write-Host "  destination : $($Config.Values.BACKUP_DEST)"
    if ($null -ne $info) {
        Write-Host "  last run    : $($info.LastRunTime)  (result $($info.LastTaskResult))"
        Write-Host "  next run    : $($info.NextRunTime)"
    }

    # A schedule that has never produced an archive is not a backup.
    $directory = Get-VibeboxBackupDirectory -Config $Config -Name $Config.Values.VM_NAME
    $archives = @(Get-ChildItem -LiteralPath $directory -Filter "*.tar.gz" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending)
    if ($archives.Count -eq 0) {
        Write-Warning "No archives exist yet at $directory."
    } else {
        $newest = $archives[0]
        Write-Host "  archives    : $($archives.Count), newest $($newest.Name) ($([math]::Round($newest.Length / 1GB, 2)) GB, $($newest.LastWriteTime))"
        $age = (Get-Date) - $newest.LastWriteTime
        if ($age.TotalDays -gt 2) {
            Write-Warning "The newest archive is $([math]::Round($age.TotalDays, 1)) days old; the schedule may not be running."
        }
    }
}
