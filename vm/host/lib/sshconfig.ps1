Set-StrictMode -Version Latest

function Get-VibeboxSshKeyDirectory {
    $directory = Join-Path (Get-VibeboxPath -Name State) "ssh"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return $directory
}

function Get-VibeboxSshKey {
    $directory = Get-VibeboxSshKeyDirectory
    $private = Join-Path $directory "id_ed25519"
    $public = "$private.pub"
    if (-not (Test-Path -LiteralPath $private -PathType Leaf) -or
        -not (Test-Path -LiteralPath $public -PathType Leaf)) {
        $sshKeygen = Get-Command ssh-keygen -ErrorAction Stop
        & $sshKeygen.Source -t ed25519 -N "" -C "vibebox-managed" -f $private | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not create the managed SSH key."
        }
    }
    return [pscustomobject]@{ PrivateKey = $private; PublicKey = (Get-Content -LiteralPath $public -Raw).Trim() }
}

function Update-VibeboxSshAlias {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$Address
    )

    $sshDirectory = Join-Path $HOME ".ssh"
    if (-not (Test-Path -LiteralPath $sshDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
    }
    $configPath = Join-Path $sshDirectory "config"
    $begin = "# >>> vibebox alias: $Name >>>"
    $end = "# <<< vibebox alias: $Name <<<"
    $lines = if (Test-Path -LiteralPath $configPath) { @(Get-Content -LiteralPath $configPath) } else { @() }
    $filtered = [System.Collections.Generic.List[string]]::new()
    $inside = $false
    foreach ($line in $lines) {
        if ($line -eq $begin) { $inside = $true; continue }
        if ($line -eq $end) { $inside = $false; continue }
        if (-not $inside) { $filtered.Add($line) }
    }
    while ($filtered.Count -gt 0 -and [string]::IsNullOrWhiteSpace($filtered[$filtered.Count - 1])) {
        $filtered.RemoveAt($filtered.Count - 1)
    }
    if ($filtered.Count -gt 0) { $filtered.Add("") }
    $key = Get-VibeboxSshKey
    $filtered.Add($begin)
    $filtered.Add("Host $Name")
    $filtered.Add("    HostName $Address")
    $filtered.Add("    User $User")
    $filtered.Add("    IdentityFile $($key.PrivateKey)")
    $filtered.Add("    IdentitiesOnly yes")
    $filtered.Add($end)
    Set-Content -LiteralPath $configPath -Value $filtered -Encoding ascii
    return $configPath
}
