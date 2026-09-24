Set-StrictMode -Version Latest

# Host networking for the Hyper-V Default Switch.
#
# Multipass on Hyper-V does not ask Hyper-V for the guest's address. It dials
# "<instance>.mshome.net", a name served by Internet Connection Sharing
# (SharedAccess) out of %windir%\System32\drivers\etc\hosts.ics, the same file
# ICS keeps its DHCP leases in. Two ICS behaviors break that after a host
# reboot:
#
#   - The Default Switch gets a new subnet on every boot, but ICS reloads the
#     previous boot's leases from hosts.ics and keeps serving any that have
#     not expired (leases last a week). The instance name then resolves to its
#     new address AND to a dead one from the old subnet.
#   - ICS rewrites hosts.ics in place without truncating it, so a shorter
#     rewrite leaves the tail of the old file behind: stale entries plus
#     fragments of broken lines.
#
# Multipass dials the dead address, waits on "Starting" forever, and wedges
# multipassd with it. The guest itself is healthy the whole time. It gets its
# lease within seconds, which is why none of DHCP, HNS, the switch or the
# image is at fault, and why rebuilding the VM changes nothing: the stale entry
# is keyed by name.
#
# Detection needs no elevation. Repair does, because hosts.ics and the
# SharedAccess and Multipass services are admin-only, so it runs as one
# elevated step (a single UAC prompt), the same way `memory apply` does.

$script:VibeboxHostsIcsPath = Join-Path $env:windir "System32\drivers\etc\hosts.ics"
$script:VibeboxHostnetTaskName = "Vibebox Host Network Guard"
$script:VibeboxHostnetGuardDirectory = Join-Path $env:ProgramData "Vibebox"
$script:VibeboxHostnetGuardScript = Join-Path $script:VibeboxHostnetGuardDirectory "hostnet-guard.ps1"

# These two functions are also injected verbatim into the elevated repair and
# into the boot guard, which run under Windows PowerShell 5.1 with nothing else
# of this module loaded. Keep them self-contained and 5.1-compatible.
function Test-VibeboxIPv4InSubnet {
    param(
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][string]$Network,
        [Parameter(Mandatory)][int]$PrefixLength
    )
    $a = [System.Net.IPAddress]::Parse($Address).GetAddressBytes()
    $n = [System.Net.IPAddress]::Parse($Network).GetAddressBytes()
    [Array]::Reverse($a)
    [Array]::Reverse($n)
    # Decimal on purpose: PowerShell reads the literal 0xFFFFFFFF as Int32 -1.
    $mask = if ($PrefixLength -le 0) { [uint32]0 } else { [uint32](([uint64]4294967295 -shl (32 - $PrefixLength)) -band [uint64]4294967295) }
    return (([BitConverter]::ToUInt32($a, 0) -band $mask) -eq ([BitConverter]::ToUInt32($n, 0) -band $mask))
}

