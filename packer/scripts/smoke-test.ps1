<#
  Prove the image can serve before it is captured. A Node that cannot answer /healthz here would ship an
  image whose only symptom is a load balancer that never goes healthy.
#>
$ErrorActionPreference = 'Stop'
$baked = 'C:\app\baked'
if (-not (Test-Path $baked)) { Write-Output 'no baked app: smoke test skipped (image is a toolchain base)'; exit 0 }

Import-Module WebAdministration
if (-not (Get-WebAppPool -Name 'WinBuildApp' -ErrorAction SilentlyContinue)) {
  New-WebAppPool -Name 'WinBuildApp' | Out-Null
}
if (-not (Get-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue)) {
  New-Website -Name 'WinBuildApp' -PhysicalPath $baked -Port 80 -ApplicationPool 'WinBuildApp' | Out-Null
}
Set-ItemProperty 'IIS:\Sites\WinBuildApp' -Name physicalPath -Value $baked
Start-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue
Start-Service W3SVC -ErrorAction SilentlyContinue

$ok = $false
for ($i = 1; $i -le 30; $i++) {
  try {
    $r = Invoke-WebRequest -Uri 'http://localhost/healthz' -UseBasicParsing -TimeoutSec 5
    if ($r.StatusCode -eq 200) { $ok = $true; break }
  } catch { Start-Sleep -Seconds 2 }
}
if (-not $ok) { throw '/healthz did not answer 200 on the baked copy' }
Write-Output "smoke test passed: $(Invoke-WebRequest -Uri 'http://localhost/version' -UseBasicParsing).Content"

# Leave the site stopped: the image is a template, and each node configures its own site at boot.
Stop-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue
