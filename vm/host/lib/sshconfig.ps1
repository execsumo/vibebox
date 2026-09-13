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

    # ssh takes the FIRST value it sees for each keyword, so an earlier
    # "Host <name>" block silently wins over the one just written. The legacy
    # container's setup-sandbox alias does exactly this -- it points the same
    # name at 127.0.0.1 -- and the failure reads as "Connection refused"
    # rather than anything pointing at the real cause.
    $conflict = Find-VibeboxSshAliasConflict -ConfigPath $configPath -Name $Name
    if ($null -ne $conflict) {
        Write-Warning ("~/.ssh/config defines 'Host $Name' at line $($conflict.Line) before the vibebox block, " +
            "pointing at $($conflict.HostName). ssh uses the first match, so that entry wins and this alias is ignored. Remove it.")
    }
    return $configPath
}

function Find-VibeboxSshAliasConflict {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { return $null }
    $lines = @(Get-Content -LiteralPath $ConfigPath)
    $marker = "# >>> vibebox alias: $Name >>>"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq $marker) { return $null }   # ours comes first; nothing shadows it
        if ($lines[$i] -match '^\s*Host\s+(.+)$') {
            $patterns = $Matches[1].Trim() -split '\s+'
            if ($patterns -contains $Name) {
                $hostName = "an unspecified address"
                for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                    if ($lines[$j] -match '^\s*Host\s+') { break }
                    if ($lines[$j] -match '^\s*HostName\s+(.+)$') { $hostName = $Matches[1].Trim(); break }
                }
                return [pscustomobject]@{ Line = $i + 1; HostName = $hostName }
            }
        }
    }
    return $null
}
