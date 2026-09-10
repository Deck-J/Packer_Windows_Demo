[CmdletBinding()]
param (
  [int]$Port = 8080,
  [string]$InstallDirectory = "C:\WorkerDemo",
  [string]$ApplicationName = "WorkerDemo",
  [int]$StartupTimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"

function Assert-Condition {
  param (
    [bool]$Condition,
    [string]$Description
  )

  if (-not $Condition) {
    throw "Post-install check failed: $Description"
  }

  Write-Output "PASS: $Description"
}

function Assert-HttpEndpoint {
  param (
    [string]$Uri,
    [string]$Description,
    [scriptblock]$AssertResponse
  )

  $deadline = (Get-Date).AddSeconds($StartupTimeoutSeconds)
  $response = $null
  do {
    try {
      $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing
      break
    }
    catch {
      if ((Get-Date) -ge $deadline) {
        throw "Post-install check failed: $Description was not reachable at $Uri. $($_.Exception.Message)"
      }
      Start-Sleep -Seconds 2
    }
  } while ((Get-Date) -lt $deadline)

  if ($null -eq $response) {
    throw "Post-install check failed: $Description did not return a response from $Uri"
  }

  Assert-Condition ($response.StatusCode -eq 200) "$Description returned HTTP $($response.StatusCode)"
  & $AssertResponse $response
}

$applicationPath = Join-Path $InstallDirectory "$ApplicationName.dll"
Assert-Condition (Test-Path -LiteralPath $applicationPath) "application binary exists at $applicationPath"

$iisService = Get-Service -Name W3SVC -ErrorAction SilentlyContinue
Assert-Condition ($null -ne $iisService -and $iisService.Status -eq "Running") "IIS service W3SVC is running"

$sshService = Get-Service -Name sshd -ErrorAction SilentlyContinue
Assert-Condition ($null -ne $sshService -and $sshService.Status -eq "Running") "OpenSSH service sshd is running"

$applicationProcess = Get-CimInstance Win32_Process -Filter "Name = 'dotnet.exe'" |
  Where-Object { $_.CommandLine -like "*$ApplicationName.dll*" }
Assert-Condition ($null -ne $applicationProcess) "$ApplicationName .NET process is running"

$baseUri = "http://127.0.0.1:$Port"
Assert-HttpEndpoint -Uri "$baseUri/health" -Description "local health endpoint" -AssertResponse {
  param ($response)
  $health = $response.Content | ConvertFrom-Json
  Assert-Condition ($health.status -eq "healthy") "local health endpoint reports healthy"
}

Assert-HttpEndpoint -Uri "$baseUri/" -Description "local application endpoint" -AssertResponse {
  param ($response)
  $details = $response.Content | ConvertFrom-Json
  Assert-Condition ($details.application -eq "Windows Worker Demo") "local application identifies itself"
  Assert-Condition ($details.status -eq "healthy") "local application reports healthy"
}

Write-Output "Post-install checks completed successfully"
