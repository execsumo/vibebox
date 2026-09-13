Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "preflight.ps1")
. (Join-Path $PSScriptRoot "sshconfig.ps1")

function Invoke-VibeboxMultipass {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [switch]$AllowFailure
    )

    $command = Get-VibeboxMultipassCommand
    if ($null -eq $command) {
        throw "Multipass is not installed. Install Canonical Multipass before using the VM lifecycle."
    }
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.Source
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $null = $startInfo.ArgumentList.Add($argument)
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start Multipass."
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try {
                $process.Kill($true)
            } catch {
                $process.Kill()
            }
            throw "multipass $($Arguments -join ' ') timed out after $TimeoutSeconds seconds."
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        $output = @()
        if (-not [string]::IsNullOrEmpty($stdout)) {
            $output += $stdout -split "`r?`n" | Where-Object { $_ -ne "" }
        }
        if (-not [string]::IsNullOrEmpty($stderr)) {
            $output += $stderr -split "`r?`n" | Where-Object { $_ -ne "" }
        }
        $exitCode = $process.ExitCode
    } finally {
        $process.Dispose()
    }
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
        [Parameter(Mandatory)][AllowEmptyString()][string]$ImageHash,
        [ValidateSet("creating", "ready")][string]$State = "ready"
    )
    if ($State -eq "ready" -and [string]::IsNullOrWhiteSpace($ImageHash)) {
        throw "A ready Vibebox marker requires a non-empty image hash."
    }
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

    if ($null -eq (Get-VibeboxMultipassCommand)) {
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
    $infoRoot = Get-VibeboxJsonProperty -Object $json -Name "info"
    $property = if ($null -ne $infoRoot) {
        $infoRoot.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    } else {
        $null
    }
    if ($null -eq $property) {
        return $null
    }
    $info = $property.Value
    $ip = @((Get-VibeboxJsonProperty -Object $info -Name "ipv4") |
        Where-Object { $_ -and $_ -notmatch '^127\.' }) | Select-Object -First 1
    $diskTotal = $null
    $diskUsed = $null
    $disks = Get-VibeboxJsonProperty -Object $info -Name "disks"
    if ($null -ne $disks) {
        $disk = @($disks.PSObject.Properties | Select-Object -First 1).Value
        if ($null -ne $disk) {
            $diskTotal = [string](Get-VibeboxJsonProperty -Object $disk -Name "total")
            $diskUsed = [string](Get-VibeboxJsonProperty -Object $disk -Name "used")
        }
    }
    $mounts = [System.Collections.Generic.List[object]]::new()
    $mountsObject = Get-VibeboxJsonProperty -Object $info -Name "mounts"
    if ($null -ne $mountsObject) {
        foreach ($mount in $mountsObject.PSObject.Properties) {
            $null = $mounts.Add([pscustomobject]@{
                source = [string]$mount.Name
                target = [string]$mount.Value
            })
        }
    }
    return [pscustomobject]@{
        Name = $Name
        State = [string](Get-VibeboxJsonProperty -Object $info -Name "state")
        IPv4 = [string]$ip
        ImageHash = [string](Get-VibeboxJsonProperty -Object $info -Name "image_hash")
        Release = [string](Get-VibeboxJsonProperty -Object $info -Name "release")
        Load = [string](Get-VibeboxJsonProperty -Object $info -Name "load")
        MemoryTotal = [string](Get-VibeboxJsonProperty -Object (Get-VibeboxJsonProperty -Object $info -Name "memory") -Name "total")
        MemoryUsed = [string](Get-VibeboxJsonProperty -Object (Get-VibeboxJsonProperty -Object $info -Name "memory") -Name "used")
        DiskTotal = $diskTotal
        DiskUsed = $diskUsed
        Mounts = @($mounts)
        Raw = $info
    }
}

function Get-VibeboxJsonProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Get-VibeboxMarkerHyperVId {
    param($Marker)
    # Markers written by an unelevated shell have no hyperVId property at all,
    # and StrictMode throws rather than returning null for an absent property.
    if ($null -eq $Marker) { return "" }
    if ($Marker.PSObject.Properties.Name -notcontains "hyperVId") { return "" }
    return [string]$Marker.hyperVId
}

