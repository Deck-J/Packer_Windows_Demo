<#
  Configuration checks that only make sense on the builder, where IIS and the published files exist.
  In the deploy phase the node is treated as a black box: the app contract is all we assert, because
  inspecting a node's IIS from the runner would require access the pipeline deliberately does not have.
#>
param(
    [ValidateSet('build', 'deploy')] [string] $Phase = 'build',
    [string] $BaseUrl = 'http://localhost',
    [string] $ExpectedVersion = ''
)

if ($Phase -ne 'build') {
    Write-Output 'iis-config: skipped outside the build phase'
    return
}

Write-Output 'iis configuration'

try {
    Import-Module WebAdministration -ErrorAction Stop
    $module = $true
} catch {
    $module = $false
}
Assert-True -Condition $module -Because 'the WebAdministration module must be present in the image'
if (-not $module) { return }

$site = Get-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue
Assert-True -Condition ($null -ne $site) -Because 'the WinBuildApp site must exist'
if ($site) {
    Assert-Equal -Actual $site.State -Expected 'Started' -Because 'the site must be running'
    Assert-Equal -Actual $site.physicalPath -Expected 'C:\app\custom' -Because 'the site must serve the published output'
    Assert-Equal -Actual $site.applicationPool -Expected 'WinBuildApp' -Because 'the site must use its own app pool'
}

$pool = Get-WebAppPool -Name 'WinBuildApp' -ErrorAction SilentlyContinue
Assert-True -Condition ($null -ne $pool) -Because 'the WinBuildApp app pool must exist'
if ($pool) {
    Assert-Equal -Actual $pool.managedRuntimeVersion -Expected '' -Because 'the pool must be No Managed Code for ASP.NET Core'
    Assert-Equal -Actual $pool.processModel.identityType -Expected 'ApplicationPoolIdentity' -Because 'the pool must not run as a privileged account'
}

$webConfig = 'C:\app\custom\web.config'
Assert-True -Condition (Test-Path $webConfig) -Because 'web.config must be present in the published output'
if (Test-Path $webConfig) {
    try {
        [xml]$xml = Get-Content $webConfig -Raw
        Assert-Equal -Actual $xml.configuration.'system.webServer'.aspNetCore.hostingModel -Expected 'outofprocess' -Because 'hosting must be out-of-process'
        Assert-True -Condition ($null -ne $xml.configuration.'system.webServer'.aspNetCore.environmentVariables) -Because 'the app environment must be declared in web.config'
    } catch {
        Assert-True -Condition $false -Because "web.config must parse as XML: $($_.Exception.Message)"
    }
}

Assert-True -Condition (Test-Path 'C:\app\custom\logs') -Because 'the stdout log directory must exist before anything tries to write to it'
