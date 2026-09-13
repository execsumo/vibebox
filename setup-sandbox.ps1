$ErrorActionPreference = "Stop"

Write-Host "Legacy edition: setup-sandbox.ps1 moved to legacy/; forwarding arguments."

$LegacyDir = Join-Path $PSScriptRoot "legacy"
$Target = Join-Path $LegacyDir "setup-sandbox.ps1"
if (-not (Test-Path -LiteralPath $Target -PathType Leaf)) {
    throw "Legacy setup script was not found at $Target."
}

$PreviousLocation = Get-Location
$ExitCode = 0
try {
    Set-Location -LiteralPath $LegacyDir
    & $Target @args
    if ($null -ne $LASTEXITCODE) {
        $ExitCode = $LASTEXITCODE
    }
}
finally {
    Set-Location -LiteralPath $PreviousLocation
}

exit $ExitCode
