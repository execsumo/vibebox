# PowerShell script to set up and launch the sandbox container
# Usage:
#   .\setup-sandbox.ps1

$ErrorActionPreference = "Stop"

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         Setting up Sandbox Container         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan

# 1. Parse username from .env file
$Username = "dev"
$SandboxName = "vibebox"
$SshPort = "22"
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
        if ($Line -match "^SSH_PORT=(.*)$") {
            $SshPort = $Matches[1].Trim()
        }
    }
}

# 2. Ensure authorized_keys file exists
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

# 3. Write/refresh a local SSH alias so you can connect with `ssh <SandboxName>`.
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

# 4. Build and launch the container stack
Write-Host ""
Write-Host "Building and launching container stack via Docker Compose..." -ForegroundColor Cyan
docker compose up -d --build

# 5. Check status and output connection guide
Write-Host ""
Write-Host "Checking container status..." -ForegroundColor Cyan
$ContainerStatus = docker compose ps --format json

if ($ContainerStatus) {
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host "      Container is Running Successfully!      " -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Step 1: Authenticate Tailscale (If not already authenticated)" -ForegroundColor Yellow
    Write-Host "  To authorize your sandbox on your Tailnet, run:" -ForegroundColor Cyan
    Write-Host "    docker logs $SandboxName-tailscale" -ForegroundColor Yellow
    Write-Host "  and click the authentication URL in the log output." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Step 2: Connect to your sandbox" -ForegroundColor Yellow
    Write-Host "  A. Local Connection (from this host PC):" -ForegroundColor Cyan
    Write-Host "     ssh $SandboxName" -ForegroundColor Yellow
    Write-Host "       (alias added to ~/.ssh/config; same as: ssh -p $SshPort $($Username)@127.0.0.1)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  B. Remote Connection (from any device on your Tailnet):" -ForegroundColor Cyan
    Write-Host "     ssh $($Username)@$SandboxName" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Step 3: Launch your Workspace" -ForegroundColor Yellow
    Write-Host "  Once logged into the SSH session, run the ultimate workspace launcher:" -ForegroundColor Cyan
    Write-Host "     launch" -ForegroundColor Yellow
    Write-Host "  This places you in a persistent tmux session running herdr." -ForegroundColor Cyan
} else {
    Write-Host "Failed to start the container. Please verify Docker Desktop is running." -ForegroundColor Red
}
Write-Host "==============================================" -ForegroundColor Cyan
