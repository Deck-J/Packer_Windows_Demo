<#
.SYNOPSIS
  Prepares a Windows Server 2022 VM to become the golden image build runner.

.DESCRIPTION
  This script runs during the Packer build and installs the software required
  by the image pipeline:

  * IIS with ASP.NET and IIS management tools for web workloads.
  * Visual Studio 2022 Build Tools, MSBuild, C++ tools, and the .NET runtime.
  * The .NET 8 SDK for compiling modern .NET applications.
  * The latest x64 GitHub Actions runner binaries.

  The runner binaries are installed but not registered with GitHub. Runner
  registration requires a short-lived token and must happen when an instance
  is launched, rather than while the reusable image is being built.

  Downloaded installers are stored temporarily in C:\ImageBuild and removed
  before the image is finalized. IIS is configured to start automatically.

.NOTES
  This script must run with Administrator privileges on Windows Server 2022.
  It requires outbound HTTPS access to aka.ms, dot.net, and api.github.com.
  The commands are intentionally non-interactive so Packer can run them.

.OUTPUTS
  A Windows image containing IIS, Visual Studio Build Tools, the .NET 8 SDK,
  and GitHub Actions runner binaries under C:\actions-runner.
#>

$ErrorActionPreference = "Stop"

# Stop immediately if any installation or download fails. A partially
# provisioned image should never be published as a golden image.

#region IIS
# Install IIS and its ASP.NET and management components for web workloads.
Install-WindowsFeature -Name Web-Server, Web-Asp-Net45, Web-Mgmt-Tools
#endregion

#region Temporary workspace
# Keep downloaded installers in a disposable workspace that is removed at the end.
$workDir = "C:\ImageBuild"
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
#endregion

#region Visual Studio Build Tools
# Install the Visual Studio workloads required to compile C#, VB, and native code.
$vsBootstrapper = Join-Path $workDir "vs_buildtools.exe"
Invoke-WebRequest -Uri "https://aka.ms/vs/17/release/vs_buildtools.exe" -OutFile $vsBootstrapper
Start-Process -FilePath $vsBootstrapper -Wait -ArgumentList @(
  "--quiet", "--wait", "--norestart",
  "--installPath", "C:\BuildTools",
  "--add", "Microsoft.VisualStudio.Workload.MSBuildTools",
  "--add", "Microsoft.VisualStudio.Workload.VCTools",
  "--add", "Microsoft.NetCore.Component.Runtime.8.0"
)
#endregion

#region .NET SDK
# Install the .NET 8 SDK so the image can build modern .NET applications.
$dotnetInstaller = Join-Path $workDir "dotnet-install.ps1"
Invoke-WebRequest -Uri "https://dot.net/v1/dotnet-install.ps1" -OutFile $dotnetInstaller
& $dotnetInstaller -Channel 8.0 -InstallDir "C:\Program Files\dotnet"
#endregion

#region GitHub Actions runner binaries
# Install the latest x64 GitHub Actions runner binaries without registering a runner.
# Registration is intentionally deferred until a workflow starts on a hosted instance.
$runnerDir = "C:\actions-runner"
New-Item -ItemType Directory -Path $runnerDir -Force | Out-Null
$runnerZip = Join-Path $workDir "actions-runner.zip"
$runnerRelease = Invoke-RestMethod -Uri "https://api.github.com/repos/actions/runner/releases/latest"
$runnerAsset = $runnerRelease.assets | Where-Object { $_.name -eq "actions-runner-win-x64.zip" } | Select-Object -First 1
Invoke-WebRequest -Uri $runnerAsset.browser_download_url -OutFile $runnerZip
Expand-Archive -Path $runnerZip -DestinationPath $runnerDir -Force
#endregion

#region Image cleanup and services
# Remove installer artifacts and ensure IIS starts automatically in derived instances.
Remove-Item $workDir -Recurse -Force
Set-Service -Name W3SVC -StartupType Automatic
Start-Service -Name W3SVC
#endregion
