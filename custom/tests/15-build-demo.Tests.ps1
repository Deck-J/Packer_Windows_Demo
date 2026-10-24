<#
  Assert that the image really did both builds.

  custom/scripts/26-msbuild-demo.ps1 and 25-devenv-build.ps1 each append to C:\packer\demo-manifest.json with
  the tool path and the artefact hash. This test reads that file, so "the image can build both ways" is a
  checked claim rather than two log lines nobody reads.

  Build phase only: the manifest lives in the image.
#>
param(
    [ValidateSet('build', 'deploy')] [string] $Phase = 'build',
    [string] $BaseUrl = 'http://localhost',
    [string] $ExpectedVersion = ''
)

if ($Phase -ne 'build') {
    Write-Output 'build-demo: skipped outside the build phase (the manifest lives in the image)'
    return
}

$manifestPath = 'C:\packer\demo-manifest.json'
Assert-True -Condition (Test-Path $manifestPath) -Because 'both demo builds must record themselves in demo-manifest.json'
if (-not (Test-Path $manifestPath)) { return }

$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$kinds = @($manifest.builds | ForEach-Object { $_.kind })
Write-Output "  recorded builds: $($kinds -join ', ')"

Assert-True -Condition ($kinds -contains 'msbuild') -Because 'an MSBuild (non-dotnet) build must have run'
Assert-True -Condition ($kinds -contains 'devenv') -Because 'a devenv (IDE) build must have run'

foreach ($entry in $manifest.builds) {
    Assert-True -Condition (Test-Path $entry.artifact) -Because "$($entry.kind) artefact must still exist at $($entry.artifact)"
    if (Test-Path $entry.artifact) {
        $actual = (Get-FileHash -Algorithm SHA256 -Path $entry.artifact).Hash.ToLower()
        Assert-Equal -Actual $actual -Expected $entry.sha256 -Because "$($entry.kind) artefact must be the file that was built"
    }
}
