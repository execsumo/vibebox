Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lifecycle.ps1")

function Get-VibeboxTailnetRegistryDirectory {
    $directory = Join-Path (Get-VibeboxPath -Name Guest) "tailnet.d"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function Read-VibeboxTailnetRegistry {
    $directory = Get-VibeboxTailnetRegistryDirectory
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($file in (Get-ChildItem -LiteralPath $directory -Filter "*.conf" -File | Sort-Object Name)) {
        $values = @{}
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            if ($line -match '^\s*([A-Z]+)\s*=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
        }
        $null = $entries.Add([pscustomobject]@{
            Name = [string]$values.SERVICE
            Target = [string]$values.TARGET
            Port = [int]$values.PORT
            Mode = [string]$values.MODE
            Path = $file.FullName
        })
    }
    return @($entries)
}

function Assert-VibeboxTailnetName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[a-z][a-z0-9-]{0,62}$') {
        throw "Tailnet service name must start with a letter and contain only lowercase letters, numbers, and dashes."
    }
}

function Assert-VibeboxTailnetTarget {
    param([Parameter(Mandatory)][string]$Target)
    if ($Target -notmatch '^https?://127\.0\.0\.1:\d{1,5}$') {
        throw "Tailnet target must be an http:// or https:// loopback URL with a port."
    }
}

function Sync-VibeboxTailnetRegistry {
    param([Parameter(Mandatory)][string]$Name)
    $directory = Get-VibeboxTailnetRegistryDirectory
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "rm", "-rf", "/tmp/tailnet.d") | Out-Null
    Invoke-VibeboxMultipass -Arguments @("transfer", "--recursive", $directory, "${Name}:/tmp") | Out-Null
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "mkdir", "-p", "/etc/vibebox/tailnet.d") | Out-Null
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "bash", "-lc", "find /etc/vibebox/tailnet.d -mindepth 1 -maxdepth 1 -type f -delete; cp -a /tmp/tailnet.d/. /etc/vibebox/tailnet.d/; rm -rf /tmp/tailnet.d; systemctl restart vibebox-tailnet.service") | Out-Null
}

function Get-VibeboxTailnetStatus {
    param([Parameter(Mandatory)][string]$Name)
    $result = Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "/opt/vibebox/tailnet-status.sh") -AllowFailure
    if ($result.ExitCode -ne 0) { return $null }
    return (($result.Output -join [Environment]::NewLine) | ConvertFrom-Json)
}

function Add-VibeboxTailnetService {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Target,
        [int]$Port = 443,
        [ValidateSet("serve", "funnel")][string]$Mode = "serve"
    )
    Assert-VibeboxTailnetName -Name $Service
    Assert-VibeboxTailnetTarget -Target $Target
    if ($Port -lt 1 -or $Port -gt 65535) { throw "Tailnet port must be between 1 and 65535." }
    $path = Join-Path (Get-VibeboxTailnetRegistryDirectory) "$Service.conf"
    @(
        "SERVICE=$Service"
        "TARGET=$Target"
        "PORT=$Port"
        "MODE=$Mode"
    ) | Set-Content -LiteralPath $path -Encoding ascii
    Sync-VibeboxTailnetRegistry -Name $Name
    Write-Host "Tailnet service '$Service' added and reconciled."
}

function Remove-VibeboxTailnetService {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Service)
    Assert-VibeboxTailnetName -Name $Service
    $path = Join-Path (Get-VibeboxTailnetRegistryDirectory) "$Service.conf"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "Tailnet service '$Service' is not in the registry; remove is a no-op."
        return
    }
    Remove-Item -LiteralPath $path -Force
    Sync-VibeboxTailnetRegistry -Name $Name
    Write-Host "Tailnet service '$Service' removed and reconciled."
}

function Apply-VibeboxTailnetServices {
    param([Parameter(Mandatory)][string]$Name)
    Sync-VibeboxTailnetRegistry -Name $Name
    Write-Host "Tailnet registry reconciled."
}
