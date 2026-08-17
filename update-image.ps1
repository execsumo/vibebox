# PowerShell script to refresh the sandbox image from scratch.
# Linux/macOS host: use update-image.sh instead.
#
# This is the durable, once-in-a-while update path. The in-container `update` command is
# the fast one: it swaps tools in place without restarting anything, but it does not touch
# APT or the base image, and its changes reset on the next `docker compose down/up`. This
# script rebuilds the image so those updates stick — and picks up APT, the base image, and
# the tailscale sidecars along the way.
#
# The build runs against nothing that is live, so the long part is safe to leave running
# while you keep working. Applying the new image is what recreates the sandbox and ends
# every SSH session, tmux window, and running agent — so that step asks first.
#
# Usage:
#   .\update-image.ps1              # Pull, rebuild, then ask before restarting
#   .\update-image.ps1 -Yes         # Same, but apply without asking (unattended/scheduled)
#   .\update-image.ps1 -BuildOnly   # Pull and rebuild, never apply

$ErrorActionPreference = "Stop"

function Get-EnvValue {
    param(
        [string]$Name,
        [string]$Default
    )

    $EnvPath = Join-Path $PSScriptRoot ".env"
    if (Test-Path $EnvPath) {
        foreach ($Line in Get-Content $EnvPath) {
            if ($Line -match "^\s*$Name\s*=\s*(.+?)\s*$") {
                return $Matches[1].Trim()
            }
        }
    }

    return $Default
}

$SandboxName = Get-EnvValue -Name "SANDBOX_NAME" -Default "vibebox"
$ImageRef = "${SandboxName}:latest"

$AutoYes = $false
$BuildOnly = $false
foreach ($arg in $args) {
    if ($arg -eq "-Yes") { $AutoYes = $true }
    elseif ($arg -eq "-BuildOnly") { $BuildOnly = $true }
    else { throw "Unknown argument: $arg" }
}

Set-Location $PSScriptRoot

$Total = 4

Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "         Refreshing the Sandbox Image         " -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "Sandbox:     $SandboxName" -ForegroundColor Yellow
Write-Host "Image:       $ImageRef" -ForegroundColor Yellow
Write-Host ""

# The image id before the build, so the summary can say whether anything actually changed.
$OldImageId = docker image inspect --format '{{.Id}}' $ImageRef 2>$null
if ($LASTEXITCODE -ne 0) { $OldImageId = "" }

try {
    Write-Host "1/$Total Pulling sidecar images..." -ForegroundColor Cyan
    # The two tailscale containers come from an upstream image rather than this Dockerfile,
    # so they update by pull, not by build.
    #
    # --ignore-buildable is required, not cosmetic: a bare `docker compose pull` also tries
    # to pull the `sandbox` service, which is built from the local Dockerfile and exists in
    # no registry. That fails with "pull access denied for vibebox" and aborts the run
    # before it ever reaches the build. The flag skips any service with a `build:` section,
    # so adding another built service later needs no change here.
    docker compose pull --ignore-buildable
    if ($LASTEXITCODE -ne 0) { throw "Sidecar image pull failed." }
    Write-Host ""

    Write-Host "2/$Total Rebuilding the sandbox image (this takes a while)..." -ForegroundColor Cyan
    Write-Host "    --no-cache is deliberate: without it Docker reuses the cached APT and npm" -ForegroundColor DarkGray
    Write-Host "    layers and the rebuild silently updates nothing. Expect ~10-15 minutes," -ForegroundColor DarkGray
    Write-Host "    most of it recompiling docling's torch dependency." -ForegroundColor DarkGray
    Write-Host "    Nothing running is touched by this step." -ForegroundColor DarkGray
    # --pull refreshes the base image too. A build failure stops the script here, before
    # the apply step: the Dockerfile's final stage verifies the toolchain and hard-fails if
    # a daily-driver tool is missing or cannot run, so a broken build never becomes a
    # running container and the existing one keeps serving.
    # Explicit $LASTEXITCODE check — a native command's non-zero exit does not trip
    # $ErrorActionPreference (same reason restore.ps1 checks it after `docker run`).
    docker compose build --no-cache --pull sandbox
    if ($LASTEXITCODE -ne 0) {
        Write-Host ""
        Write-Host "ERROR: Image build failed. Nothing was applied - the running sandbox is untouched." -ForegroundColor Red
        Write-Host "==============================================" -ForegroundColor Cyan
        exit 1
    }
    Write-Host ""

    $NewImageId = docker image inspect --format '{{.Id}}' $ImageRef 2>$null
    if ($LASTEXITCODE -ne 0) { $NewImageId = "" }
    $NewImageCreated = docker image inspect --format '{{.Created}}' $ImageRef 2>$null
    if ($LASTEXITCODE -ne 0) { $NewImageCreated = "unknown" }

    Write-Host "3/$Total Build result" -ForegroundColor Cyan
    Write-Host "Built:       $NewImageCreated" -ForegroundColor Yellow
    if (-not $OldImageId) {
        Write-Host "Status:      new image (nothing to compare against)" -ForegroundColor Yellow
    } elseif ($OldImageId -eq $NewImageId) {
        Write-Host "Status:      identical to the running image - nothing changed upstream" -ForegroundColor Yellow
    } else {
        Write-Host "Status:      new image differs from the one in use" -ForegroundColor Green
        $OldShort = $OldImageId.Substring(7, 12)
        $NewShort = $NewImageId.Substring(7, 12)
        Write-Host "    old $OldShort  ->  new $NewShort" -ForegroundColor DarkGray
    }
    Write-Host ""

    if ($BuildOnly) {
        Write-Host "-BuildOnly: stopping here. Apply it whenever you are ready:" -ForegroundColor Yellow
        Write-Host "    docker compose up -d"
        Write-Host "==============================================" -ForegroundColor Cyan
        exit 0
    }

    if (-not $AutoYes) {
        Write-Host "Applying this image recreates the sandbox container." -ForegroundColor Yellow
        Write-Host "Every SSH session, tmux window, and running agent inside it will end." -ForegroundColor Yellow
        Write-Host "    Your home directory and Tailscale identity are on volumes and survive." -ForegroundColor DarkGray
        $Reply = Read-Host "Apply now? [y/N]"
        if ($Reply -notmatch '^(y|yes)$') {
            Write-Host ""
            Write-Host "Not applied. The new image is built and waiting - apply it when ready:" -ForegroundColor Yellow
            Write-Host "    docker compose up -d"
            Write-Host "==============================================" -ForegroundColor Cyan
            exit 0
        }
        Write-Host ""
    }

    Write-Host "4/$Total Applying the new image..." -ForegroundColor Cyan
    docker compose up -d
    Write-Host ""
    docker compose ps
    Write-Host ""
    Write-Host "Sandbox image refreshed and running." -ForegroundColor Green
    Write-Host "    The Hermes WebUI is started by the entrypoint; check with" -ForegroundColor DarkGray
    Write-Host "    'hermes-webui status' once you are back inside the box." -ForegroundColor DarkGray
} catch {
    Write-Host "ERROR: Image refresh failed: $_" -ForegroundColor Red
    Write-Host "==============================================" -ForegroundColor Cyan
    exit 1
}

Write-Host "==============================================" -ForegroundColor Cyan
