# PowerShell script to set up and launch the sandbox container
# Usage:
#   .\setup-sandbox.ps1

$ErrorActionPreference = "Stop"

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         Setting up Sandbox Container         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Parse settings from .env file
$Username = "dev"
$SandboxName = "vibebox"
$SshPort = "22"
$TsAuthKey = ""
$EnvPath = Join-Path $PSScriptRoot ".env"
if (Test-Path $EnvPath) {
    $EnvContent = Get-Content $EnvPath
    foreach ($Line in $EnvContent) {
        if ($Line -match "^SANDBOX_USERNAME=(.*)$") {
            $Username = $Matches[1].Trim()
        }
        if ($Line -match "^SANDBOX_NAME=(.*)$") {
            $SandboxName = $Matches[1].Trim()
        }
        if ($Line -match "^SANDBOX_SSH_PORT=(.*)$") {
            $SshPort = $Matches[1].Trim()
        }
        if ($Line -match "^TS_AUTHKEY=(.*)$") {
            $TsAuthKey = $Matches[1].Trim()
        }
    }
}

# 2. Require a Tailscale auth key before doing any expensive work.
#    Interactive login is not a viable fallback here: without a key the tailscale
#    container exits and crash-loops, orphaning the network namespace the sandbox
#    shares with it, which breaks even local SSH. Fail now rather than after a
#    multi-minute image build. A shell env var wins over .env, matching Compose.
$AuthKey = if (-not [string]::IsNullOrWhiteSpace($env:TS_AUTHKEY)) { $env:TS_AUTHKEY.Trim() } else { $TsAuthKey }
if ([string]::IsNullOrWhiteSpace($AuthKey) -or -not $AuthKey.StartsWith("tskey-")) {
    Write-Host ""
    Write-Host "ERROR: TS_AUTHKEY is not set (or does not look like a Tailscale key)." -ForegroundColor Red
    Write-Host ""
    Write-Host "  The sandbox shares its network namespace with the tailscale container," -ForegroundColor Cyan
    Write-Host "  so an unauthenticated tailscale takes SSH down with it." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Generate a key at: https://login.tailscale.com/admin/settings/keys" -ForegroundColor Yellow
    Write-Host "     (recommended: Reusable + Ephemeral, tagged tag:vibebox)" -ForegroundColor DarkGray
    Write-Host "  2. Add it to .env as:  TS_AUTHKEY=tskey-auth-..." -ForegroundColor Yellow
    Write-Host "  3. Re-run this script." -ForegroundColor Yellow
    Write-Host ""
    if (-not (Test-Path $EnvPath)) {
        Write-Host "  No .env found. Start from the template:  copy .env.example .env" -ForegroundColor Yellow
        Write-Host ""
    }
    exit 1
}
Write-Host "Tailscale auth key found." -ForegroundColor Green

# 3. Ensure authorized_keys file exists
$AuthKeysPath = Join-Path $PSScriptRoot "authorized_keys"

if (-not (Test-Path $AuthKeysPath) -or (Get-Item $AuthKeysPath).Length -eq 0) {
    Write-Host "No active 'authorized_keys' file found. Looking for your Windows SSH keys..." -ForegroundColor Yellow
    
    $UserSshDir = Join-Path $HOME ".ssh"
    $KeyFiles = @("id_ed25519.pub", "id_rsa.pub")
    $FoundKey = $false

    if (Test-Path $UserSshDir) {
        foreach ($KeyFile in $KeyFiles) {
            $FullPath = Join-Path $UserSshDir $KeyFile
            if (Test-Path $FullPath) {
                Write-Host "Found public key at $FullPath. Importing it to sandbox authorized_keys..." -ForegroundColor Green
                Copy-Item -Path $FullPath -Destination $AuthKeysPath
                $FoundKey = $true
                break
            }
        }
    }

    if (-not $FoundKey) {
        Write-Host ""
        Write-Host "WARNING: Could not find a default public SSH key on your Windows host." -ForegroundColor Yellow
        Write-Host "Please paste your public key in the newly created 'authorized_keys' file in this folder," -ForegroundColor Yellow
        Write-Host "then re-run this script." -ForegroundColor Yellow
        Write-Host ""
        # Create an empty file so the mount doesn't fail
        New-Item -Path $AuthKeysPath -ItemType File -Force | Out-Null
    }
} else {
    Write-Host "'authorized_keys' file already exists and is configured." -ForegroundColor Green
}

