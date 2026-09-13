Set-StrictMode -Version Latest

$script:VibeboxConfigKeys = @(
    "VM_NAME",
    "UBUNTU_RELEASE",
    "VM_CPUS",
    "VM_MEMORY",
    "VM_DISK",
    "GUEST_USER",
    "GUEST_SHELL",
    "GUEST_UFW",
    "GUEST_SWAP_GB",
    "GUEST_TIMEZONE",
    "TAILSCALE_TAG",
    "NODE_MAJOR",
    "TOOLS_OPTIONAL",
    "TOOLS_UPDATE_POLICY",
    "BACKUP_DEST",
    "BACKUP_RETENTION_DAYS",
    "READINESS_TIMEOUT_SEC"
)

function Get-VibeboxRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
}

function Get-VibeboxPath {
    param([Parameter(Mandatory)][string]$Name)

    $root = Get-VibeboxRepoRoot
    $paths = @{
        Root = $root
        Vm = Join-Path $root "vm"
        Env = Join-Path $root "vm\vibebox.env"
        EnvExample = Join-Path $root "vm\vibebox.env.example"
        State = Join-Path $root "vm\state"
        CloudInitTemplate = Join-Path $root "vm\cloud-init\user-data.yaml.tmpl"
        Guest = Join-Path $root "vm\guest"
        Host = Join-Path $root "vm\host"
    }

    if (-not $paths.ContainsKey($Name)) {
        throw "Unknown Vibebox path '$Name'."
    }
    return $paths[$Name]
}

function Get-VibeboxMultipassCommand {
    $command = Get-Command multipass -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command
    }

    $candidates = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $null = $candidates.Add((Join-Path $env:ProgramFiles "Multipass\bin\multipass.exe"))
    }
    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if (-not [string]::IsNullOrWhiteSpace($programFilesX86)) {
        $null = $candidates.Add((Join-Path $programFilesX86 "Multipass\bin\multipass.exe"))
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return Get-Command -Name $candidate -ErrorAction Stop
        }
    }
    return $null
}

function Read-VibeboxKeyValueFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Configuration file not found: $Path"
    }

    $values = [ordered]@{}
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $Path) {
        $lineNumber++
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith("#")) {
            continue
        }

        if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$') {
            throw "Invalid configuration syntax at $Path line $lineNumber. Use KEY=VALUE."
        }

        $key = $Matches[1]
        if ($values.Contains($key)) {
            throw "Duplicate configuration key '$key' at $Path line $lineNumber."
        }
        $values[$key] = $Matches[2].Trim()
    }
    return $values
}

function Ensure-VibeboxEnv {
    $envPath = Get-VibeboxPath -Name Env
    if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) {
        $example = Get-VibeboxPath -Name EnvExample
        Copy-Item -LiteralPath $example -Destination $envPath
        Write-Verbose "Created $envPath from the committed example."
    }
    return $envPath
}

function ConvertTo-VibeboxBoolean {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)

    switch -Regex ($Value.Trim().ToLowerInvariant()) {
        "^true$" { return $true }
        "^false$" { return $false }
        default { throw "$Name must be true or false, not '$Value'." }
    }
}

function ConvertTo-VibeboxSizeBytes {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Name)

    if ($Value -notmatch '^\s*(\d+(?:\.\d+)?)\s*(B|K|KB|KIB|M|MB|MIB|G|GB|GIB|T|TB|TIB)\s*$') {
        throw "$Name must be a number followed by a supported size unit, not '$Value'."
    }

    $number = [double]$Matches[1]
    $unit = $Matches[2].ToUpperInvariant()
    $multiplier = switch -Regex ($unit) {
        "^B$" { 1 }
        "^K(B|IB)?$" { 1KB }
        "^M(B|IB)?$" { 1MB }
        "^G(B|IB)?$" { 1GB }
        "^T(B|IB)?$" { 1TB }
    }
    return [uint64][math]::Round($number * $multiplier)
}

