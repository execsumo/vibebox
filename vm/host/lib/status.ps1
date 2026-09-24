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

    # Read from Multipass rather than Hyper-V: it needs no elevation, and it
    # reports the same units the configuration is written in.
    $cpu = $null
    if ($null -ne $Info -and $null -ne $Info.Raw) {
        $rawCpu = Get-VibeboxJsonProperty -Object $Info.Raw -Name "cpu_count"
        if ($null -ne $rawCpu -and "$rawCpu" -ne "") { $cpu = [int]$rawCpu }
    }
    $memoryGb = if ($null -ne $Info) { ConvertTo-VibeboxMemoryGb -Value $Info.MemoryTotal } else { $null }
    $diskGb = if ($null -ne $Info) { ConvertTo-VibeboxMemoryGb -Value $Info.DiskTotal } else { $null }
    return [pscustomobject]@{
        Cpus = $cpu
        MemoryGb = $memoryGb
        DiskGb = $diskGb
    }
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
        [pscustomobject]@{
            Cpus = $null
            MemoryGb = $null
            DiskGb = $null
        }
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

    # Only create-time settings can drift now. Resource sizes are fixed at
    # create and reported straight from Multipass, so there is nothing to
    # reconcile and no unit mismatch to misreport.
    $drift = [System.Collections.Generic.List[string]]::new()
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

    # A half-finished create looks like a running VM, but nothing was
    # provisioned into it. Say so instead of letting the tool checks imply it.
    $creationComplete = $null -ne $marker -and [string]$marker.state -eq "ready"
    $hostnet = Get-VibeboxHostNetworkHealth -Name $Name

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
        [pscustomobject]@{ id = "creation"; ok = $creationComplete; detail = if ($creationComplete) { "creation completed" } else { "creation did not finish; run vibebox create to resume it" } }
        [pscustomobject]@{ id = "hostnet-dns"; ok = $hostnet.Ok; detail = $hostnet.Detail }
        [pscustomobject]@{ id = "config-drift"; ok = ($drift.Count -eq 0); detail = if ($drift.Count) { $drift -join "; " } else { "no configuration drift" } }
        [pscustomobject]@{ id = "ssh"; ok = $sshReachable; detail = if ($sshReachable) { "SSH port is reachable" } else { "SSH port is not reachable" } }
        [pscustomobject]@{ id = "required-tools"; ok = ($requiredMissing.Count -eq 0); detail = if ($requiredMissing.Count) { "missing: $($requiredMissing -join ', ')" } else { "all required tools pass version checks" } }
        [pscustomobject]@{ id = "tailnet-registry"; ok = ($tailnetDrift.Count -eq 0); detail = if ($tailnetDrift.Count) { "drift: $($tailnetDrift -join ', ')" } else { "tailnet registry matches live Services" } }
        [pscustomobject]@{ id = "tailscale"; ok = $tailscaleOk; detail = if ($tailscaleOk) { "Tailscale node is running" } else { "Tailscale backend state: $(if ($null -ne $guest) { $guest.net.tailscale.state } else { 'unknown' }). Run vibebox enroll tailscale." } }
        [pscustomobject]@{ id = "core-services"; ok = ($failedCoreServices.Count -eq 0); detail = if ($failedCoreServices.Count) { "failed: $(($failedCoreServices | ForEach-Object { $_.unit }) -join ', ')" } else { "core services are active" } }
        [pscustomobject]@{ id = "clock"; ok = $clockOk; detail = if ($clockOk) { "clock is synchronized" } else { "clock is not synchronized within tolerance" } }
    )
    $ok = ($state -eq "running") -and $creationComplete -and $hostnet.Ok -and ($drift.Count -eq 0) -and ($mounts.Count -eq 0) -and
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
