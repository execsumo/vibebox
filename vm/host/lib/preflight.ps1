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

function Test-VibeboxAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-VibeboxPreflightResults {
    param([Parameter(Mandatory)]$Config)

    $results = [System.Collections.Generic.List[object]]::new()
    $null = $results.Add([pscustomobject]@{
        Id = "powershell"
        Ok = ($PSVersionTable.PSVersion.Major -ge 7)
        Detail = "PowerShell $($PSVersionTable.PSVersion)"
    })
    $null = $results.Add([pscustomobject]@{
        Id = "administrator"
        Ok = (Test-VibeboxAdministrator)
        Detail = "An elevated shell is required for Hyper-V configuration."
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
    $null = $results.Add([pscustomobject]@{
        Id = "multipass"
        Ok = ($null -ne (Get-VibeboxMultipassCommand))
        Detail = "Canonical Multipass is the supported lifecycle adapter."
    })

    $hyperv = $false
    $hypervDetail = "Hyper-V cmdlets were not found."
    $getVmHost = Get-Command Get-VMHost -ErrorAction SilentlyContinue
    if ($null -ne $getVmHost) {
        try {
            $hostInfo = Get-VMHost -ErrorAction Stop
            $hyperv = $true
            $hypervDetail = "Hyper-V host: $($hostInfo.ComputerName)"
        } catch {
            $hypervDetail = "Hyper-V is present but unavailable: $($_.Exception.Message)"
        }
    }
    $null = $results.Add([pscustomobject]@{ Id = "hyperv"; Ok = $hyperv; Detail = $hypervDetail })

    $feature = $null
    $getFeature = Get-Command Get-WindowsOptionalFeature -ErrorAction SilentlyContinue
    if ($null -ne $getFeature) {
        try {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -ErrorAction Stop
        } catch {
            $feature = $null
        }
    }
    $featureOk = $null -ne $feature -and $feature.State -eq "Enabled"
    $null = $results.Add([pscustomobject]@{
        Id = "hyperv-feature"
        Ok = $featureOk
        Detail = if ($null -ne $feature) { "Microsoft-Hyper-V state: $($feature.State)" } else { "Could not query Microsoft-Hyper-V." }
    })

    $system = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $totalMemory = if ($null -ne $system) { [uint64]$system.TotalPhysicalMemory } else { [uint64]0 }
    $freeMemory = if ($null -ne $os) { [uint64]$os.FreePhysicalMemory * 1KB } else { [uint64]0 }
    $requestedMemory = Get-VibeboxBytesFromSize -Value $Config.Values.VM_MEMORY
    # Reserve room for the still-running legacy container, WSL2, and the host.
    $concurrentReserve = 4GB
    $memoryOk = $freeMemory -ge ($requestedMemory + $concurrentReserve)
    $null = $results.Add([pscustomobject]@{
        Id = "resource-headroom-memory"
        Ok = $memoryOk
        Detail = "Free physical memory: $([math]::Round($freeMemory / 1GB, 2)) GB; requested VM plus concurrency reserve: $([math]::Round(($requestedMemory + $concurrentReserve) / 1GB, 2)) GB."
    })

    $root = Get-VibeboxRepoRoot
    $drive = (Get-Item -LiteralPath $root).PSDrive
    $freeDisk = if ($null -ne $drive) { [uint64]$drive.Free } else { [uint64]0 }
    $requestedDisk = Get-VibeboxBytesFromSize -Value $Config.Values.VM_DISK
    $diskOk = $freeDisk -ge $requestedDisk
    $null = $results.Add([pscustomobject]@{
        Id = "resource-headroom-disk"
        Ok = $diskOk
        Detail = "Free host disk: $([math]::Round($freeDisk / 1GB, 2)) GB; configured VM disk: $([math]::Round($requestedDisk / 1GB, 2)) GB."
    })

    $null = $results.Add([pscustomobject]@{
        Id = "nested-virtualization-policy"
        Ok = $true
        Detail = "Nested virtualization requested: $($Config.Values.VM_NESTED_VIRT)."
    })

    $backupPath = [Environment]::ExpandEnvironmentVariables($Config.Values.BACKUP_DEST)
    $backupQualifier = Split-Path -Path $backupPath -Qualifier
    $backupDrive = if ($backupQualifier) { $backupQualifier.TrimEnd(":") } else { "" }
    $vmDiskDrive = "C"
    $backupDiskNumber = $null
    $vmDiskNumber = $null
    try {
        if ($backupDrive) {
            $backupDiskNumber = (Get-Partition -DriveLetter $backupDrive -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
        }
        $vmDiskNumber = (Get-Partition -DriveLetter $vmDiskDrive -ErrorAction Stop | Get-Disk -ErrorAction Stop).Number
    } catch {
        # The warning is useful even in a non-elevated doctor invocation. A
        # later elevated run can replace unknown with a verified answer.
        $backupDiskNumber = $null
        $vmDiskNumber = $null
    }
    $samePhysicalDrive = $null -ne $backupDiskNumber -and $backupDiskNumber -eq $vmDiskNumber
    $physicalDriveKnown = $null -ne $backupDiskNumber -and $null -ne $vmDiskNumber
    $null = $results.Add([pscustomobject]@{
        Id = "backup-drive"
        Ok = $true
        Warning = [bool]($samePhysicalDrive -or -not $physicalDriveKnown)
        Detail = if ($samePhysicalDrive) {
            "BACKUP_DEST resolves to $backupPath on the same physical disk as the default VM disk."
        } elseif (-not $physicalDriveKnown) {
            "Could not verify the physical disk for BACKUP_DEST=$backupPath; run doctor elevated."
        } else {
            "BACKUP_DEST resolves to $backupPath on a different physical disk from the default VM disk."
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
        -not $_.Ok -and (-not ($AllowMissingMultipass -and $_.Id -eq "multipass"))
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
