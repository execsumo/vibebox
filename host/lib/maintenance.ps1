Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lifecycle.ps1")

# Platform maintenance jobs in the guest. They are pre-installed by
# provisioning; the user configures them with MAINTENANCE_* in vibebox.env.
# The guest side is guest/maintenance.sh.

function Show-VibeboxMaintenance {
    param([Parameter(Mandatory)][string]$Name)
    $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "/opt/vibebox/maintenance.sh", "status") -AllowFailure
    $result.Output | ForEach-Object { Write-Host $_ }
}

function Set-VibeboxMaintenance {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)
    # Push the current vibebox.env (and guest tree) the same way provisioning
    # does, then regenerate only the timers -- no toolchain reinstall.
    New-VibeboxGuestPayload -Name $Name -Config $Config
    $result = Invoke-VibeboxMultipass -Arguments @(
        "exec", $Name, "--", "sudo", "/opt/vibebox/maintenance.sh", "configure", "/opt/vibebox/vibebox.env"
    ) -AllowFailure
    $result.Output | ForEach-Object { Write-Host $_ }
    if ($result.ExitCode -ne 0) { throw "Maintenance configuration was rejected by the guest." }
}

function Start-VibeboxMaintenance {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][ValidateSet("daily", "weekly")][string]$Job)
    Write-Host "Running the $Job maintenance job now; this can take several minutes."
    $unit = "vibebox-maintenance@$Job.service"
    $run = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "systemctl", "start", $unit) -TimeoutSeconds 3600 -AllowFailure
    $log = Invoke-VibeboxMultipass -Arguments @(
        "exec", $Name, "--", "sudo", "journalctl", "-u", $unit, "--no-pager", "-o", "cat", "--since", "-3h", "-n", "60"
    ) -AllowFailure
    $log.Output | ForEach-Object { Write-Host $_ }
    if ($run.ExitCode -ne 0) { throw "The $Job maintenance job failed; see the output above." }
}
