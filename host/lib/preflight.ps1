Set-StrictMode -Version Latest

function Get-VibeboxBytesFromSize {
    param([Parameter(Mandatory)][string]$Value)
    $match = [regex]::Match($Value, '^\s*(\d+(?:\.\d+)?)\s*(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB)\s*$')
    if (-not $match.Success) {
        throw "Invalid size '$Value'."
    }
    $multiplier = switch -Regex ($match.Groups[2].Value.ToUpperInvariant()) {
        "^B$" { 1 }
        "^K(B|IB)?$" { 1KB }
        "^M(B|IB)?$" { 1MB }
        "^G(B|IB)?$" { 1GB }
        "^T(B|IB)?$" { 1TB }
    }
    return [uint64][math]::Round(([double]$match.Groups[1].Value) * $multiplier)
}

# Multipass drives Hyper-V through its own daemon, which runs as a LocalSystem
# service. Nothing vibebox does needs an elevated client, so doctor does not
# ask for one. The checks below are exactly the conditions that can actually
# stop a create/provision/destroy cycle.
function Get-VibeboxPreflightResults {
    param([Parameter(Mandatory)]$Config)

    $results = [System.Collections.Generic.List[object]]::new()
    $null = $results.Add([pscustomobject]@{
        Id = "powershell"
        Ok = ($PSVersionTable.PSVersion.Major -ge 7)
        Detail = "PowerShell $($PSVersionTable.PSVersion)"
    })
    $null = $results.Add([pscustomobject]@{
        Id = "git"
        Ok = ($null -ne (Get-Command git -ErrorAction SilentlyContinue))
        Detail = "git is required for repository and evidence operations."
    })
    $null = $results.Add([pscustomobject]@{
        Id = "ssh"
        Ok = ($null -ne (Get-Command ssh -ErrorAction SilentlyContinue))
        Detail = "OpenSSH client is required for the managed alias."
    })

    $multipassCmd = Get-VibeboxMultipassCommand
    $null = $results.Add([pscustomobject]@{
        Id = "multipass"
        Ok = ($null -ne $multipassCmd)
        Detail = "Canonical Multipass is the supported lifecycle adapter."
    })

    # The daemon can be listening and still be wedged; a hung multipassd looks
    # exactly like a healthy one from the service list. Prove it answers.
    $daemonOk = $false
    $daemonDetail = "Multipass client was not found; daemon not probed."
    if ($null -ne $multipassCmd) {
        try {
            $probe = Start-Job -ScriptBlock {
                param($exe)
                & $exe version 2>&1 | Out-String
            } -ArgumentList $multipassCmd
            if (Wait-Job -Job $probe -Timeout 20) {
                $output = (Receive-Job -Job $probe) -join "`n"
                if ($output -match 'multipassd\s+(\S+)') {
                    $daemonOk = $true
                    $daemonDetail = "multipassd responded: $($Matches[1])"
                } else {
                    $daemonDetail = "multipassd gave an unexpected reply: $($output.Trim())"
                }
            } else {
                $daemonDetail = "multipassd did not answer within 20s. It is wedged; restart the Multipass service from an elevated shell: Restart-Service Multipass -Force (force-kill multipassd.exe first if the stop hangs)."
            }
            Remove-Job -Job $probe -Force -ErrorAction SilentlyContinue
        } catch {
            $daemonDetail = "Could not probe multipassd: $($_.Exception.Message)"
        }
    }
    $null = $results.Add([pscustomobject]@{ Id = "multipass-daemon"; Ok = $daemonOk; Detail = $daemonDetail })

    # A stale <name>.mshome.net entry hangs create and start on "Starting"
    # indefinitely. Catch it here in a second instead of after a 300s timeout.
    $hostnet = Get-VibeboxHostNetworkHealth -Name $Config.Values.VM_NAME
    $null = $results.Add([pscustomobject]@{ Id = "hostnet-dns"; Ok = $hostnet.Ok; Detail = $hostnet.Detail })

    # Hyper-V availability is proven by its services running, which any user can
    # read. Get-VM / Get-WindowsOptionalFeature need elevation and would only
    # re-answer the same question.
    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    $vmcompute = Get-Service -Name vmcompute -ErrorAction SilentlyContinue
    $hypervOk = ($null -ne $vmms -and $vmms.Status -eq 'Running') -and
                ($null -ne $vmcompute -and $vmcompute.Status -eq 'Running')
    $null = $results.Add([pscustomobject]@{
        Id = "hyperv"
        Ok = $hypervOk
        Detail = if ($hypervOk) {
            "Hyper-V services vmms and vmcompute are running."
        } else {
            "Hyper-V services are not both running (vmms=$($vmms.Status), vmcompute=$($vmcompute.Status)). Enable Hyper-V and reboot."
        }
    })

    # Headroom is advisory. Hyper-V dynamic memory starts the guest at its
    # startup size and grows under pressure, so refusing to launch because the
    # maximum is not free today would be wrong.
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $freeMemory = if ($null -ne $os) { [uint64]$os.FreePhysicalMemory * 1KB } else { [uint64]0 }
    $startupMemory = Get-VibeboxBytesFromSize -Value $Config.Values.VM_MEMORY
    $memoryTight = $freeMemory -lt $startupMemory
    $null = $results.Add([pscustomobject]@{
        Id = "resource-headroom-memory"
        Ok = $true
        Warning = $memoryTight
        Detail = "Free physical memory: $([math]::Round($freeMemory / 1GB, 2)) GB; VM memory: $([math]::Round($startupMemory / 1GB, 2)) GB."
    })

    # Multipass stores instance disks on the system drive, not the repo drive.
    # The disk is dynamically allocated, so this compares against real free
    # space as a warning rather than a precondition.
    $systemDrive = ($env:SystemDrive).TrimEnd(":")
    $freeDisk = [uint64]0
    try {
        $psDrive = Get-PSDrive -Name $systemDrive -ErrorAction Stop
        $freeDisk = [uint64]$psDrive.Free
    } catch { $freeDisk = [uint64]0 }
    $requestedDisk = Get-VibeboxBytesFromSize -Value $Config.Values.VM_DISK
    $diskTight = $freeDisk -lt $requestedDisk
    $null = $results.Add([pscustomobject]@{
        Id = "resource-headroom-disk"
        Ok = $true
        Warning = $diskTight
        Detail = "Free space on ${systemDrive}: $([math]::Round($freeDisk / 1GB, 2)) GB; configured VM disk (dynamically allocated): $([math]::Round($requestedDisk / 1GB, 2)) GB."
    })

    $backupPath = [Environment]::ExpandEnvironmentVariables($Config.Values.BACKUP_DEST)
    $backupQualifier = Split-Path -Path $backupPath -Qualifier
    $backupDrive = if ($backupQualifier) { $backupQualifier.TrimEnd(":") } else { "" }
    $sameLogicalDrive = $backupDrive -and ($backupDrive -ieq $systemDrive)
    $null = $results.Add([pscustomobject]@{
        Id = "backup-drive"
        Ok = $true
        Warning = [bool]$sameLogicalDrive
        Detail = if ($sameLogicalDrive) {
            "BACKUP_DEST ($backupPath) is on ${systemDrive}:, the same drive as the VM disk. A drive failure would take both."
        } else {
            "BACKUP_DEST resolves to $backupPath, separate from the VM disk on ${systemDrive}:."
        }
    })

    return @($results)
}

function Assert-VibeboxPreflight {
    param(
        [Parameter(Mandatory)]$Config,
        [switch]$AllowMissingMultipass
    )

    $results = Get-VibeboxPreflightResults -Config $Config
    $failures = @($results | Where-Object {
        -not $_.Ok -and (-not ($AllowMissingMultipass -and $_.Id -in @("multipass", "multipass-daemon")))
    })
    foreach ($result in $results) {
        $warning = $result.PSObject.Properties.Name -contains "Warning" -and $result.Warning
        if ($warning) {
            Write-Warning "$($result.Id) - $($result.Detail)"
        } elseif (-not $result.Ok) {
            [Console]::Error.WriteLine("not ok $($result.Id) - $($result.Detail)")
        } else {
            Write-Verbose "ok $($result.Id) - $($result.Detail)"
        }
    }
    if ($failures.Count -gt 0) {
        throw "Host preflight failed: $($failures.Id -join ', ')"
    }
}
