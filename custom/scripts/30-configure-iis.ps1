<#
  Step 3: configure IIS for the published application.

  This is the part that is genuinely site-specific and therefore belongs in custom/, not in the image:
  the app pool identity, the environment the app sees, request limits, and where the logs go.
#>
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration

$site = 'WinBuildApp'
$pool = 'WinBuildApp'
$path = 'C:\app\custom'
$port = 80

if (-not (Get-WebAppPool -Name $pool -ErrorAction SilentlyContinue)) {
    New-WebAppPool -Name $pool | Out-Null
    Write-Output "created app pool $pool"
}
# .NET Core runs out-of-process behind the ASP.NET Core Module: "No Managed Code" is correct here.
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value ''
Set-ItemProperty "IIS:\AppPools\$pool" -Name processModel.identityType -Value ApplicationPoolIdentity
Set-ItemProperty "IIS:\AppPools\$pool" -Name recycling.periodicRestart.time -Value '00:00:00'

if (-not (Get-Website -Name $site -ErrorAction SilentlyContinue)) {
    New-Website -Name $site -PhysicalPath $path -Port $port -ApplicationPool $pool | Out-Null
    Write-Output "created site $site on port $port"
}
Set-ItemProperty "IIS:\Sites\$site" -Name physicalPath -Value $path
Set-ItemProperty "IIS:\Sites\$site" -Name applicationPool -Value $pool

# Environment for the app, provided through the ASP.NET Core Module rather than machine-wide.
$webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <handlers>
      <add name="aspNetCore" path="*" verb="*" modules="AspNetCoreModuleV2" resourceType="Unspecified" />
    </handlers>
    <aspNetCore processPath="dotnet" arguments=".\WinBuild.SampleApp.dll" stdoutLogEnabled="true"
                stdoutLogFile=".\logs\stdout" hostingModel="outofprocess">
      <environmentVariables>
        <environmentVariable name="ASPNETCORE_ENVIRONMENT" value="Production" />
        <environmentVariable name="ASPNETCORE_URLS" value="http://localhost:$port" />
        <environmentVariable name="APP_BUILD_SOURCE" value="image-bake" />
      </environmentVariables>
    </aspNetCore>
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
      </customHeaders>
    </httpProtocol>
  </system.webServer>
</configuration>
"@
Set-Content -Path (Join-Path $path 'web.config') -Value $webConfig -Encoding UTF8
New-Item -ItemType Directory -Force -Path (Join-Path $path 'logs') | Out-Null

Start-WebAppPool -Name $pool -ErrorAction SilentlyContinue
Start-Website -Name $site -ErrorAction SilentlyContinue
Write-Output "IIS configured: $site -> $path, pool $pool, env Production"
