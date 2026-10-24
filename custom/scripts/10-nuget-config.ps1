<#
  Step 1 of the custom build: give the build its NuGet configuration.
  Public feed always; the private GitHub Packages feed only when a token was supplied (never in this repo).
#>
$ErrorActionPreference = 'Stop'
$configPath = 'C:\packer\custom\NuGet.Config'
$owner = $env:GITHUB_REPOSITORY_OWNER

$sources = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" protocolVersion="3" />
"@

if ($owner) {
    Write-Output "adding GitHub Packages source for $owner"
    $sources += "    <add key=`"github`" value=`"https://nuget.pkg.github.com/$owner/index.json`" protocolVersion=`"3`" />`n"
} else {
    Write-Output "GITHUB_REPOSITORY_OWNER not set: public feed only"
}

$sources += @"
  </packageSources>
  <config>
    <add key="globalPackagesFolder" value="C:\packer\.nuget\packages" />
  </config>
</configuration>
"@

Set-Content -Path $configPath -Value $sources -Encoding UTF8
Write-Output "wrote $configPath"