function ConvertTo-VibeboxList {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }
    return @($Value.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Assert-VibeboxConfig {
    param([Parameter(Mandatory)]$Config)

    $v = $Config.Values
    if ($v.VM_NAME -notmatch '^[a-z][a-z0-9-]{0,62}$') {
        throw "VM_NAME must start with a letter and contain only lowercase letters, numbers, and dashes."
    }
    if ($v.UBUNTU_RELEASE -notmatch '^\d+\.\d+$') {
        throw "UBUNTU_RELEASE must be a release number such as 24.04."
    }
    $cpus = 0
    if (-not [int]::TryParse($v.VM_CPUS, [ref]$cpus) -or $cpus -lt 1) {
        throw "VM_CPUS must be a positive integer."
    }
    $null = ConvertTo-VibeboxSizeBytes -Value $v.VM_MEMORY -Name "VM_MEMORY"
    $null = ConvertTo-VibeboxSizeBytes -Value $v.VM_DISK -Name "VM_DISK"
    $null = ConvertTo-VibeboxBoolean -Value $v.GUEST_UFW -Name "GUEST_UFW"
    if ($v.GUEST_USER -notmatch '^[a-z_][a-z0-9_-]{0,31}$') {
        throw "GUEST_USER must be a valid Linux login name."
    }
    if ($v.GUEST_SHELL -notmatch '^/') {
        throw "GUEST_SHELL must be an absolute path."
    }
    $swap = 0
    if (-not [int]::TryParse($v.GUEST_SWAP_GB, [ref]$swap) -or $swap -lt 0) {
        throw "GUEST_SWAP_GB must be a non-negative integer."
    }
    $node = 0
    if (-not [int]::TryParse($v.NODE_MAJOR, [ref]$node) -or $node -lt 1) {
        throw "NODE_MAJOR must be a positive integer."
    }
    if ($v.TOOLS_UPDATE_POLICY -notin @("latest", "locked")) {
        throw "TOOLS_UPDATE_POLICY must be latest or locked."
    }
    $retention = 0
    if (-not [int]::TryParse($v.BACKUP_RETENTION_DAYS, [ref]$retention) -or $retention -lt 0) {
        throw "BACKUP_RETENTION_DAYS must be a non-negative integer."
    }
    $timeout = 0
    if (-not [int]::TryParse($v.READINESS_TIMEOUT_SEC, [ref]$timeout) -or $timeout -lt 1) {
        throw "READINESS_TIMEOUT_SEC must be a positive integer."
    }

    $allowedOptional = @("agy", "herdr", "rtk", "droid", "hermes", "codeburn", "pi", "codegraph", "gws", "docling", "infisical")
    foreach ($tool in (ConvertTo-VibeboxList $v.TOOLS_OPTIONAL)) {
        if ($tool -notin $allowedOptional) {
            throw "TOOLS_OPTIONAL contains unsupported tool '$tool'."
        }
    }
}

function Get-VibeboxConfig {
    param(
        [hashtable]$Overrides = @{},
        [switch]$CreateIfMissing
    )

    $envPath = Get-VibeboxPath -Name Env
    if ($CreateIfMissing) {
        Ensure-VibeboxEnv | Out-Null
    }

    $defaults = Read-VibeboxKeyValueFile -Path (Get-VibeboxPath -Name EnvExample)
    $declared = [ordered]@{}
    if (Test-Path -LiteralPath $envPath -PathType Leaf) {
        $declared = Read-VibeboxKeyValueFile -Path $envPath
    }

    $values = [ordered]@{}
    $sources = [ordered]@{}
    foreach ($key in $script:VibeboxConfigKeys) {
        if ($Overrides.ContainsKey($key) -and $null -ne $Overrides[$key]) {
            $values[$key] = [string]$Overrides[$key]
            $sources[$key] = "CLI"
        } elseif ($declared.Contains($key)) {
            $values[$key] = [string]$declared[$key]
            $sources[$key] = "vibebox.env"
        } elseif ($defaults.Contains($key)) {
            $values[$key] = [string]$defaults[$key]
            $sources[$key] = "built-in default"
        } else {
            throw "No value is defined for required configuration key '$key'."
        }
    }

    $config = [pscustomobject]@{
        Values = $values
        Sources = $sources
        Declared = $declared
        Path = $envPath
    }
    Assert-VibeboxConfig -Config $config
    return $config
}

function Find-VibeboxSecretConfiguration {
    param([Parameter(Mandatory)]$Config)

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Config.Declared.Keys) {
        $value = [string]$Config.Declared[$key]
        $keyLooksSensitive = $key -match '(?i)(KEY|TOKEN|PASSWORD|SECRET|AUTH|PRIVATE)'
        $valueLooksSensitive = $value -match '(?i)(tskey-|ghp_|github_pat_|sk-[A-Za-z0-9]|AIza|BEGIN (RSA|OPENSSH|EC|PRIVATE) KEY)'
        if ($keyLooksSensitive -or $valueLooksSensitive) {
            $null = $findings.Add($key)
        }
    }
    return @($findings | Select-Object -Unique)
}

function Find-VibeboxGpuConfiguration {
    param([Parameter(Mandatory)]$Config)

    return @($Config.Declared.Keys | Where-Object { $_ -match '(?i)(GPU|CUDA|NVIDIA|DDA|GPU.?PV)' })
}

function Get-VibeboxConfigDisplay {
    param([Parameter(Mandatory)]$Config)

    foreach ($key in $script:VibeboxConfigKeys) {
        [pscustomobject]@{
            Key = $key
            Value = $Config.Values[$key]
            Source = $Config.Sources[$key]
        }
    }
}

function Get-VibeboxConfigOverridesFromArguments {
    param([Parameter(Mandatory)]$Arguments)

    $map = @{
        Name = "VM_NAME"
        Cpus = "VM_CPUS"
        Memory = "VM_MEMORY"
        Disk = "VM_DISK"
        Release = "UBUNTU_RELEASE"
    }
    $overrides = @{}
    foreach ($argument in $map.Keys) {
        if (-not $Arguments.ContainsKey($argument)) {
            continue
        }
        $value = $Arguments[$argument]
        if ($null -eq $value -or ([string]$value).Trim().Length -eq 0) {
            continue
        }
        $overrides[$map[$argument]] = $value
    }
    return $overrides
}
