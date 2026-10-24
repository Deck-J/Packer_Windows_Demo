<#
  Step 2: restore, build and publish the application.
  Warnings are errors, and the version comes from the pipeline so /version can be asserted later.
#>
$ErrorActionPreference = 'Stop'
$src = 'C:\packer\src\src\WinBuild.SampleApp'
$out = 'C:\app\custom'
$version = if ($env:APP_VERSION) { $env:APP_VERSION } else { '0.0.0-local' }
$nuget = 'C:\packer\custom\NuGet.Config'

if (-not (Test-Path $src)) { throw "source not found at $src" }
New-Item -ItemType Directory -Force -Path $out | Out-Null

Write-Output "restore for $version"
& dotnet restore $src --configfile $nuget --nologo
if ($LASTEXITCODE -ne 0) { throw "restore failed ($LASTEXITCODE)" }

Write-Output "build (warnings as errors)"
& dotnet build $src -c Release --no-restore --nologo -warnaserror -p:Version=$version
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

Write-Output "publish to $out"
& dotnet publish $src -c Release --no-build --nologo -o $out -p:Version=$version
if ($LASTEXITCODE -ne 0) { throw "publish failed ($LASTEXITCODE)" }

if (-not (Test-Path (Join-Path $out 'WinBuild.SampleApp.dll'))) { throw 'publish produced no assembly' }
Write-Output "built $version into $out"
