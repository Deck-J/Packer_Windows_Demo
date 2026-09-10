<#
.SYNOPSIS
  Verifies that the Windows golden image contains all required build tools.

.DESCRIPTION
  This script runs inside the temporary Packer builder after provisioning.
  Any failed check stops the build, preventing an incomplete image from being
  published. It does not register the GitHub Actions runner or contact GitHub.
#>

$ErrorActionPreference = "Stop"

function Assert-Path {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Self-test failed: $Description was not found at $Path"
  }

  Write-Output "PASS: $Description"
}

function Assert-Command {
  param (
    [Parameter(Mandatory = $true)]
    [string]$Command,

    [Parameter(Mandatory = $true)]
    [string]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $commandInfo = Get-Command $Command -ErrorAction SilentlyContinue
  if ($null -eq $commandInfo) {
    throw "Self-test failed: $Description command '$Command' is not available"
  }

  & $commandInfo.Source $Arguments.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
  if ($LASTEXITCODE -ne 0) {
    throw "Self-test failed: $Description returned exit code $LASTEXITCODE"
  }

  Write-Output "PASS: $Description"
}

$iisService = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
if ($null -eq $iisService -or $iisService.Status -ne "Running") {
  throw "Self-test failed: IIS service W3SVC is not running"
}
Write-Output "PASS: IIS service is running"

Assert-Path `
  -Path "C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe" `
  -Description "MSBuild"

Assert-Path `
  -Path "C:\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe" `
  -Description "C# Roslyn compiler"

Assert-Path `
  -Path "C:\actions-runner\config.cmd" `
  -Description "GitHub Actions runner"

Assert-Command `
  -Command "dotnet" `
  -Arguments "--version" `
  -Description ".NET SDK"

& "C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe" -version
if ($LASTEXITCODE -ne 0) {
  throw "Self-test failed: MSBuild returned exit code $LASTEXITCODE"
}
Write-Output "PASS: MSBuild starts successfully"

Write-Output "Windows image self-tests completed successfully"
