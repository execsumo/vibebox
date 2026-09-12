Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lifecycle.ps1")

function Get-VibeboxMultipassVersion {
    if ($null -eq (Get-VibeboxMultipassCommand)) { return "" }
    $result = Invoke-VibeboxMultipass -Arguments @("version") -AllowFailure
    if ($result.ExitCode -ne 0) { return "" }
    return (($result.Output | Select-Object -First 1) -as [string]).Trim()
}

function ConvertTo-VibeboxMemoryGb {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    if ($Value -match '^\s*([\d.]+)\s*([KMGT]?i?B?)\s*$') {
        $number = [double]$Matches[1]
        $unit = $Matches[2].ToUpperInvariant()
        $multiplier = switch -Regex ($unit) {
            "^$" { 1 }
            "^K" { 1KB }
            "^M" { 1MB }
            "^G" { 1GB }
            "^T" { 1TB }
        }
        return [math]::Round(($number * $multiplier) / 1GB, 2)
    }
    return $null
}

function Get-VibeboxLiveResources {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Info)

    $cpu = $null
    $memoryGb = $null
    $diskGb = $null
    $vm = Get-VibeboxHyperVInstance -Name $Name
    if ($null -ne $vm) {
        $cpu = [int]$vm.ProcessorCount
        $memoryGb = [math]::Round(([double]$vm.MemoryStartup / 1GB), 2)
        $drive = @(Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | Select-Object -First 1)
        if ($drive.Count -gt 0 -and $drive[0].Path) {
            $vhd = Get-VHD -Path $drive[0].Path -ErrorAction SilentlyContinue
            if ($null -ne $vhd) {
                $diskGb = [math]::Round(([double]$vhd.Size / 1GB), 2)
            }
        }
    }
    if ($null -eq $diskGb -and $Info.DiskTotal) {
        $diskGb = ConvertTo-VibeboxMemoryGb -Value $Info.DiskTotal
    }
    return [pscustomobject]@{ Cpus = $cpu; MemoryGb = $memoryGb; DiskGb = $diskGb }
}

function Get-VibeboxGuestStatus {
    param([Parameter(Mandatory)][string]$Name)

    $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "/opt/vibebox/status.sh") -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    try {
        return (($result.Output -join [Environment]::NewLine) | ConvertFrom-Json)
    } catch {
        Write-Warning "Guest status was not valid JSON: $($_.Exception.Message)"
        return $null
    }
}

