Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "preflight.ps1")
. (Join-Path $PSScriptRoot "sshconfig.ps1")

function Invoke-VibeboxMultipass {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [switch]$AllowFailure
    )

    $command = Get-Command multipass -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        throw "Multipass is not installed. Install Canonical Multipass before using the VM lifecycle."
    }
    $output = & $command.Source @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "multipass $($Arguments -join ' ') failed with exit code $exitCode`n$($output -join [Environment]::NewLine)"
    }
    return [pscustomobject]@{ Output = @($output); ExitCode = $exitCode }
}

function Get-VibeboxStateDirectory {
    $path = Get-VibeboxPath -Name State
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Get-VibeboxInstanceMarkerPath {
    param([Parameter(Mandatory)][string]$Name)
    $directory = Join-Path (Get-VibeboxStateDirectory) "instances"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory "$Name.json"
}

function Test-VibeboxManagedInstance {
    param([Parameter(Mandatory)][string]$Name)
    return Test-Path -LiteralPath (Get-VibeboxInstanceMarkerPath -Name $Name) -PathType Leaf
}

function Get-VibeboxInstanceMarker {
    param([Parameter(Mandatory)][string]$Name)
    $path = Get-VibeboxInstanceMarkerPath -Name $Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Save-VibeboxInstanceMarker {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ImageHash,
        [ValidateSet("creating", "ready")][string]$State = "ready"
    )
    $marker = [ordered]@{
        name = $Name
        createdBy = "vibebox"
        state = $State
        createdAt = (Get-Date).ToUniversalTime().ToString("o")
        ubuntuRelease = $Config.Values.UBUNTU_RELEASE
        guestUser = $Config.Values.GUEST_USER
        imageHash = $ImageHash
    }
    $hyperv = Get-VibeboxHyperVInstance -Name $Name
    if ($null -ne $hyperv) {
        $marker.hyperVId = [string]$hyperv.Id
    }
    $marker | ConvertTo-Json | Set-Content -LiteralPath (Get-VibeboxInstanceMarkerPath -Name $Name) -Encoding utf8
}

function Get-VibeboxInstanceInfo {
    param([Parameter(Mandatory)][string]$Name)

    if ($null -eq (Get-Command multipass -ErrorAction SilentlyContinue)) {
        return $null
    }
    $result = Invoke-VibeboxMultipass -Arguments @("info", $Name, "--format", "json") -AllowFailure
    if ($result.ExitCode -ne 0) {
        return $null
    }
    try {
        $json = ($result.Output -join [Environment]::NewLine) | ConvertFrom-Json
    } catch {
        throw "Multipass returned invalid JSON for instance '$Name': $($_.Exception.Message)"
    }
    $property = $json.info.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($null -eq $property) {
        return $null
    }
    $info = $property.Value
    $ip = @($info.ipv4 | Where-Object { $_ -and $_ -notmatch '^127\.' }) | Select-Object -First 1
    $diskTotal = $null
    $diskUsed = $null
    if ($null -ne $info.disks) {
        $disk = @($info.disks) | Select-Object -First 1
        if ($null -ne $disk) {
            $diskTotal = [string]$disk.total
            $diskUsed = [string]$disk.used
        }
    }
    $mounts = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $info.mounts) {
        foreach ($mount in $info.mounts.PSObject.Properties) {
            $null = $mounts.Add([pscustomobject]@{
                source = [string]$mount.Name
                target = [string]$mount.Value
            })
        }
    }
    return [pscustomobject]@{
        Name = $Name
        State = [string]$info.state
        IPv4 = [string]$ip
        ImageHash = [string]$info.image_hash
        Release = [string]$info.release
        Load = [string]$info.load
        MemoryTotal = [string]$info.memory.total
        MemoryUsed = [string]$info.memory.used
        DiskTotal = $diskTotal
        DiskUsed = $diskUsed
        Mounts = @($mounts)
        Raw = $info
    }
}

