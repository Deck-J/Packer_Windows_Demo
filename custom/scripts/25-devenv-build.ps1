<#
  Prove the image can build with devenv, not just MSBuild.

  MSBuild and `dotnet` cover ordinary projects; devenv is what you need for project types whose build targets
  live inside the IDE - .vdproj installers, SSDT/SSRS, VSTO/Office add-ins. This step locates devenv, builds the
  solution with it, and asserts the artefacts - so "the image can do a devenv build" is a log line and a file,
  not a claim in a README.

  Behaviour by image:
    full IDE (vs_edition != buildtools)  -> devenv build runs, artefacts asserted, exit code enforced
    Build Tools only                     -> says so and skips, rather than failing a build that never asked
                                            for the IDE
#>
$ErrorActionPreference = 'Stop'
$log = 'C:\packer\devenv.log'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }

# Locate the IDE with vswhere, which is present even in Build Tools images.
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$devenv = $null
if (Test-Path $vswhere) {
    $installPath = (& $vswhere -latest -products * -property installationPath 2>$null | Select-Object -First 1)
    if ($installPath) {
        $candidate = Join-Path $installPath 'Common7\IDE\devenv.com'
        if (Test-Path $candidate) { $devenv = $candidate }
    }
}

if (-not $devenv) {
    Log 'devenv not present in this image (Build Tools): skipping the IDE build demonstration'
    Log 'set vs_edition=community|professional|enterprise to run this step for real'
    exit 0
}

Log "devenv: $devenv"
(& $devenv /? 2>&1 | Select-Object -First 2) | ForEach-Object { Log "  $_" }

$solution = 'C:\packer\src\WinBuild.Demo.sln' 
if (-not (Test-Path $solution)) { throw "solution not found at $solution" }

$buildLog = 'C:\packer\devenv-build.log'
Log "building $solution with devenv (Release|x64)"
& $devenv $solution /Build 'Release|x64' /Out $buildLog
$exit = $LASTEXITCODE
Log "devenv exit code: $exit"

if (Test-Path $buildLog) {
    Get-Content $buildLog -Tail 25 | ForEach-Object { Log "  | $_" }
}
if ($exit -ne 0) { throw "devenv build failed with exit code $exit (see $buildLog)" }

# Assert the artefact, not just the exit code.
$exe = 'C:\packer\src\WinBuild.MsBuildDemo\bin\Release\WinBuild.MsBuildDemo.exe'
if (-not (Test-Path $exe)) { throw "devenv reported success but produced no executable" }
$hash = (Get-FileHash -Algorithm SHA256 -Path $exe).Hash.ToLower()
Log "devenv produced $exe (sha256 $hash)"

# Record it beside the MSBuild result, so the pipeline can show both toolchains in one place.
$manifestPath = 'C:\packer\demo-manifest.json'
$entries = @()
if (Test-Path $manifestPath) {
    try { $entries = @((Get-Content $manifestPath -Raw | ConvertFrom-Json).builds) } catch { $entries = @() }
}
$entries += [pscustomobject]@{ kind = 'devenv'; tool = $devenv; artifact = $exe; sha256 = $hash; at = (Get-Date).ToString('o') }
@{ builds = $entries } | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8

Log 'devenv build demonstration passed'