# 4. Write/refresh a local SSH alias so you can connect with `ssh <SandboxName>`.
#    Uses 127.0.0.1 (not localhost): the port is published IPv4-only and Windows
#    resolves localhost to ::1 first. Idempotent via a marked block per sandbox.
$SshConfigDir = Join-Path $HOME ".ssh"
$SshConfigPath = Join-Path $SshConfigDir "config"
$BeginMarker = ">>> sandbox alias: $SandboxName (managed by setup-sandbox) >>>"
$EndMarker   = "<<< sandbox alias: $SandboxName <<<"
if (-not (Test-Path $SshConfigDir)) { New-Item -ItemType Directory -Path $SshConfigDir | Out-Null }
$ConfigLines = @()
if (Test-Path $SshConfigPath) { $ConfigLines = @(Get-Content $SshConfigPath) }
# Drop any previous managed block for this sandbox (markers included), preserving the rest.
$Filtered = New-Object System.Collections.Generic.List[string]
$InBlock = $false
foreach ($Line in $ConfigLines) {
    if ($Line -match [regex]::Escape($BeginMarker)) { $InBlock = $true; continue }
    if ($Line -match [regex]::Escape($EndMarker))   { $InBlock = $false; continue }
    if (-not $InBlock) { $Filtered.Add($Line) }
}
while ($Filtered.Count -gt 0 -and [string]::IsNullOrWhiteSpace($Filtered[$Filtered.Count - 1])) {
    $Filtered.RemoveAt($Filtered.Count - 1)
}
if ($Filtered.Count -gt 0) { $Filtered.Add("") }
$Filtered.Add("# $BeginMarker")
$Filtered.Add("Host $SandboxName")
$Filtered.Add("    HostName 127.0.0.1")
$Filtered.Add("    Port $SshPort")
$Filtered.Add("    User $Username")
$Filtered.Add("# $EndMarker")
Set-Content -Path $SshConfigPath -Value $Filtered -Encoding ascii
Write-Host "Configured SSH alias 'Host $SandboxName' -> 127.0.0.1:$SshPort in $SshConfigPath" -ForegroundColor Green

# 5. Build and launch the container stack
Write-Host ""
Write-Host "Building and launching container stack via Docker Compose..." -ForegroundColor Cyan
docker compose up -d --build

# 6. Check status and output connection guide
Write-Host ""
Write-Host "Checking container status..." -ForegroundColor Cyan
$ContainerStatus = docker compose ps --format json

if ($ContainerStatus) {
    # Ask tailscale for the tailnet suffix so the remote hint is a real FQDN. The
    # bare name only resolves on devices that accept Tailscale DNS; the FQDN always
    # does. Best-effort: fall back to the short name if the node isn't up yet.
    $TailnetFqdn = $SandboxName
    $StatusJson = docker exec "$SandboxName-tailscale" tailscale status --json 2>$null
    if ($StatusJson) {
        $Suffix = [regex]::Match(($StatusJson -join ""), '"MagicDNSSuffix":\s*"([^"]*)"').Groups[1].Value
        if ($Suffix) { $TailnetFqdn = "$SandboxName.$Suffix" }
    }

    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "      Container is Running Successfully!      " -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Step 1: Connect to your sandbox" -ForegroundColor Yellow
    Write-Host "  A. From this host PC:" -ForegroundColor Cyan
    Write-Host "     ssh $SandboxName" -ForegroundColor Yellow
    Write-Host "       (alias added to ~/.ssh/config; same as: ssh -p $SshPort $($Username)@127.0.0.1)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  B. From any device on your Tailnet:" -ForegroundColor Cyan
    Write-Host "     ssh $($Username)@$TailnetFqdn" -ForegroundColor Yellow
    Write-Host "       (or 'ssh $($Username)@$SandboxName' on devices using Tailscale DNS)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Step 2: First-time setup (once per sandbox)" -ForegroundColor Yellow
    Write-Host "  In the SSH session, run:" -ForegroundColor Cyan
    Write-Host "     onboard" -ForegroundColor Yellow
    Write-Host "  Wires up GitHub auth, git identity, dotfiles, RTK, and CodeGraph." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Step 3: Launch your workspace" -ForegroundColor Yellow
    Write-Host "  Every login, run:" -ForegroundColor Cyan
    Write-Host "     launch" -ForegroundColor Yellow
    Write-Host "  This places you in a persistent Herdr workspace." -ForegroundColor Cyan
} else {
    Write-Host "Failed to start the container. Please verify Docker Desktop is running." -ForegroundColor Red
}
Write-Host "==============================================" -ForegroundColor Cyan
