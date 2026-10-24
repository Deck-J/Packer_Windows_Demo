<#
  Step 4: prove the site actually serves before the image is captured.
  A build that compiles but cannot answer /healthz produces an image whose only symptom is a load
  balancer that never goes healthy — which is much harder to diagnose than a failed build.
#>
$ErrorActionPreference = 'Stop'
$base = 'http://localhost'
$deadline = (Get-Date).AddSeconds(120)
$ok = $false

while ((Get-Date) -lt $deadline) {
    try {
        $r = Invoke-WebRequest -Uri "$base/healthz" -UseBasicParsing -TimeoutSec 5
        if ($r.StatusCode -eq 200 -and $r.Content.Trim() -eq 'ok') { $ok = $true; break }
    } catch {
        Start-Sleep -Seconds 3
    }
}
if (-not $ok) {
    $log = 'C:\app\custom\logs\stdout'
    if (Test-Path $log) { Get-Content $log -Tail 40 | Write-Output }
    throw '/healthz never returned ok'
}

$version = (Invoke-WebRequest -Uri "$base/version" -UseBasicParsing).Content.Trim()
$servedBy = (Invoke-WebRequest -Uri "$base/healthz" -UseBasicParsing).Headers['X-Served-By']
Write-Output "healthz ok; /version = $version; X-Served-By = $servedBy"
Write-Output "custom build verified"