function Assert-VibeboxManagedTarget {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-VibeboxManagedInstance -Name $Name)) {
        throw "Instance '$Name' is not managed by Vibebox. Refusing to operate on an unrelated instance."
    }
    $marker = Get-VibeboxInstanceMarker -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) {
        throw "Managed instance '$Name' was not found."
    }
    if ($marker.imageHash) {
        if ([string]::IsNullOrWhiteSpace($info.ImageHash)) {
            throw "Could not verify the image identity for managed instance '$Name'. Refusing the operation."
        }
        if ([string]$marker.imageHash -ne [string]$info.ImageHash) {
            throw "Instance '$Name' does not match the image identity recorded by Vibebox. Refusing a destructive operation."
        }
    }
    $hyperv = Get-VibeboxHyperVInstance -Name $Name
    if ($marker.hyperVId) {
        if ($null -eq $hyperv) {
            throw "Could not verify the Hyper-V identity for managed instance '$Name'. Refusing the operation."
        }
        if ([string]$marker.hyperVId -ne [string]$hyperv.Id) {
            throw "Instance '$Name' does not match the Hyper-V identity recorded by Vibebox. Refusing a destructive operation."
        }
    }
}

function Get-VibeboxHyperVInstance {
    param([Parameter(Mandatory)][string]$Name)

    $getVm = Get-Command Get-VM -ErrorAction SilentlyContinue
    if ($null -eq $getVm) {
        return $null
    }
    try {
        return @(Get-VM -Name $Name -ErrorAction Stop | Where-Object { $_.Name -eq $Name }) |
            Select-Object -First 1
    } catch {
        return $null
    }
}

function Set-VibeboxHyperVPolicy {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Config
    )

    $vm = Get-VibeboxHyperVInstance -Name $Name
    if ($null -eq $vm) {
        Write-Warning "Hyper-V did not expose an exact VM named '$Name'; autostart/stop/nested policy could not be applied."
        return $false
    }
    if ($vm.State -ne "Off") {
        throw "Hyper-V policy changes require VM '$Name' to be stopped."
    }

    $autoStart = ConvertTo-VibeboxBoolean -Value $Config.Values.VM_AUTOSTART -Name "VM_AUTOSTART"
    $startAction = if ($autoStart) { "Start" } else { "Nothing" }
    $stopAction = if ($Config.Values.VM_STOP_ACTION -eq "shutdown") { "ShutDown" } else { "Save" }
    Set-VM -VM $vm -AutomaticStartAction $startAction -AutomaticStopAction $stopAction -AutomaticStartDelay 30
    $nested = ConvertTo-VibeboxBoolean -Value $Config.Values.VM_NESTED_VIRT -Name "VM_NESTED_VIRT"
    Set-VMProcessor -VM $vm -ExposeVirtualizationExtensions:$nested
    return $true
}

function Resize-VibeboxHyperVDisk {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][uint64]$TargetBytes
    )

    $vm = Get-VibeboxHyperVInstance -Name $Name
    if ($null -eq $vm) {
        throw "Hyper-V did not expose an exact VM named '$Name'; cannot safely resize its disk."
    }
    if ($vm.State -ne "Off") {
        throw "Disk changes require VM '$Name' to be stopped."
    }
    $drive = @(Get-VMHardDiskDrive -VM $vm | Select-Object -First 1)
    if ($drive.Count -eq 0 -or [string]::IsNullOrWhiteSpace($drive[0].Path)) {
        throw "Could not resolve the exact VHDX for VM '$Name'."
    }
    $vhd = Get-VHD -Path $drive[0].Path -ErrorAction Stop
    if ([uint64]$vhd.Size -gt $TargetBytes) {
        throw "Configured VM_DISK is smaller than the current VHDX. Shrinking a VM disk is refused."
    }
    if ([uint64]$vhd.Size -lt $TargetBytes) {
        Resize-VHD -Path $drive[0].Path -SizeBytes $TargetBytes
        return $true
    }
    return $false
}

function Get-VibeboxImageHash {
    param([Parameter(Mandatory)][string]$Name)
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { return "" }
    return $info.ImageHash
}