function ConvertTo-VibeboxSanitizedHostsIcs {
    param(
        [AllowEmptyCollection()][string[]]$Lines = @(),
        # Objects with Address and PrefixLength: the host's live IPv4 subnets.
        [AllowEmptyCollection()][object[]]$Subnets = @()
    )

    # An entry is "<ip> <name> # <lease expiry>", the expiry being a UTC
    # SYSTEMTIME: year month day-of-week day hour minute second millisecond.
    $pattern = '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+(\S+)\s*(?:#\s*([\d ]*))?$'
    $header = New-Object System.Collections.Generic.List[string]
    $entries = New-Object System.Collections.Generic.List[object]
    $removed = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($line in $Lines) {
        $index++
        if ($line -match '^\s*#') {
            if ($entries.Count -eq 0) { $header.Add($line) }
            continue
        }
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success -or $null -eq ($match.Groups[1].Value -as [System.Net.IPAddress])) {
            $removed.Add([pscustomobject]@{ Line = $line; Address = ""; HostName = ""; Reason = "malformed" })
            continue
        }
        $expiry = [datetime]::MinValue
        $parts = @($match.Groups[3].Value.Trim() -split '\s+' | Where-Object { $_ -ne "" })
        if ($parts.Count -eq 8) {
            try {
                $expiry = New-Object DateTime ([int]$parts[0]), ([int]$parts[1]), ([int]$parts[3]),
                    ([int]$parts[4]), ([int]$parts[5]), ([int]$parts[6]), ([int]$parts[7]), ([DateTimeKind]::Utc)
            } catch { $expiry = [datetime]::MinValue }
        }
        $entries.Add([pscustomobject]@{
            Line = $line
            Address = $match.Groups[1].Value
            HostName = $match.Groups[2].Value.ToLowerInvariant()
            Expiry = $expiry
            Order = $index
        })
    }

    # Keep an entry only if a live host interface can reach it. An address
    # outside every current subnet belongs to a switch that no longer exists.
    $reachable = New-Object System.Collections.Generic.List[object]
    foreach ($entry in $entries) {
        $inSubnet = $false
        foreach ($subnet in $Subnets) {
            if (Test-VibeboxIPv4InSubnet -Address $entry.Address -Network $subnet.Address -PrefixLength ([int]$subnet.PrefixLength)) {
                $inSubnet = $true
                break
            }
        }
        if ($inSubnet) {
            $reachable.Add($entry)
        } else {
            $removed.Add([pscustomobject]@{ Line = $entry.Line; Address = $entry.Address; HostName = $entry.HostName; Reason = "outside-current-subnets" })
        }
    }

    # One address per name: the lease that expires last is the newest.
    $kept = New-Object System.Collections.Generic.List[object]
    foreach ($group in ($reachable | Group-Object -Property HostName)) {
        $newest = @($group.Group | Sort-Object -Property Expiry, Order)[-1]
        foreach ($entry in $group.Group) {
            if ($entry.Order -eq $newest.Order) {
                $kept.Add($entry)
            } else {
                $removed.Add([pscustomobject]@{ Line = $entry.Line; Address = $entry.Address; HostName = $entry.HostName; Reason = "superseded" })
            }
        }
    }
    $keptInOrder = @($kept | Sort-Object -Property Order)

    $output = New-Object System.Collections.Generic.List[string]
    foreach ($line in $header) { $output.Add($line) }
    $output.Add("")
    foreach ($entry in $keptInOrder) { $output.Add($entry.Line) }

    # ToArray, not @(): @() over a generic List inside this literal throws
    # "Argument types do not match" in PowerShell 7.
    return [pscustomobject]@{
        Lines = $output.ToArray()
        Kept = $keptInOrder
        Removed = $removed.ToArray()
    }
}

