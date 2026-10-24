<#
  Prove the image can do an MSBuild build of a legacy (non-SDK-style) .NET Framework project.

  `dotnet build` cannot build this project: no SDK, and .NET Framework targeting packs come from Visual Studio.
  So this step uses MSBuild.exe located through vswhere, asserts the output, and records a hash - the same
  discipline as the devenv step, applied to the other toolchain.
#>
$ErrorActionPreference = 'Stop'
$log = 'C:\packer\msbuild.log'
$manifestPath = 'C:\packer\demo-manifest.json'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }

function Add-ManifestEntry($kind, $tool, $artifact, $sha256) {
    $entries = @()
    if (Test-Path $manifestPath) {
        try { $entries = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).builds) } catch { $entries = @() }
    }
    $entries += [pscustomobject]@{ kind = $kind; tool = $tool; artifact = $artifact; sha256 = $sha256; at = (Get-Date).ToString('o') }
    @{ builds = $entries } | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
}

$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'vswhere.exe not found: the image has no Visual Studio toolchain at all' }

$msbuild = (& $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1)
if (-not $msbuild) { throw 'MSBuild.exe not found via vswhere' }
Log "msbuild: $msbuild"
(& $msbuild -version 2>&1 | Select-Object -First 1) | ForEach-Object { Log "  $_" }

$project = 'C:\packer\src\WinBuild.MsBuildDemo\WinBuild.MsBuildDemo.csproj'
if (-not (Test-Path $project)) { throw "demo project not found at $project" }

$buildLog = 'C:\packer\msbuild-build.log'
Log "building $project (Release|AnyCPU) with MSBuild"
& $msbuild $project /p:Configuration=Release /p:Platform=AnyCPU /nologo /v:minimal /fl "/flp:LogFile=$buildLog;Verbosity=minimal"
$exit = $LASTEXITCODE
Log "msbuild exit code: $exit"
if (Test-Path $buildLog) { Get-Content $buildLog -Tail 20 | ForEach-Object { Log "  | $_" } }
if ($exit -ne 0) { throw "MSBuild build failed with exit code $exit (see $buildLog)" }

$exe = 'C:\packer\src\WinBuild.MsBuildDemo\bin\Release\WinBuild.MsBuildDemo.exe'
if (-not (Test-Path $exe)) { throw 'MSBuild reported success but produced no executable' }
$hash = (Get-FileHash -Algorithm SHA256 -Path $exe).Hash.ToLower()
Log "msbuild produced $exe (sha256 $hash)"

# Run it: a build that produces an executable which cannot start is not a working build.
$output = & $exe 2>&1
Log "  output: $(($output | Select-Object -First 1))"
if ($LASTEXITCODE -ne 0) { throw "the built executable failed to run (exit $LASTEXITCODE)" }

Add-ManifestEntry 'msbuild' $msbuild $exe $hash
Log 'msbuild build demonstration passed'
