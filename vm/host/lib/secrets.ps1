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
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$Secret
    )

    $command = Get-VibeboxMultipassCommand
    if ($null -eq $command) { throw "Multipass is not installed. Install Canonical Multipass before enrolling secrets." }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $command.Source
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    $null = $process.Start()
    $process.StandardInput.WriteLine($Secret)
    $process.StandardInput.Close()
    # Consume output so a verbose client cannot block on a full pipe. Never
    # print either stream because it may echo enrollment context.
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $null = $stdoutTask.Result
    $null = $stderrTask.Result
    if ($process.ExitCode -ne 0) {
        throw "Secret-bearing operation for '$Name' failed with exit code $($process.ExitCode). No secret was written to the log."
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
    param([Parameter(Mandatory)][string]$Name)

    $path = Get-VibeboxRescuePasswordPath -Name $Name
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $null
    }
    $password = New-VibeboxPassword
    Invoke-VibeboxSecretInput -Name "rescue-password" -Arguments @(
        "exec", $Name, "--", "sudo", "chpasswd"
    ) -Secret "ubuntu:$password"
    Invoke-VibeboxMultipass -Arguments @("exec", $Name, "--", "sudo", "passwd", "--unlock", "ubuntu") | Out-Null
    Set-Content -LiteralPath $path -Value $password -NoNewline -Encoding utf8
    & icacls.exe $path /inheritance:r /grant:r "$env:USERNAME:(R)" "SYSTEM:(F)" "Administrators:(F)" | Out-Null
    Write-Host "Rescue password (displayed once): $password"
    Write-Host "Stored with a restricted ACL at $path"
    return $password
}

function Invoke-VibeboxEnroll {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][ValidateSet("tailscale", "github", "hermes")][string]$Provider
    )

    switch ($Provider) {
        "tailscale" {
            $secure = Read-Host "Paste the short-lived Tailscale auth key (input is not logged)" -AsSecureString
            $secret = ConvertTo-VibeboxPlainText -SecureString $secure
            try {
                Invoke-VibeboxSecretInput -Name "tailscale" -Arguments @(
                    "exec", $Name, "--", "sudo", "bash", "-lc",
                    'read -r key; tailscale up --auth-key="$key" --hostname="' + $Name + '" --advertise-tags=tag:vibebox'
                ) -Secret $secret
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
