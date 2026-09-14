[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",

    [Parameter(Position = 1)]
    [string]$Subcommand,

    [Parameter(Position = 2, ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArguments = @(),

    [string]$Name,
    [int]$Cpus,
    [string]$Memory,
    [string]$Disk,
    [string]$Release,
    [switch]$Restart,
    [switch]$Confirm,
    [switch]$Json,
    [string]$Archive,
    [string]$Label,
    [string]$SourceUser,
    [string]$At,
    [string]$KeyFrom,
    [string]$Tag,
    [switch]$IncludeCaches,
    [switch]$ToolsOnly,
    [switch]$OsOnly,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$RemainingArguments = @($RemainingArguments)

$lib = Join-Path $PSScriptRoot "lib"
. (Join-Path $lib "config.ps1")
. (Join-Path $lib "preflight.ps1")
. (Join-Path $lib "sshconfig.ps1")
. (Join-Path $lib "lifecycle.ps1")
. (Join-Path $lib "status.ps1")
. (Join-Path $lib "secrets.ps1")
. (Join-Path $lib "backup.ps1")
. (Join-Path $lib "migrate.ps1")
. (Join-Path $lib "schedule.ps1")
. (Join-Path $lib "tailnet.ps1")

$ExitUsage = 1
$ExitPreflight = 2
$ExitMissing = 3
$ExitValidation = 5
$ExitOperation = $ExitValidation - $ExitUsage

function Show-VibeboxUsage {
    @"
vibebox doctor
vibebox config show
vibebox create [-Name] [-Cpus] [-Memory] [-Disk] [-Release]
vibebox start|stop|restart [-Name]
vibebox destroy [-Name] -Confirm
vibebox status [-Name] [-Json]
vibebox ssh [-Name] [-- <command>]
vibebox console [-Name]
vibebox provision [-Name]
vibebox update [-Name] [-ToolsOnly] [-OsOnly]
vibebox memory <show|apply>
vibebox rebuild [-Name] -Confirm
vibebox backup [-Name] [-Label <label>]
vibebox schedule <enable|disable|status> [-At HH:mm]
vibebox restore [-Name] -Archive <path> [-SourceUser <user>] [-DryRun]
vibebox migrate [-Name] -Archive <path> -SourceUser <user> [-IncludeCaches] [-DryRun]
vibebox conformance [-Name] [-Json]
vibebox enroll <tailscale|github|hermes> [-KeyFrom <env-file>] [-Tag <tag:name>]
vibebox tailnet <list|add|remove|apply>
"@
}

function Resolve-VibeboxName {
    param([Parameter(Mandatory)]$Config)
    if (-not [string]::IsNullOrWhiteSpace($Name)) { return $Name }
    return $Config.Values.VM_NAME
}

function Get-VibeboxManagedNames {
    $directory = Join-Path (Get-VibeboxPath -Name State) "instances"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $directory -Filter "*.json" -File |
        ForEach-Object { $_.BaseName })
}

function Resolve-VibeboxExistingName {
    param([Parameter(Mandatory)]$Config)
    $candidate = Resolve-VibeboxName -Config $Config
    if (Test-VibeboxManagedInstance -Name $candidate) { return $candidate }
    $managed = @(Get-VibeboxManagedNames)
    if ([string]::IsNullOrWhiteSpace($Name) -and $managed.Count -eq 1) {
        return $managed[0]
    }
    return $candidate
}

function Assert-VibeboxConfirmation {
    param([Parameter(Mandatory)][string]$Action, [Parameter(Mandatory)][string]$Target)
    if (-not $Confirm) {
        throw "$Action requires -Confirm. Resolved target: $Target. No changes were made."
    }
}

function ConvertTo-VibeboxBytes {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)
    return ConvertTo-VibeboxSizeBytes -Value $Value -Name $Name
}

try {
    switch ($Command.ToLowerInvariant()) {
        "help" {
            Show-VibeboxUsage
            exit 0
        }
        "doctor" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $secretKeys = @(Find-VibeboxSecretConfiguration -Config $config)
            $gpuKeys = @(Find-VibeboxGpuConfiguration -Config $config)
            if ($secretKeys.Count -gt 0) {
                throw "vibebox.env contains key-shaped secret values in: $($secretKeys -join ', '). Remove them; enroll secrets explicitly."
            }
            if ($gpuKeys.Count -gt 0) {
                Write-Warning "GPU-related configuration is ignored: $($gpuKeys -join ', '). The VM is CPU-only; keep GPU workloads on the host path."
            }
            Assert-VibeboxPreflight -Config $config
            Write-Host "Vibebox host preflight passed."
            exit 0
        }
        "config" {
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { throw "config requires show." }
            $config = Get-VibeboxConfig -CreateIfMissing
            switch ($Subcommand.ToLowerInvariant()) {
                "show" {
                    Get-VibeboxConfigDisplay -Config $config | Format-Table -AutoSize
                    exit 0
                }
                default { throw "Unknown config operation '$Subcommand'." }
            }
        }
        "create" {
            $argumentMap = @{
                Name = $Name
                Cpus = if ($Cpus -gt 0) { $Cpus } else { $null }
                Memory = $Memory
                Disk = $Disk
                Release = $Release
            }
            $config = Get-VibeboxConfig -Overrides (Get-VibeboxConfigOverridesFromArguments -Arguments $argumentMap) -CreateIfMissing
            New-VibeboxInstance -Config $config | Out-Null
            Ensure-VibeboxRescuePassword -Name $config.Values.VM_NAME -User $config.Values.GUEST_USER | Out-Null
            Write-Host "Vibebox '$($config.Values.VM_NAME)' is ready."
            exit 0
        }
        "start" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            if (-not (Test-VibeboxManagedInstance -Name $target)) { throw "Instance '$target' was not found." }
            Start-VibeboxInstance -Name $target -Config $config | Out-Null
            Write-Host "Vibebox '$target' is running."
            exit 0
        }
        "stop" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Stop-VibeboxInstance -Name $target -Config $config | Out-Null
            Write-Host "Vibebox '$target' is stopped."
            exit 0
        }
        "restart" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Restart-VibeboxInstance -Name $target -Config $config | Out-Null
            Write-Host "Vibebox '$target' restarted."
            exit 0
        }
        "destroy" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxConfirmation -Action "Destroy" -Target $target
            Remove-VibeboxInstance -Name $target
            exit 0
        }
        "status" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            $status = Get-VibeboxStatus -Config $config -Name $target
            if ($Json) {
                $status | ConvertTo-Json -Depth 12 -Compress
            } else {
                $status | Format-List
                if ($status.configDrift.Count -gt 0) {
                    [Console]::Error.WriteLine("WARNING: create-time configuration drift. Reconcile with 'vibebox rebuild -Confirm', or revert vibebox.env.")
                }
            }
            if ($status.state -in @("unknown", "stopped")) { exit $ExitMissing }
            if (-not $status.ok) { exit $ExitValidation }
            exit 0
        }
        "ssh" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            $info = Start-VibeboxInstance -Name $target -Config $config
            Update-VibeboxSshAlias -Name $target -User $config.Values.GUEST_USER -Address $info.IPv4 | Out-Null
            & ssh $target @RemainingArguments
            exit $LASTEXITCODE
        }
        "console" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            $vmconnect = Get-Command vmconnect.exe -ErrorAction Stop
            Start-Process -FilePath $vmconnect.Source -ArgumentList @("localhost", $target)
            exit 0
        }
        "provision" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            New-VibeboxGuestPayload -Name $target -Config $config
            Invoke-VibeboxGuestProvision -Name $target
            exit 0
        }
        "memory" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            $bounds = "min $($config.Values.VM_MEMORY_MIN), startup $($config.Values.VM_MEMORY_STARTUP), max $($config.Values.VM_MEMORY)"
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { $Subcommand = "show" }
            switch ($Subcommand.ToLowerInvariant()) {
                "show" {
                    Write-Host "configured: $bounds"
                    $vm = Get-VibeboxHyperVInstance -Name $target
                    if ($null -eq $vm) {
                        Write-Host "live      : unreadable without an elevated shell"
                    } else {
                        Write-Host "live      : dynamic=$($vm.DynamicMemoryEnabled) min=$([math]::Round($vm.MemoryMinimum/1GB,2))G startup=$([math]::Round($vm.MemoryStartup/1GB,2))G max=$([math]::Round($vm.MemoryMaximum/1GB,2))G"
                    }
                    exit 0
                }
                "apply" {
                    $info = Get-VibeboxInstanceInfo -Name $target
                    $wasRunning = ($null -ne $info -and $info.State -eq "RUNNING")
                    if ($wasRunning) {
                        Write-Host "Stopping $target; Hyper-V only accepts memory changes while it is off."
                        Stop-VibeboxInstance -Name $target -Config $config | Out-Null
                    }
                    if (Get-VibeboxHyperVInstance -Name $target) {
                        $null = Set-VibeboxDynamicMemory -Name $target -Config $config
                    } else {
                        # Re-run just this step elevated rather than making the
                        # user open an admin shell and retype it.
                        Write-Host "Requesting elevation to set dynamic memory ($bounds)..."
                        $script = "Set-VM -Name $target -DynamicMemory -MemoryMinimumBytes $((ConvertTo-VibeboxSizeBytes -Value $config.Values.VM_MEMORY_MIN -Name VM_MEMORY_MIN)) -MemoryStartupBytes $((ConvertTo-VibeboxSizeBytes -Value $config.Values.VM_MEMORY_STARTUP -Name VM_MEMORY_STARTUP)) -MemoryMaximumBytes $((ConvertTo-VibeboxSizeBytes -Value $config.Values.VM_MEMORY -Name VM_MEMORY))"
                        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList "-NoProfile","-Command",$script
                        if ($p.ExitCode -ne 0) { throw "Elevated memory change failed with exit code $($p.ExitCode)." }
                        Write-Host "Dynamic memory applied: $bounds."
                    }
                    if ($wasRunning) { Start-VibeboxInstance -Name $target -Config $config | Out-Null }
                    exit 0
                }
                default { throw "Unknown memory operation $Subcommand. Use show or apply." }
            }
        }
        "update" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            if ($ToolsOnly -and $OsOnly) { throw "Use either -ToolsOnly or -OsOnly, not both." }
            $mode = if ($ToolsOnly) { "tools" } elseif ($OsOnly) { "os" } else { "all" }
            # An OS upgrade is slow and can restart services, so give this the
            # long allowance rather than the 300s default.
            $result = Invoke-VibeboxMultipass -Arguments @(
                "exec", $target, "--", "sudo", "/opt/vibebox/update.sh",
                "/etc/vibebox/vibebox.env", $mode
            ) -TimeoutSeconds 3600
            $result.Output | ForEach-Object { Write-Host $_ }
            exit 0
        }
        "rebuild" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxConfirmation -Action "Rebuild" -Target $target
            # Validate the create plan before destroying anything. A rebuild
            # that destroys and then fails to create leaves no VM at all.
            Assert-VibeboxCreatePlan -Config $config
            Remove-VibeboxInstance -Name $target
            New-VibeboxInstance -Config $config | Out-Null
            Ensure-VibeboxRescuePassword -Name $config.Values.VM_NAME -User $config.Values.GUEST_USER | Out-Null
            exit 0
        }
        "backup" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Invoke-VibeboxBackup -Config $config -Name $target -Label $Label | Out-Null
            exit 0
        }
        "schedule" {
            $config = Get-VibeboxConfig -CreateIfMissing
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { $Subcommand = "status" }
            switch ($Subcommand.ToLowerInvariant()) {
                "enable" {
                    if ([string]::IsNullOrWhiteSpace($At)) { $At = "12:30" }
                    Enable-VibeboxBackupSchedule -Config $config -At $At
                    exit 0
                }
                "disable" { Disable-VibeboxBackupSchedule; exit 0 }
                "status"  { Show-VibeboxBackupSchedule -Config $config; exit 0 }
                default { throw "Unknown schedule operation '$Subcommand'. Use enable, disable, or status." }
            }
        }
        "migrate" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            if ([string]::IsNullOrWhiteSpace($Archive)) { throw "migrate requires -Archive <path>." }
            if ([string]::IsNullOrWhiteSpace($SourceUser)) { throw "migrate requires -SourceUser <name> (the account the archive was made under)." }
            Invoke-VibeboxMigrate -Config $config -Name $target -Archive $Archive -SourceUser $SourceUser -IncludeCaches:$IncludeCaches -DryRun:$DryRun
            exit 0
        }
        "restore" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            if ([string]::IsNullOrWhiteSpace($Archive)) { throw "restore requires -Archive <path>." }
            Invoke-VibeboxRestore -Config $config -Name $target -Archive $Archive -SourceUser $SourceUser -DryRun:$DryRun
            exit 0
        }
        "enroll" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { throw "enroll requires tailscale, github, or hermes." }
            $enrollTag = if (-not [string]::IsNullOrWhiteSpace($Tag)) { $Tag } else { [string]$config.Values["TAILSCALE_TAG"] }
            Invoke-VibeboxEnroll -Name $target -User $config.Values.GUEST_USER -Provider $Subcommand -KeyFrom $KeyFrom -Tag $enrollTag
            exit 0
        }
        "tailnet" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { throw "tailnet requires list, add, remove, or apply." }
            switch ($Subcommand.ToLowerInvariant()) {
                "list" {
                    $tailnet = Get-VibeboxTailnetStatus -Name $target
                    if ($null -eq $tailnet) { throw "Tailnet status is unavailable from guest '$target'." }
                    if ($Json) { $tailnet | ConvertTo-Json -Depth 8 -Compress } else { $tailnet | Format-List }
                    exit 0
                }
                "apply" {
                    Apply-VibeboxTailnetServices -Name $target
                    exit 0
                }
                "add" {
                    if ($RemainingArguments.Count -lt 3) { throw "tailnet add requires <name> --target <url>." }
                    $service = $RemainingArguments[0]
                    $targetUrl = $null
                    $port = 443
                    $mode = "serve"
                    for ($i = 1; $i -lt $RemainingArguments.Count; $i++) {
                        switch ($RemainingArguments[$i]) {
                            "--target" { $i++; $targetUrl = $RemainingArguments[$i] }
                            "--port" { $i++; $port = [int]$RemainingArguments[$i] }
                            "--mode" { $i++; $mode = $RemainingArguments[$i] }
                            default { throw "Unknown tailnet add option '$($RemainingArguments[$i])'." }
                        }
                    }
                    if ([string]::IsNullOrWhiteSpace($targetUrl)) { throw "tailnet add requires --target <url>." }
                    Add-VibeboxTailnetService -Name $target -Service $service -Target $targetUrl -Port $port -Mode $mode
                    exit 0
                }
                "remove" {
                    if ($RemainingArguments.Count -ne 1) { throw "tailnet remove requires <name>." }
                    Remove-VibeboxTailnetService -Name $target -Service $RemainingArguments[0]
                    exit 0
                }
                default { throw "Unknown tailnet operation '$Subcommand'." }
            }
        }
        "conformance" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            $conformance = Join-Path (Get-VibeboxPath -Name Vm) "conformance\run.ps1"
            & $conformance -Name $target -Json:$Json
            exit $LASTEXITCODE
        }
        default {
            Show-VibeboxUsage
            exit $ExitUsage
        }
    }
} catch {
    $message = $_.Exception.Message
    [Console]::Error.WriteLine("vibebox: $message")
    if ($message -match "requires -Confirm|requires [a-z]|Unknown argument|Unknown [a-z]|must be") { exit $ExitUsage }
    if ($message -match "preflight") { exit $ExitPreflight }
    if ($message -match "not found|not managed|does not exist") { exit $ExitMissing }
    if ($message -match "validation|drift|schema") { exit $ExitValidation }
    exit $ExitOperation
}
