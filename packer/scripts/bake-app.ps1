<#
  Bakes a smoke-test copy of the application into the image.

  This copy exists ONLY so the image can be validated before it is captured; it is not what runs in the
  test, and /version proves which copy a node is serving. It is built from the source archive the pipeline
  uploaded, never from a developer's working tree.
#>
$ErrorActionPreference = 'Stop'
$log = 'C:\packer\bake.log'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }

$src = 'C:\packer\src'
if (-not (Test-Path $src) -and $env:SOURCE_URL) {
  Log "fetching source archive $env:SOURCE_URL"
  $zip = 'C:\packer\src.zip'
  & gcloud storage cp $env:SOURCE_URL $zip --quiet
  if ($LASTEXITCODE -ne 0) { throw "could not fetch source archive ($LASTEXITCODE)" }
  Expand-Archive -Path $zip -DestinationPath 'C:\packer\src' -Force
  Log "source expanded"
}
if (-not (Test-Path $src)) {
  Log "no source archive present; skipping baked copy (the deployed package still supplies the app)"
  New-Item -ItemType Directory -Force -Path C:\app | Out-Null
  '{"stage":"bake-skipped","detail":"no source archive"}' | Set-Content C:\app\status.json
  exit 0
}

Log "publishing from $src at version $env:APP_VERSION"
$proj = @(
  (Join-Path $src 'WinBuild.SampleApp'),
  (Join-Path $src 'src\WinBuild.SampleApp'),
  (Join-Path $src 'repo\src\WinBuild.SampleApp')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $proj) { Log "no project under $src - skipping baked copy"; exit 0 }
& 'C:\Program Files\dotnet\dotnet.exe' publish $proj `
  -c Release -o 'C:\app\baked' -p:Version=$env:APP_VERSION --nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }
Log "baked copy published to C:\app\baked"
