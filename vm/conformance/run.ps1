[CmdletBinding()]
param(
    [string]$Name,
    [switch]$Json,
    # The 20-vps group proves unmodified upstream installs work (PostgreSQL,
    # nginx, timers, sysctl). It is slow and it mutates the guest, so it is
    # opt-in: run it for Gate A evidence, not on every loop.
    [switch]$Full
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
. (Join-Path $root "vm\host\lib\config.ps1")
. (Join-Path $root "vm\host\lib\lifecycle.ps1")

$config = Get-VibeboxConfig -CreateIfMissing
if ([string]::IsNullOrWhiteSpace($Name)) { $Name = $config.Values.VM_NAME }
Assert-VibeboxManagedTarget -Name $Name

$results = [System.Collections.Generic.List[object]]::new()
function Add-CheckOutput {
    param([string]$Output, [string]$Scope, [string]$Path)
    foreach ($line in ($Output -split "`r?`n")) {
        if ($line -match '^(ok|not ok|skip)\s+(\S+)\s+-\s+(.+)$') {
            $null = $results.Add([pscustomobject]@{
                scope = $Scope
                file = $Path
                status = $Matches[1]
                id = $Matches[2]
                description = $Matches[3]
            })
        }
    }
}

$guestRoot = Join-Path $root "vm\conformance"
Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "rm", "-rf", "/tmp/guest", "/tmp/vibebox-conformance") | Out-Null
Invoke-VibeboxMultipass -Arguments @("transfer", "--recursive", (Join-Path $guestRoot "guest"), "${Name}:/tmp") | Out-Null
Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "mkdir", "-p", "/tmp/vibebox-conformance") | Out-Null
Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "mv", "/tmp/guest", "/tmp/vibebox-conformance/guest") | Out-Null
Invoke-VibeboxMultipass -Arguments @("transfer", (Join-Path $guestRoot "lib.sh"), "${Name}:/tmp/vibebox-lib.sh") | Out-Null
Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "mv", "/tmp/vibebox-lib.sh", "/tmp/vibebox-conformance/lib.sh") | Out-Null

$guestFiles = @(Get-ChildItem -LiteralPath (Join-Path $guestRoot "guest") -Filter "*.sh" -Recurse -File | Sort-Object FullName)
if (-not $Full) {
    $guestFiles = @($guestFiles | Where-Object { $_.Directory.Name -ne '20-vps' })
    Write-Verbose "Skipping the 20-vps group; re-run with -Full for upstream-install evidence."
}
foreach ($file in $guestFiles) {
    $relative = $file.FullName.Substring((Join-Path $guestRoot "guest").Length).TrimStart("\").Replace("\", "/")
    $remote = "/tmp/vibebox-conformance/guest/$relative"
    $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", $remote) -AllowFailure
    $output = ($result.Output -join "`n")
    $before = $results.Count
    Add-CheckOutput -Output $output -Scope "guest" -Path $relative
    if ($result.ExitCode -notin @(0, 77) -and
        -not ($results | Select-Object -Skip $before | Where-Object { $_.status -eq "not ok" })) {
        $null = $results.Add([pscustomobject]@{
            scope = "guest"
            file = $relative
            status = "not ok"
            id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            description = "check exited $($result.ExitCode) without a not ok result"
        })
    } elseif ($result.ExitCode -eq 77 -and
        -not ($results | Select-Object -Skip $before | Where-Object { $_.status -eq "skip" })) {
        $null = $results.Add([pscustomobject]@{
            scope = "guest"
            file = $relative
            status = "skip"
            id = [IO.Path]::GetFileNameWithoutExtension($file.Name)
            description = "check skipped with exit code 77"
        })
    }
}

$hostFiles = @(Get-ChildItem -LiteralPath (Join-Path $guestRoot "host") -Filter "*.ps1" -Recurse -File | Sort-Object FullName)
foreach ($file in $hostFiles) {
    $relative = $file.FullName.Substring((Join-Path $guestRoot "host").Length).TrimStart("\").Replace("\", "/")
    $output = & pwsh -NoProfile -File $file.FullName -Name $Name 2>&1
    $exitCode = $LASTEXITCODE
    $before = $results.Count
    Add-CheckOutput -Output ($output -join "`n") -Scope "host" -Path $relative
    if ($exitCode -notin @(0, 77) -and -not ($results | Where-Object { $_.file -eq $relative -and $_.status -eq "not ok" })) {
        $null = $results.Add([pscustomobject]@{ scope = "host"; file = $relative; status = "not ok"; id = [IO.Path]::GetFileNameWithoutExtension($file.Name); description = "check exited $exitCode" })
    } elseif ($exitCode -eq 77 -and
        -not ($results | Select-Object -Skip $before | Where-Object { $_.status -eq "skip" })) {
        $null = $results.Add([pscustomobject]@{ scope = "host"; file = $relative; status = "skip"; id = [IO.Path]::GetFileNameWithoutExtension($file.Name); description = "check skipped with exit code 77" })
    }
}

$summary = [pscustomobject]@{
    name = $Name
    checkedAt = (Get-Date).ToUniversalTime().ToString("o")
    pass = @($results | Where-Object status -eq "ok").Count
    fail = @($results | Where-Object status -eq "not ok").Count
    skip = @($results | Where-Object status -eq "skip").Count
    checks = @($results)
}
if ($Json) {
    $summary | ConvertTo-Json -Depth 10 -Compress
} else {
    $results | ForEach-Object { "$($_.status) $($_.id) - $($_.description)" }
    "pass=$($summary.pass) fail=$($summary.fail) skip=$($summary.skip)"
}
Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "rm", "-rf", "/tmp/vibebox-conformance") -AllowFailure | Out-Null
if ($summary.fail -gt 0) { exit 5 }
exit 0