function New-VibeboxGuestPayload {
    param(
        [Parameter(Mandatory)][string]$Name,
        $Config
    )

    $guest = Get-VibeboxPath -Name Guest
    if ($null -eq $Config) {
        $Config = Get-VibeboxConfig -CreateIfMissing
    }
    $secretKeys = @(Find-VibeboxSecretConfiguration -Config $Config)
    if ($secretKeys.Count -gt 0) {
        throw "vibebox.env contains key-shaped secret values in: $($secretKeys -join ', '). Remove them before transferring guest configuration."
    }
    $envPath = Join-Path (Get-VibeboxStateDirectory) "$Name-effective.env"
    $effectiveEnv = foreach ($key in $script:VibeboxConfigKeys) {
        "$key=$($Config.Values[$key])"
    }
    Set-Content -LiteralPath $envPath -Value $effectiveEnv -Encoding ascii
    try {
        # Transfer the contents, not the host directory itself. This keeps the
        # clean guest contract at /opt/vibebox/{provision,units,...}.
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", "if [[ -f /opt/vibebox/manifest.lock ]]; then cp /opt/vibebox/manifest.lock /tmp/vibebox-manifest.lock; fi; rm -rf /tmp/guest") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("transfer", "--recursive", $guest, "${Name}:/tmp") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "mkdir", "-p", "/opt/vibebox") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "cp", "-a", "/tmp/guest/.", "/opt/vibebox/") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", "if [[ -f /tmp/vibebox-manifest.lock ]]; then cp /tmp/vibebox-manifest.lock /opt/vibebox/manifest.lock; fi; rm -rf /tmp/guest /tmp/vibebox-manifest.lock") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("transfer", $envPath, "${Name}:/tmp/vibebox.env") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "cp", "/tmp/vibebox.env", "/opt/vibebox/vibebox.env") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "rm", "-f", "/tmp/vibebox.env") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "chmod", "-R", "a+rX", "/opt/vibebox") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", "chmod +x /opt/vibebox/provision/* /opt/vibebox/*.sh /opt/vibebox/backup-producer") | Out-Null
        Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "chown", "-R", "root:root", "/opt/vibebox") | Out-Null
    } finally {
        Remove-Item -LiteralPath $envPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-VibeboxGuestProvision {
    param([Parameter(Mandatory)][string]$Name)
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "/opt/vibebox/provision/provision.sh") | Out-Null
}

function Wait-VibeboxInstance {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 90
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $info = Get-VibeboxInstanceInfo -Name $Name
        if ($null -ne $info -and $info.State -eq "RUNNING" -and -not [string]::IsNullOrWhiteSpace($info.IPv4)) {
            return $info
        }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    throw "VM '$Name' did not become running with an address within $TimeoutSeconds seconds."
}

function New-VibeboxInstance {
    param(
        [Parameter(Mandatory)]$Config,
        [hashtable]$Overrides = @{}
    )

    $name = $Config.Values.VM_NAME
    if (Test-VibeboxManagedInstance -Name $name) {
        $existing = Get-VibeboxInstanceInfo -Name $name
        if ($null -eq $existing) {
            $marker = Get-VibeboxInstanceMarker -Name $name
            if ($marker.state -eq "creating") {
                # The launch may have been interrupted before Multipass created
                # anything. Remove only our intent marker and retry normally.
                Remove-Item -LiteralPath (Get-VibeboxInstanceMarkerPath -Name $name) -Force
            } else {
                throw "Vibebox marker exists for '$name', but Multipass cannot find the instance. Repair state before retrying."
            }
        }
        if ($null -ne $existing -and (Get-VibeboxInstanceMarker -Name $name).state -eq "creating") {
            Write-Host "Resuming interrupted creation of '$name'."
            if ($existing.State -ne "RUNNING") {
                Invoke-VibeboxMultipass -Arguments @("start", $name) | Out-Null
            }
            $existing = Wait-VibeboxInstance -Name $name -TimeoutSeconds ([int]$Config.Values.READINESS_TIMEOUT_SEC)
            New-VibeboxGuestPayload -Name $name -Config $Config
            Invoke-VibeboxGuestProvision -Name $name
            Invoke-VibeboxMultipass -Arguments @("stop", "--type", "shutdown", $name) | Out-Null
            Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash $existing.ImageHash
            Set-VibeboxHyperVPolicy -Name $name -Config $Config | Out-Null
            return Start-VibeboxInstance -Name $name -Config $Config
        }
        Write-Host "Instance '$name' already exists; create is a clean no-op."
        return $existing
    }
    if ($null -ne (Get-VibeboxInstanceInfo -Name $name)) {
        throw "An unrelated Multipass instance already uses '$name'. Choose another VM_NAME."
    }

    $secretKeys = @(Find-VibeboxSecretConfiguration -Config $Config)
    if ($secretKeys.Count -gt 0) {
        throw "vibebox.env contains key-shaped secret values in: $($secretKeys -join ', '). Remove them before creating a VM."
    }
    Assert-VibeboxPreflight -Config $Config
    $key = Get-VibeboxSshKey
    $template = Get-Content -LiteralPath (Get-VibeboxPath -Name CloudInitTemplate) -Raw
    $userData = $template.Replace("__VIBEBOX_GUEST_USER__", $Config.Values.GUEST_USER).
        Replace("__VIBEBOX_GUEST_SHELL__", $Config.Values.GUEST_SHELL).
        Replace("__VIBEBOX_SSH_PUBLIC_KEY__", $key.PublicKey)
    $state = Get-VibeboxStateDirectory
    $userDataPath = Join-Path $state "$name-user-data.yaml"
    Set-Content -LiteralPath $userDataPath -Value $userData -Encoding utf8

    # Write an intent before launch so Ctrl-C at any point leaves a resumable
    # marker rather than an ambiguous instance.
    Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash "" -State creating
    Write-Host "Creating Multipass instance '$name'."
    $launchArgs = @(
        "launch", "release:$($Config.Values.UBUNTU_RELEASE)",
        "--name", $name,
        "--cpus", $Config.Values.VM_CPUS,
        "--memory", $Config.Values.VM_MEMORY,
        "--disk", $Config.Values.VM_DISK,
        "--cloud-init", $userDataPath
    )
    Invoke-VibeboxMultipass -Arguments $launchArgs | Out-Null
    $info = Wait-VibeboxInstance -Name $name -TimeoutSeconds ([int]$Config.Values.READINESS_TIMEOUT_SEC)
    New-VibeboxGuestPayload -Name $name -Config $Config
    Invoke-VibeboxGuestProvision -Name $name
    Invoke-VibeboxMultipass -Arguments @("stop", "--type", "shutdown", $name) | Out-Null
    Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash $info.ImageHash
    Set-VibeboxHyperVPolicy -Name $name -Config $Config | Out-Null
    $info = Start-VibeboxInstance -Name $name -Config $Config
    return $info
}

function Start-VibeboxInstance {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Config)
    Assert-VibeboxManagedTarget -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { throw "Instance '$Name' was not found." }
    if ($info.State -eq "RUNNING") {
        Write-Host "Instance '$Name' is already running."
    } else {
        Invoke-VibeboxMultipass -Arguments @("start", $Name) | Out-Null
    }
    $info = Wait-VibeboxInstance -Name $Name -TimeoutSeconds ([int]$Config.Values.READINESS_TIMEOUT_SEC)
    Update-VibeboxSshAlias -Name $Name -User $Config.Values.GUEST_USER -Address $info.IPv4 | Out-Null
    return $info
}

function Stop-VibeboxInstance {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Config)
    Assert-VibeboxManagedTarget -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { throw "Instance '$Name' was not found." }
    if ($info.State -eq "STOPPED") {
        Write-Host "Instance '$Name' is already stopped."
        return $info
    }
    $stopType = if ($Config.Values.VM_STOP_ACTION -eq "save") { "suspend" } else { "shutdown" }
    Invoke-VibeboxMultipass -Arguments @("stop", "--type", $stopType, $Name) | Out-Null
    return (Get-VibeboxInstanceInfo -Name $Name)
}

function Restart-VibeboxInstance {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)]$Config)
    Stop-VibeboxInstance -Name $Name -Config $Config | Out-Null
    return Start-VibeboxInstance -Name $Name -Config $Config
}

function Remove-VibeboxInstance {
    param([Parameter(Mandatory)][string]$Name)
    Assert-VibeboxManagedTarget -Name $Name
    $info = Get-VibeboxInstanceInfo -Name $Name
    if ($null -eq $info) { throw "Instance '$Name' was not found." }
    Write-Host "Resolved destructive target: Multipass instance '$Name' (state: $($info.State))."
    Invoke-VibeboxMultipass -Arguments @("delete", "--purge", $Name) | Out-Null
    Remove-Item -LiteralPath (Get-VibeboxInstanceMarkerPath -Name $Name) -Force
    $rescuePath = Join-Path (Get-VibeboxPath -Name State) "rescue\$Name.txt"
    if (Test-Path -LiteralPath $rescuePath -PathType Leaf) {
        Remove-Item -LiteralPath $rescuePath -Force
    }
    Write-Host "Destroyed Vibebox instance '$Name'."
}
