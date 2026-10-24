# Creates a troubleshooting account and enables RDP for this build machine.
#
# Only runs when the pipeline is dispatched with debug_keep_vm=true. The point is to leave a machine the
# operator can actually log in to after a failed build, without opening RDP to the internet:
#
#   * RDP listens on 3389 but the firewall admits it only from the IAP range (35.235.240.0/20), so the
#     operator connects through `gcloud compute start-iap-tunnel <vm> 3389` — no public port, ever.
#   * The account is a local administrator with a password generated for this build and stored in Secret
#     Manager, never printed into a log.
#   * The machine carries a `ttl` label, so the reaper deletes it whether or not anyone remembers.
#
# Everything here is idempotent: re-running it repairs the state rather than failing.

$ErrorActionPreference = 'Stop'
$log = 'C:\packer\debug-access.log'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }

$user = if ($env:DEBUG_USER) { $env:DEBUG_USER } else { 'packer-debug' }
$password = $env:DEBUG_PASSWORD
if (-not $password) { Log 'debug access not requested (no password supplied) - nothing to do'; exit 0 }

Log "creating troubleshooting account '$user'"

$existing = Get-LocalUser -Name $user -ErrorAction SilentlyContinue
if (-not $existing) {
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    New-LocalUser -Name $user -Password $secure -PasswordNeverExpires -AccountNeverExpires `
        -FullName 'Build troubleshooting account' -Description 'Created by the winbuild pipeline for debugging' | Out-Null
    Log "account created"
} else {
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    Set-LocalUser -Name $user -Password $secure
    Log "account existed; password reset"
}

if (-not (Get-LocalGroupMember -Group 'Administrators' -Member $user -ErrorAction SilentlyContinue)) {
    Add-LocalGroupMember -Group 'Administrators' -Member $user
    Log "added to Administrators"
}

# RDP on, but the rule is scoped to IAP. There is no 0.0.0.0/0 rule in this image and there must never be.
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue | ForEach-Object {
    Set-NetFirewallRule -Name $_.Name -RemoteAddress '35.235.240.0/20' -ErrorAction SilentlyContinue
}
New-NetFirewallRule -DisplayName 'RDP via IAP only' -Direction Inbound -Protocol TCP -LocalPort 3389 `
    -RemoteAddress '35.235.240.0/20' -Action Allow -ErrorAction SilentlyContinue | Out-Null

Set-Service -Name TermService -StartupType Automatic
Start-Service TermService -ErrorAction SilentlyContinue

Log "RDP enabled, limited to 35.235.240.0/20"
Log "connect with: gcloud compute start-iap-tunnel <instance> 3389 --local-host-port=localhost:13389 --zone=<zone>"
