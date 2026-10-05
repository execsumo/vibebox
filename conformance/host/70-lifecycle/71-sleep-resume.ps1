param([Parameter(Mandatory)][string]$Name)
Write-Output "skip 71-sleep-resume - host sleep/resume is user-controlled and cannot be safely automated"
[Console]::Error.WriteLine("Run the documented sleep/resume cycle and attach its clock, Tailscale, and SSH evidence.")
exit 77
