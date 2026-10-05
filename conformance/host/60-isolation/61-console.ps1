param([Parameter(Mandatory)][string]$Name)
$ErrorActionPreference = "Stop"
if ($null -eq (Get-Command vmconnect.exe -ErrorAction SilentlyContinue)) {
    Write-Output "skip 61-console - vmconnect.exe is not available in this shell"
    [Console]::Error.WriteLine("Install the Hyper-V management tools to test the rescue console.")
    exit 77
}
Write-Output "skip 61-console - interactive console proof requires a human login prompt"
[Console]::Error.WriteLine("Run vmconnect.exe localhost $Name with sshd stopped and record the result.")
exit 77
