<#
  The test entrypoint: one command, two phases.

    build   on the builder, after the site is configured  ->  unit tests + IIS config + app contract on localhost
    deploy  from the runner, against the LB address       ->  app contract + distribution across nodes

  Exits non-zero if any check fails, so the image build fails or the pipeline's verify job fails.
#>
param(
    [ValidateSet('build', 'deploy')] [string] $Phase = 'build',
    [string] $BaseUrl = 'http://localhost',
    [string] $ExpectedVersion = '',
    [switch] $SkipUnitTests
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'Assert.ps1')

Write-Output "=== validation phase: $Phase (base: $BaseUrl) ==="

if ($Phase -eq 'build' -and -not $SkipUnitTests) {
    $testProject = 'C:\packer\src\WinBuild.SampleApp.Tests'
    if (Test-Path $testProject) {
        Write-Output 'unit tests'
        & dotnet test $testProject -c Release --nologo --logger 'console;verbosity=minimal'
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Because 'the unit test suite must pass'
    } else {
        Write-Output "no unit test project at $testProject - skipping"
    }
}

# Every *.Tests.ps1 in this folder is part of the suite; the filename prefix is the order.
Get-ChildItem -Path $here -Filter '*.Tests.ps1' | Sort-Object Name | ForEach-Object {
    Write-Output ""
    . $_.FullName -Phase $Phase -BaseUrl $BaseUrl -ExpectedVersion $ExpectedVersion
}

Assert-NoFailures -Phase $Phase
