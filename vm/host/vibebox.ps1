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
. (Join-Path $lib "tailnet.ps1")

$ExitUsage = 1
$ExitPreflight = 2
$ExitMissing = 3
$ExitValidation = 5
$ExitOperation = $ExitValidation - $ExitUsage

function Show-VibeboxUsage {
    @"
vibebox doctor
vibebox config <show|diff|apply> [-Restart]
vibebox create [-Name] [-Cpus] [-Memory] [-Disk] [-Release]
vibebox start|stop|restart [-Name]
vibebox destroy [-Name] -Confirm
vibebox status [-Name] [-Json]
vibebox ssh [-Name] [-- <command>]
vibebox console [-Name]
vibebox provision|update [-Name]
vibebox rebuild [-Name] -Confirm
vibebox backup [-Name] [-Label <label>]
vibebox restore [-Name] -Archive <path> [-DryRun]
vibebox conformance [-Name] [-Json]
vibebox enroll <tailscale|github|hermes>
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

function Invoke-VibeboxConfigApply {
    param([Parameter(Mandatory)]$Config)

    $target = Resolve-VibeboxExistingName -Config $Config
    Assert-VibeboxManagedTarget -Name $target
    $info = Get-VibeboxInstanceInfo -Name $target
    if ($null -eq $info) { throw "Managed instance '$target' was not found." }
    $marker = Get-VibeboxInstanceMarker -Name $target
    if ($null -ne $marker) {
        if ([string]$marker.ubuntuRelease -ne [string]$Config.Values.UBUNTU_RELEASE) {
            throw "UBUNTU_RELEASE is create-time-only. Use vibebox rebuild to change it."
        }
        if ([string]$marker.guestUser -ne [string]$Config.Values.GUEST_USER) {
            throw "GUEST_USER is create-time-only. Use vibebox rebuild to change it."
        }
        if ($marker.name -ne $Config.Values.VM_NAME -and [string]::IsNullOrWhiteSpace($Name)) {
            throw "VM_NAME is create-time-only. Use vibebox rebuild to rename the instance."
        }
    }
    $running = $info.State -eq "RUNNING"
    if ($running -and -not $Restart) {
        throw "Configuration apply requires the VM to be stopped. Stop it first, or use -Restart."
    }
    if ($running) {
        # Reconciliation requires the Hyper-V VM to be Off even when the
        # configured ordinary stop action is Save.
        Invoke-VibeboxMultipass -Arguments @("stop", "--type", "shutdown", $target) | Out-Null
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            $stopped = Get-VibeboxInstanceInfo -Name $target
            if ($null -ne $stopped -and $stopped.State -eq "STOPPED") { break }
            Start-Sleep -Seconds 1
        }
        if ($null -eq $stopped -or $stopped.State -ne "STOPPED") {
            throw "VM '$target' did not reach the stopped state for configuration apply."
        }
    }

    $vm = Get-VibeboxHyperVInstance -Name $target
    if ($null -ne $vm) {
        $desiredMemory = ConvertTo-VibeboxBytes -Value $Config.Values.VM_MEMORY -Name "VM_MEMORY"
        $currentMemory = [uint64]$vm.MemoryStartup
        if ($currentMemory -ne $desiredMemory) {
            Set-VMMemory -VM $vm -StartupBytes $desiredMemory
        }
        if ([int]$vm.ProcessorCount -ne [int]$Config.Values.VM_CPUS) {
            Set-VMProcessor -VM $vm -Count ([int]$Config.Values.VM_CPUS)
        }
    } else {
        Write-Warning "Hyper-V VM properties are unavailable; CPU and memory cannot be reconciled safely."
    }

    $desiredDisk = ConvertTo-VibeboxBytes -Value $Config.Values.VM_DISK -Name "VM_DISK"
    Resize-VibeboxHyperVDisk -Name $target -TargetBytes $desiredDisk | Out-Null
    Set-VibeboxHyperVPolicy -Name $target -Config $Config | Out-Null
    if ($running) {
        Start-VibeboxInstance -Name $target -Config $Config | Out-Null
    }
    Write-Host "Host configuration applied to '$target'. Run 'vibebox provision' for guest policy/tool changes."
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
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { throw "config requires show, diff, or apply." }
            $config = Get-VibeboxConfig -CreateIfMissing
            switch ($Subcommand.ToLowerInvariant()) {
                "show" {
                    Get-VibeboxConfigDisplay -Config $config | Format-Table -AutoSize
                    exit 0
                }
                "diff" {
                    $target = Resolve-VibeboxExistingName -Config $config
                    $status = if (Test-VibeboxManagedInstance -Name $target) {
                        Get-VibeboxStatus -Config $config -Name $target
                    } else { $null }
                    if ($null -eq $status) {
                        Write-Host "No managed VM exists for '$target'. All instance settings are pending create."
                    } else {
                        $status.configDrift | ForEach-Object { Write-Host "drift: $_" }
                        if ($status.configDrift.Count -eq 0) { Write-Host "No configuration drift detected." }
                    }
                    exit 0
                }
                "apply" {
                    Invoke-VibeboxConfigApply -Config $config
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
            Ensure-VibeboxRescuePassword -Name $config.Values.VM_NAME | Out-Null
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
                    [Console]::Error.WriteLine("WARNING: configuration drift detected. Run 'vibebox config apply' (or stop the VM first).")
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
        "update" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            Invoke-VibeboxMultipass -Arguments @("exec", $target, "--", "sudo", "/opt/vibebox/provision/30-tools", "/etc/vibebox/vibebox.env") | Out-Null
            exit 0
        }
        "rebuild" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxConfirmation -Action "Rebuild" -Target $target
            Remove-VibeboxInstance -Name $target
            New-VibeboxInstance -Config $config | Out-Null
            Ensure-VibeboxRescuePassword -Name $config.Values.VM_NAME | Out-Null
            exit 0
        }
        "backup" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Invoke-VibeboxBackup -Config $config -Name $target -Label $Label | Out-Null
            exit 0
        }
        "restore" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            if ([string]::IsNullOrWhiteSpace($Archive)) { throw "restore requires -Archive <path>." }
            Invoke-VibeboxRestore -Config $config -Name $target -Archive $Archive -DryRun:$DryRun
            exit 0
        }
        "enroll" {
            $config = Get-VibeboxConfig -CreateIfMissing
            $target = Resolve-VibeboxExistingName -Config $config
            Assert-VibeboxManagedTarget -Name $target
            if ([string]::IsNullOrWhiteSpace($Subcommand)) { throw "enroll requires tailscale, github, or hermes." }
            Invoke-VibeboxEnroll -Name $target -User $config.Values.GUEST_USER -Provider $Subcommand
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
