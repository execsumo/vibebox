Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "config.ps1")
. (Join-Path $PSScriptRoot "lifecycle.ps1")

function ConvertTo-VibeboxPlainText {
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Invoke-VibeboxSecretInput {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$GuestCommand,
        [Parameter(Mandatory)][string]$Secret,
        [Parameter(Mandatory)][string]$Instance,
        [Parameter(Mandatory)][string]$User
    )

    # Deliberately SSH, not `multipass exec`. Multipass does not forward stdin
    # to the guest, so a secret piped through it is never read and the command
    # blocks forever waiting on input that cannot arrive.
    $info = Get-VibeboxInstanceInfo -Name $Instance
    if ($null -eq $info -or [string]::IsNullOrWhiteSpace($info.IPv4)) {
        throw "Instance '$Instance' has no reachable address for enrollment."
    }
    $key = Get-VibeboxSshKey
    $ssh = Get-Command ssh -ErrorAction Stop

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $ssh.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-i", $key.PrivateKey,
        "-o", "BatchMode=yes",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=$(Join-Path (Get-VibeboxPath -Name State) 'known-hosts')",
        "$User@$($info.IPv4)",
        "sudo -n bash -c '$GuestCommand'"
    )) {
        $startInfo.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $process.StandardInput.Write($Secret + "`n")
    $process.StandardInput.Close()
    # Consume both streams so a verbose client cannot block on a full pipe, and
    # never print either -- they can echo enrollment context.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill($true) } catch { $process.Kill() }
        throw "Secret-bearing operation for '$Name' timed out. No secret was written to the log."
    }
    $null = $stdoutTask.Result
    $stderr = $stderrTask.Result
    if ($process.ExitCode -ne 0) {
        # Surface the guest's own diagnostic, which does not contain the secret.
        $detail = ($stderr -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join "; "
        throw "Secret-bearing operation for '$Name' failed with exit code $($process.ExitCode). $detail"
    }
}

function Get-VibeboxRescuePasswordPath {
    param([Parameter(Mandatory)][string]$Name)
    $directory = Join-Path (Get-VibeboxPath -Name State) "rescue"
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    return Join-Path $directory "$Name.txt"
}

function New-VibeboxPassword {
    $bytes = [byte[]]::new(24)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $characters = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#%+=_"
    $builder = [Text.StringBuilder]::new()
    foreach ($byte in $bytes) {
        $null = $builder.Append($characters[$byte % $characters.Length])
    }
    return $builder.ToString()
}

function Ensure-VibeboxRescuePassword {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User
    )

    $path = Get-VibeboxRescuePasswordPath -Name $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $null
    }
    $password = New-VibeboxPassword
    Invoke-VibeboxSecretInput -Name "rescue-password" -GuestCommand 'read -r c; printf %s "$c" | tr -d "\r" | chpasswd' `
        -Secret "ubuntu:$password" -Instance $Name -User $User
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "passwd", "--unlock", "ubuntu") | Out-Null
    Set-Content -LiteralPath $path -Value $password -NoNewline -Encoding utf8
    & icacls.exe $path /inheritance:r /grant:r "${env:USERNAME}:(R)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    Write-Host "Rescue password (displayed once): $password"
    Write-Host "Stored with a restricted ACL at $path"
    return $password
}

function Invoke-VibeboxEnroll {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][ValidateSet("tailscale", "github", "hermes")][string]$Provider,
        # Read the key from a KEY=VALUE file instead of prompting. The value is
        # never printed, never echoed, and never written to a log -- it goes
        # straight from the file into the guest's stdin.
        [string]$KeyFrom,
        [string]$Tag
    )

    switch ($Provider) {
        "tailscale" {
            if (-not [string]::IsNullOrWhiteSpace($KeyFrom)) {
                $keyPath = (Resolve-Path -LiteralPath $KeyFrom -ErrorAction Stop).Path
                $line = @(Get-Content -LiteralPath $keyPath |
                    Where-Object { $_ -match '^\s*TS_AUTHKEY\s*=' }) | Select-Object -First 1
                if ([string]::IsNullOrWhiteSpace($line)) {
                    throw "No TS_AUTHKEY entry found in $keyPath."
                }
                $secret = ($line -replace '^\s*TS_AUTHKEY\s*=', '').Trim().Trim('"').Trim("'")
                if ([string]::IsNullOrWhiteSpace($secret)) { throw "TS_AUTHKEY in $keyPath is empty." }
                Write-Host "Using the TS_AUTHKEY found in $keyPath (value not displayed)."
            } else {
                $secure = Read-Host "Paste the short-lived Tailscale auth key (input is not logged)" -AsSecureString
                $secret = ConvertTo-VibeboxPlainText -SecureString $secure
            }
            # Build the guest command as its own variable. Concatenating inside
            # an array literal makes PowerShell emit a stray extra element.
            $tagArgument = if ([string]::IsNullOrWhiteSpace($Tag)) { "" } else { " --advertise-tags=$Tag" }
            $guestCommand = 'read -r key; key=$(printf %s "$key" | tr -d "\r"); tailscale up --auth-key="$key" --hostname="' + $Name + '"' + $tagArgument
            try {
                Invoke-VibeboxSecretInput -Name "tailscale" -GuestCommand $guestCommand `
                    -Secret $secret -Instance $Name -User $User
            } finally {
                $secret = $null
            }
            Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "systemctl", "restart", "vibebox-tailnet.service") | Out-Null
        }
        "github" {
            Write-Host "GitHub enrollment runs interactively inside the guest; no token is captured by the host."
            $multipass = (Get-VibeboxMultipassCommand).Source
            & $multipass "exec" $Name "--" "sudo" "-u" $User "-H" "gh" "auth" "login"
            if ($LASTEXITCODE -ne 0) { throw "GitHub enrollment failed." }
        }
        "hermes" {
            Write-Host "Hermes enrollment runs interactively inside the guest; no credential is captured by the host."
            $multipass = (Get-VibeboxMultipassCommand).Source
            & $multipass "exec" $Name "--" "sudo" "-u" $User "-H" "hermes" "login"
            if ($LASTEXITCODE -ne 0) { throw "Hermes enrollment failed." }
        }
    }
}