function Get-VibeboxHostSubnets {
    return @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
        ForEach-Object { [pscustomobject]@{ Address = $_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
}

function Get-VibeboxHostNetworkHealth {
    param([Parameter(Mandatory)][string]$Name)

    $fqdn = "$Name.mshome.net".ToLowerInvariant()
    if (-not (Test-Path -LiteralPath $script:VibeboxHostsIcsPath -PathType Leaf)) {
        return [pscustomobject]@{
            Ok = $true; Stale = @(); Current = ""; Malformed = 0
            Detail = "No ICS lease file; nothing can resolve $fqdn to a stale address."
        }
    }
    $lines = @(Get-Content -LiteralPath $script:VibeboxHostsIcsPath -ErrorAction Stop)
    $result = ConvertTo-VibeboxSanitizedHostsIcs -Lines $lines -Subnets (Get-VibeboxHostSubnets)
    $stale = @($result.Removed | Where-Object { $_.HostName -eq $fqdn })
    $current = @($result.Kept | Where-Object { $_.HostName -eq $fqdn } | ForEach-Object { $_.Address }) | Select-Object -First 1
    $malformed = @($result.Removed | Where-Object { $_.Reason -eq "malformed" }).Count

    if ($stale.Count -gt 0) {
        $list = ($stale | ForEach-Object { "$($_.Address) ($($_.Reason))" }) -join ", "
        return [pscustomobject]@{
            Ok = $false; Stale = $stale; Current = [string]$current; Malformed = $malformed
            Detail = ("$fqdn has stale ICS entries: $list. Multipass dials that name, so start/launch will hang on 'Starting'. " +
                "Run 'vibebox hostnet repair' (one UAC prompt); run 'vibebox hostnet enable' once so reboots clean this up automatically.")
        }
    }
    $detail = if ($current) { "$fqdn resolves only to $current, inside a live host subnet." } else { "$fqdn has no ICS entry yet; the guest registers one when it takes a lease." }
    if ($malformed -gt 0) {
        $detail += " hosts.ics also has $malformed malformed line(s) left by an untruncated ICS rewrite; harmless on their own."
    }
    return [pscustomobject]@{ Ok = $true; Stale = @(); Current = [string]$current; Malformed = $malformed; Detail = $detail }
}

function Assert-VibeboxHostNetwork {
    param([Parameter(Mandatory)][string]$Name)
    $health = Get-VibeboxHostNetworkHealth -Name $Name
    if (-not $health.Ok) {
        throw "Host network preflight failed: $($health.Detail)"
    }
}

function Test-VibeboxElevated {
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The body shared by `hostnet repair` and the boot guard. It runs elevated
# under Windows PowerShell 5.1, so it carries its own copy of the helpers above.
function Get-VibeboxHostnetCoreScript {
    $helpers = @("Test-VibeboxIPv4InSubnet", "ConvertTo-VibeboxSanitizedHostsIcs") | ForEach-Object {
        "function $_ {`n$((Get-Item "function:$_").ScriptBlock.ToString())`n}"
    }
    return @(
        'param([ValidateSet("Repair", "Boot")][string]$Mode = "Boot", [string]$InstanceName = "", [string]$BackupDirectory = "", [string]$LogPath = "")'
        'Set-StrictMode -Version 2.0'
        '$ErrorActionPreference = "Stop"'
        'function Say([string]$Message) { if ($LogPath) { Add-Content -LiteralPath $LogPath -Value $Message }; Write-Host $Message }'
        $helpers
        @'
# Refuse up front rather than half-running: unelevated, every step below is
# denied piecemeal, after the log already claims it happened.
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "The host network repair must run elevated; nothing was changed."
}
$ics = Join-Path $env:windir "System32\drivers\etc\hosts.ics"
$subnets = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
    ForEach-Object { New-Object PSObject -Property @{ Address = $_.IPAddress; PrefixLength = [int]$_.PrefixLength } })
$lines = @()
if (Test-Path -LiteralPath $ics -PathType Leaf) { $lines = @(Get-Content -LiteralPath $ics) }
$result = ConvertTo-VibeboxSanitizedHostsIcs -Lines $lines -Subnets $subnets
$changed = @($result.Removed).Count -gt 0

if ($Mode -eq "Boot" -and -not $changed) { Say "hosts.ics is clean."; return }
foreach ($entry in @($result.Removed)) { Say "removing hosts.ics line ($($entry.Reason)): $($entry.Line)" }

# A daemon already dialing a dead address never recovers on its own; a fresh
# one re-resolves the name. The VM keeps running under Hyper-V meanwhile.
$daemon = Get-Process -Name multipassd -ErrorAction SilentlyContinue
if ($daemon) {
    Say "Stopping multipassd."
    & taskkill.exe /F /T /IM multipassd.exe | Out-Null
}

if ($changed) {
    # ICS holds its lease table in memory and rewrites the file from it, so
    # edit only while SharedAccess is stopped; it reloads the file on start.
    $ics_service = Get-Service -Name SharedAccess -ErrorAction SilentlyContinue
    $wasRunning = $ics_service -and $ics_service.Status -eq "Running"
    if ($wasRunning) { Say "Stopping SharedAccess (ICS)."; Stop-Service -Name SharedAccess -Force }
    if ($BackupDirectory -and (Test-Path -LiteralPath $ics -PathType Leaf)) {
        New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        $backup = Join-Path $BackupDirectory ("hosts.ics.{0}.bak" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
        Copy-Item -LiteralPath $ics -Destination $backup -Force
        Say "Backed up hosts.ics to $backup."
    }
    # Replace the file outright: rewriting in place is what left the tail.
    [System.IO.File]::WriteAllLines($ics, [string[]]$result.Lines, (New-Object System.Text.UTF8Encoding($false)))
    Say "Rewrote hosts.ics with $(@($result.Kept).Count) current entr$(if (@($result.Kept).Count -eq 1) { 'y' } else { 'ies' })."
    if ($wasRunning) { Say "Starting SharedAccess (ICS)."; Start-Service -Name SharedAccess }
}
Clear-DnsClientCache

if ($Mode -eq "Repair" -and $InstanceName) {
    # A running guest whose lease was not in the file stays unresolvable until
    # it renews, days from now. A clean shutdown makes it take a fresh lease on
    # the next start.
    $fqdn = ("{0}.mshome.net" -f $InstanceName).ToLowerInvariant()
    $hasEntry = @($result.Kept | Where-Object { $_.HostName -eq $fqdn }).Count -gt 0
    $vm = Get-VM -Name $InstanceName -ErrorAction SilentlyContinue
    if ($vm -and [string]$vm.State -eq "Running" -and -not $hasEntry) {
        Say "Shutting down $InstanceName so it takes a fresh lease on the next start."
        $job = Stop-VM -Name $InstanceName -Force -AsJob
        if (-not (Wait-Job -Job $job -Timeout 120)) {
            Say "Guest did not shut down within 120s; turning it off."
            Stop-Job -Job $job
            Stop-VM -Name $InstanceName -TurnOff -Force
        }
        Remove-Job -Job $job -Force
    }
}

if (Get-Service -Name Multipass -ErrorAction SilentlyContinue) {
    Say "Starting Multipass."
    Start-Service -Name Multipass
}
'@
    ) -join "`n"
}

# Runs a script elevated, prompting once through UAC when this shell is not
# already elevated. Output is relayed through a log file because an elevated
# child's console cannot be captured by the unelevated parent.
function Invoke-VibeboxElevatedScript {
    param(
        [Parameter(Mandatory)][string]$Script,
        [Parameter(Mandatory)][string]$Purpose
    )
    $log = Join-Path ([System.IO.Path]::GetTempPath()) ("vibebox-elevated-{0}.log" -f [guid]::NewGuid().ToString("N"))
    $escapedLog = $log.Replace("'", "''")
    $wrapper = @"
`$LogPath = '$escapedLog'
try {
$Script
    exit 0
} catch {
    Add-Content -LiteralPath `$LogPath -Value ("ERROR: " + `$_.Exception.Message)
    exit 1
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    $arguments = @("-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded)
    try {
        if (Test-VibeboxElevated) {
            & powershell.exe @arguments | Out-Null
            $exitCode = $LASTEXITCODE
        } else {
            Write-Host "Requesting elevation to $Purpose..."
            try {
                $process = Start-Process -FilePath powershell.exe -Verb RunAs -Wait -PassThru -WindowStyle Hidden -ArgumentList $arguments
            } catch {
                throw "Elevation was declined or failed; nothing was changed. ($($_.Exception.Message))"
            }
            $exitCode = $process.ExitCode
        }
        if (Test-Path -LiteralPath $log -PathType Leaf) {
            Get-Content -LiteralPath $log | ForEach-Object { Write-Host "  $_" }
        }
        if ($exitCode -ne 0) {
            throw "The elevated step to $Purpose failed with exit code $exitCode."
        }
    } finally {
        Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    }
}

function ConvertTo-VibeboxPowerShellLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-VibeboxHostNetworkRepair {
    param([Parameter(Mandatory)][string]$Name)

    $backupDirectory = Join-Path (Get-VibeboxStateDirectory) "hostnet"
    $script = "& {`n$(Get-VibeboxHostnetCoreScript)`n} -Mode Repair -InstanceName $(ConvertTo-VibeboxPowerShellLiteral $Name) -BackupDirectory $(ConvertTo-VibeboxPowerShellLiteral $backupDirectory) -LogPath `$LogPath"
    Invoke-VibeboxElevatedScript -Script $script -Purpose "repair Default Switch name resolution"
}

function Get-VibeboxHostNetworkGuardTask {
    return Get-ScheduledTask -TaskName $script:VibeboxHostnetTaskName -ErrorAction SilentlyContinue
}

# The guard runs as SYSTEM at every boot, so its script lives where only
# administrators can change it -- never in the user-writable repository, which
# would hand SYSTEM to anything that can edit the checkout.
function Enable-VibeboxHostNetworkGuard {
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) ("vibebox-hostnet-guard-{0}.ps1" -f [guid]::NewGuid().ToString("N"))
    [System.IO.File]::WriteAllText($staging, (Get-VibeboxHostnetCoreScript) + "`n", [System.Text.UTF8Encoding]::new($true))
    try {
        $hash = (Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash
        $install = @"
`$staging = $(ConvertTo-VibeboxPowerShellLiteral $staging)
`$directory = $(ConvertTo-VibeboxPowerShellLiteral $script:VibeboxHostnetGuardDirectory)
`$target = $(ConvertTo-VibeboxPowerShellLiteral $script:VibeboxHostnetGuardScript)
`$taskName = $(ConvertTo-VibeboxPowerShellLiteral $script:VibeboxHostnetTaskName)
# Refuse a staged file that changed between hashing and this elevated copy.
if ((Get-FileHash -LiteralPath `$staging -Algorithm SHA256).Hash -ne '$hash') { throw "Staged guard script changed before install; refusing." }
New-Item -ItemType Directory -Path `$directory -Force | Out-Null
# ProgramData lets ordinary users create files; lock this folder to admins.
& icacls.exe `$directory /inheritance:r /grant:r "*S-1-5-18:(OI)(CI)F" "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-32-545:(OI)(CI)RX" | Out-Null
if (`$LASTEXITCODE -ne 0) { throw "icacls failed to restrict `$directory." }
Copy-Item -LiteralPath `$staging -Destination `$target -Force
`$log = Join-Path `$directory "hostnet-guard.log"
`$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode Boot -LogPath "{1}"' -f `$target, `$log)
`$trigger = New-ScheduledTaskTrigger -AtStartup
`$principal = New-ScheduledTaskPrincipal -UserId "S-1-5-18" -LogonType ServiceAccount -RunLevel Highest
`$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
Register-ScheduledTask -TaskName `$taskName -Action `$action -Trigger `$trigger -Principal `$principal -Settings `$settings -Force ``
    -Description "Removes stale Default Switch leases from hosts.ics at boot so Multipass instances resolve to their current address. Installed by vibebox hostnet enable." | Out-Null
Add-Content -LiteralPath `$LogPath -Value "Installed `$target and registered '`$taskName' (runs as SYSTEM at startup)."
"@
        Invoke-VibeboxElevatedScript -Script $install -Purpose "install the boot-time host network guard"
    } finally {
        Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue
    }
}

function Disable-VibeboxHostNetworkGuard {
    $remove = @"
`$taskName = $(ConvertTo-VibeboxPowerShellLiteral $script:VibeboxHostnetTaskName)
`$directory = $(ConvertTo-VibeboxPowerShellLiteral $script:VibeboxHostnetGuardDirectory)
if (Get-ScheduledTask -TaskName `$taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false
    Add-Content -LiteralPath `$LogPath -Value "Removed scheduled task '`$taskName'."
}
if (Test-Path -LiteralPath `$directory) {
    Remove-Item -LiteralPath `$directory -Recurse -Force
    Add-Content -LiteralPath `$LogPath -Value "Removed `$directory."
}
"@
    Invoke-VibeboxElevatedScript -Script $remove -Purpose "remove the boot-time host network guard"
}

function Show-VibeboxHostNetworkStatus {
    param([Parameter(Mandatory)][string]$Name)

    $health = Get-VibeboxHostNetworkHealth -Name $Name
    Write-Host "Name resolution : $(if ($health.Ok) { 'ok' } else { 'STALE' })"
    Write-Host "  $($health.Detail)"
    $task = Get-VibeboxHostNetworkGuardTask
    if ($null -eq $task) {
        Write-Host "Boot guard      : not installed. Run 'vibebox hostnet enable' once so reboots cannot leave stale entries."
    } else {
        $info = Get-ScheduledTaskInfo -TaskName $script:VibeboxHostnetTaskName -ErrorAction SilentlyContinue
        $last = if ($null -ne $info -and $info.LastRunTime) { "last run $($info.LastRunTime) (result $($info.LastTaskResult))" } else { "not run yet" }
        Write-Host "Boot guard      : $($task.State), $last"
    }
    return $health
}