function Assert-VibeboxManagedTarget {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Test-VibeboxManagedInstance -Name $Name)) {
        throw "Instance '$Name' is not managed by Vibebox. Refusing to operate on an unrelated instance."
    }
    $marker = Get-VibeboxInstanceMarker -Name $Name
    if ([string]$marker.state -ne "ready") {
        throw "Instance '$Name' is still being created. Refusing to operate on an unverified target."
    }
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
    # Hyper-V corroboration when the shell can see it. Get-VM needs elevation,
    # so its absence is not evidence of anything and must not block the
    # operation -- the marker and image hash above are the actual proof of
    # ownership. A positive mismatch, however, is disqualifying.
    $markerHyperVId = Get-VibeboxMarkerHyperVId -Marker $marker
    $hyperv = Get-VibeboxHyperVInstance -Name $Name
    if ($markerHyperVId -and $null -ne $hyperv -and
        $markerHyperVId -ne [string]$hyperv.Id) {
        throw "Instance '$Name' does not match the Hyper-V identity recorded by Vibebox. Refusing a destructive operation."
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
    # These files are consumed by Linux. Set-Content would write CRLF on
    # Windows, and a trailing carriage return silently becomes part of every
    # value -- GUEST_USER=herwin+CR no longer names a real account.
    [System.IO.File]::WriteAllText($envPath, (($effectiveEnv -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
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
    Invoke-VibeboxMultipass -Arguments @(
        "exec", $Name, "--", "sudo", "env",
        "VIBEBOX_CONFIG_FILE=/opt/vibebox/vibebox.env",
        "/opt/vibebox/provision/provision.sh"
    ) | Out-Null
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

function Assert-VibeboxCreatePlan {
    param([Parameter(Mandatory)]$Config)

    # Touch every configuration value the create path dereferences, so a stale
    # or missing key fails here rather than after a destroy has already run.
    $required = @("UBUNTU_RELEASE", "VM_NAME", "VM_CPUS", "VM_MEMORY", "VM_DISK",
                  "GUEST_USER", "GUEST_SHELL", "READINESS_TIMEOUT_SEC")
    # $Config.Values is a hashtable; index it rather than walking PSObject
    # properties, which do not enumerate hashtable keys.
    $missing = @()
    foreach ($key in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$Config.Values[$key])) {
            $missing += $key
        }
    }
    if ($missing.Count -gt 0) {
        throw "Configuration is missing values required to create an instance: $($missing -join ', '). Nothing was changed."
    }
}

function New-VibeboxInstance {
    param(
        [Parameter(Mandatory)]$Config,
        [hashtable]$Overrides = @{}
    )

    $name = $Config.Values.VM_NAME
    if (Test-VibeboxManagedInstance -Name $name) {
        $marker = Get-VibeboxInstanceMarker -Name $name
        if ([string]$marker.state -eq "ready") {
            if ([string]$marker.ubuntuRelease -ne [string]$Config.Values.UBUNTU_RELEASE) {
                throw "UBUNTU_RELEASE is create-time-only for '$name'. Use vibebox rebuild to change it."
            }
            if ([string]$marker.guestUser -ne [string]$Config.Values.GUEST_USER) {
                throw "GUEST_USER is create-time-only for '$name'. Use vibebox rebuild to change it."
            }
        }
        $existing = Get-VibeboxInstanceInfo -Name $name
        if ($null -eq $existing) {
            if ($marker.state -eq "creating") {
                # The launch may have been interrupted before Multipass created
                # anything. Remove only our intent marker and retry normally.
                Remove-Item -LiteralPath (Get-VibeboxInstanceMarkerPath -Name $name) -Force
            } else {
                throw "Vibebox marker exists for '$name', but Multipass cannot find the instance. Repair state before retrying."
            }
        }
        if ($null -ne $existing -and (Get-VibeboxInstanceMarker -Name $name).state -eq "creating") {
            $marker = Get-VibeboxInstanceMarker -Name $name
            if ([string]$marker.ubuntuRelease -ne [string]$Config.Values.UBUNTU_RELEASE) {
                throw "Interrupted creation of '$name' used Ubuntu $($marker.ubuntuRelease), but configuration requests $($Config.Values.UBUNTU_RELEASE). Remove the incomplete VM and marker before retrying."
            }
            if ([string]$marker.guestUser -ne [string]$Config.Values.GUEST_USER) {
                throw "Interrupted creation of '$name' used guest user $($marker.guestUser), but configuration requests $($Config.Values.GUEST_USER). Remove the incomplete VM and marker before retrying."
            }
            $markerHyperVId = Get-VibeboxMarkerHyperVId -Marker $marker
            $hyperv = Get-VibeboxHyperVInstance -Name $name
            if ($markerHyperVId -and $null -ne $hyperv -and
                $markerHyperVId -ne [string]$hyperv.Id) {
                throw "Interrupted creation of '$name' does not match its recorded Hyper-V identity. Remove the incomplete VM and marker before retrying."
            }
            Write-Host "Resuming interrupted creation of '$name'."
            if ($existing.State -ne "RUNNING") {
                Invoke-VibeboxMultipass -Arguments @("start", $name) | Out-Null
            }
            $existing = Wait-VibeboxInstance -Name $name -TimeoutSeconds ([int]$Config.Values.READINESS_TIMEOUT_SEC)
            New-VibeboxGuestPayload -Name $name -Config $Config
            Invoke-VibeboxGuestProvision -Name $name
            Invoke-VibeboxMultipass -Arguments @("stop", $name) | Out-Null
            Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash $existing.ImageHash
            return Start-VibeboxInstance -Name $name -Config $Config
        }
        # Only a real instance is a no-op. When a stale "creating" marker was
        # cleared above, $existing is null and we must fall through and create.
        if ($null -ne $existing) {
            Write-Host "Instance '$name' already exists; create is a clean no-op."
            return $existing
        }
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
    [System.IO.File]::WriteAllText($userDataPath, ($userData -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))

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
    # Capture the Hyper-V identity immediately after launch. If provisioning
    # is interrupted later, resume only from a marker bound to this VM.
    Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash "" -State creating
    $info = Wait-VibeboxInstance -Name $name -TimeoutSeconds ([int]$Config.Values.READINESS_TIMEOUT_SEC)
    New-VibeboxGuestPayload -Name $name -Config $Config
    Invoke-VibeboxGuestProvision -Name $name
    Invoke-VibeboxMultipass -Arguments @("stop", $name) | Out-Null
    Save-VibeboxInstanceMarker -Name $name -Config $Config -ImageHash $info.ImageHash
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
    # ACPI shutdown, not suspend: a saved VM resumes with a stale clock.
    $stopCommand = "stop"
    Invoke-VibeboxMultipass -Arguments @($stopCommand, $Name) | Out-Null
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