function Get-VibeboxStatus {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Name
    )

    $info = Get-VibeboxInstanceInfo -Name $Name
    $state = if ($null -eq $info) { "unknown" } elseif ($info.State -eq "RUNNING") { "running" } else { "stopped" }
    if ($null -ne $info -and $info.IPv4 -and $state -eq "running") {
        Update-VibeboxSshAlias -Name $Name -User $Config.Values.GUEST_USER -Address $info.IPv4 | Out-Null
    }
    $live = if ($null -ne $info) {
        Get-VibeboxLiveResources -Name $Name -Info $info
    } else {
        [pscustomobject]@{ Cpus = $null; MemoryGb = $null; DiskGb = $null }
    }
    $guest = if ($state -eq "running") { Get-VibeboxGuestStatus -Name $Name } else { $null }
    $mounts = @()
    if ($null -ne $info) {
        $mounts = @($info.Mounts | Where-Object { $_ })
    }
    $mountChecks = [System.Collections.Generic.List[object]]::new()
    $null = $mountChecks.Add([pscustomobject]@{
        id = "no-mounts"
        ok = ($mounts.Count -eq 0)
        detail = "$($mounts.Count) Multipass mount(s) configured"
    })

    $drift = [System.Collections.Generic.List[string]]::new()
    if ($null -ne $live.Cpus -and [int]$live.Cpus -ne [int]$Config.Values.VM_CPUS) {
        $null = $drift.Add("CPU configured as $($Config.Values.VM_CPUS), live VM has $($live.Cpus)")
    }
    $wantedMemory = ConvertTo-VibeboxMemoryGb -Value $Config.Values.VM_MEMORY
    if ($null -ne $live.MemoryGb -and $null -ne $wantedMemory -and
        [math]::Abs([double]$live.MemoryGb - [double]$wantedMemory) -gt 0.01) {
        $null = $drift.Add("memory configured as $wantedMemory GB, live VM has $($live.MemoryGb) GB")
    }
    $wantedDisk = ConvertTo-VibeboxMemoryGb -Value $Config.Values.VM_DISK
    if ($null -ne $live.DiskGb -and $null -ne $wantedDisk -and [double]$live.DiskGb -ne [double]$wantedDisk) {
        if ([double]$live.DiskGb -lt [double]$wantedDisk) {
            $null = $drift.Add("disk configured as $wantedDisk GB, live VHDX is $($live.DiskGb) GB (grow-only)")
        } else {
            $null = $drift.Add("disk configured as $wantedDisk GB, live VHDX is $($live.DiskGb) GB (shrink refused)")
        }
    }
    $marker = Get-VibeboxInstanceMarker -Name $Name
    if ($null -ne $marker -and [string]$marker.ubuntuRelease -ne [string]$Config.Values.UBUNTU_RELEASE) {
        $null = $drift.Add("Ubuntu release was created as $($marker.ubuntuRelease), configuration requests $($Config.Values.UBUNTU_RELEASE)")
    }
    if ($null -ne $marker -and [string]$marker.name -ne [string]$Config.Values.VM_NAME) {
        $null = $drift.Add("VM name was created as $($marker.name), configuration requests $($Config.Values.VM_NAME) (rebuild required)")
    }
    if ($null -ne $marker -and [string]$marker.guestUser -ne [string]$Config.Values.GUEST_USER) {
        $null = $drift.Add("guest user was created as $($marker.guestUser), configuration requests $($Config.Values.GUEST_USER) (rebuild required)")
    }

    $sshReachable = $false
    if ($null -ne $info -and $info.IPv4) {
        $sshReachable = Test-NetConnection -ComputerName $info.IPv4 -Port 22 -InformationLevel Quiet -WarningAction SilentlyContinue
    }
    $hypervAvailable = $null -ne (Get-Command Get-VM -ErrorAction SilentlyContinue)
    $consoleAvailable = $null -ne (Get-Command vmconnect.exe -ErrorAction SilentlyContinue)
    $requiredMissing = @("guest-unreachable")
    $tailnetDrift = @()
    $services = [object[]]@()
    if ($null -ne $guest) {
        $requiredMissing = @($guest.tools.required.missing)
        $tailnetDrift = @($guest.tailnet.drift)
        $services = @($guest.services)
    }
    $coreUnits = @("ssh.service", "tailscaled.service", "docker.service", "systemd-timesyncd.service", "vibebox-grow-disk.service", "vibebox-tailnet.service")
    $failedCoreServices = @($services | Where-Object { $_.unit -in $coreUnits -and -not $_.active })
    $clockOk = $null -ne $guest -and $guest.clock.synced -and
        ($null -eq $guest.clock.offsetSec -or [double]$guest.clock.offsetSec -le 2)
    $tailscaleOk = $null -ne $guest -and $guest.net.tailscale.state -eq "Running"
    $checks = @($mountChecks.ToArray()) + @(
        [pscustomobject]@{ id = "config-drift"; ok = ($drift.Count -eq 0); detail = if ($drift.Count) { $drift -join "; " } else { "no configuration drift" } }
        [pscustomobject]@{ id = "ssh"; ok = $sshReachable; detail = if ($sshReachable) { "SSH port is reachable" } else { "SSH port is not reachable" } }
        [pscustomobject]@{ id = "required-tools"; ok = ($requiredMissing.Count -eq 0); detail = if ($requiredMissing.Count) { "missing: $($requiredMissing -join ', ')" } else { "all required tools pass version checks" } }
        [pscustomobject]@{ id = "tailnet-registry"; ok = ($tailnetDrift.Count -eq 0); detail = if ($tailnetDrift.Count) { "drift: $($tailnetDrift -join ', ')" } else { "tailnet registry matches live Services" } }
        [pscustomobject]@{ id = "tailscale"; ok = $tailscaleOk; detail = if ($tailscaleOk) { "Tailscale node is running" } else { "Tailscale node is not enrolled or running" } }
        [pscustomobject]@{ id = "core-services"; ok = ($failedCoreServices.Count -eq 0); detail = if ($failedCoreServices.Count) { "failed: $(($failedCoreServices | ForEach-Object { $_.unit }) -join ', ')" } else { "core services are active" } }
        [pscustomobject]@{ id = "clock"; ok = $clockOk; detail = if ($clockOk) { "clock is synchronized" } else { "clock is not synchronized within tolerance" } }
    )
    $ok = ($state -eq "running") -and ($drift.Count -eq 0) -and ($mounts.Count -eq 0) -and
        $sshReachable -and ($requiredMissing.Count -eq 0) -and $tailscaleOk -and ($tailnetDrift.Count -eq 0) -and
        ($failedCoreServices.Count -eq 0) -and $clockOk

    return [pscustomobject]@{
        name = $Name
        state = $state
        checkedAt = (Get-Date).ToUniversalTime().ToString("o")
        host = [pscustomobject]@{
            multipassVersion = Get-VibeboxMultipassVersion
            hyperV = $hypervAvailable
            consoleAvailable = $consoleAvailable
        }
        vm = [pscustomobject]@{
            cpus = $live.Cpus
            memoryGb = $live.MemoryGb
            diskGb = $live.DiskGb
            diskUsedPct = if ($null -ne $guest) { $guest.diskUsedPct } else { $null }
            uptimeSec = if ($null -ne $guest) { $guest.uptimeSec } else { $null }
            mounts = $mounts
        }
        net = [pscustomobject]@{
            localIp = if ($null -ne $info) { $info.IPv4 } else { "" }
            sshAlias = $Name
            sshReachable = $sshReachable
            tailscale = if ($null -ne $guest) { $guest.net.tailscale } else { [pscustomobject]@{ state = "Unknown"; name = ""; ip = "" } }
        }
        tailnet = if ($null -ne $guest) { $guest.tailnet } else { [pscustomobject]@{ node = $Name; services = @(); drift = @() } }
        clock = if ($null -ne $guest) { $guest.clock } else { [pscustomobject]@{ offsetSec = $null; synced = $false } }
        gpu = "none"
        services = $services
        tools = if ($null -ne $guest) { $guest.tools } else { [pscustomobject]@{ required = [pscustomobject]@{ ok = 0; missing = @("guest-unreachable") }; optional = [pscustomobject]@{ ok = 0; missing = @() } } }
        checks = $checks
        configDrift = @($drift.ToArray())
        ok = $ok
    }
}
