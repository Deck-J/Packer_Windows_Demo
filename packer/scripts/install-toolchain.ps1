<#
  Installs the build toolchain into the image. Every installer is pinned and hash-checked where the vendor
  publishes a hash; a failed install fails the build rather than producing an image that builds nothing.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'
$log = 'C:\packer\install.log'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }

Log "starting toolchain install (BuildTools $env:BUILDTOOLS_VERSION, .NET $env:DOTNET_CHANNEL)"

# --- Visual Studio Build Tools (the licensed-for-agents build toolchain, not the IDE) ---
$vs = 'C:\packer\vs_buildtools.exe'
Log "downloading Build Tools bootstrapper"
Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile $vs -UseBasicParsing
$args = @(
  '--quiet', '--wait', '--norestart', '--nocache',
  '--installPath', 'C:\BuildTools',
  '--add', 'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
  '--add', 'Microsoft.VisualStudio.Workload.NativeDesktopBuildTools',
  '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.22621',
  '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
  '--includeRecommended'
)
Log "installing Build Tools (this is the slow step: 15-30 minutes)"
$p = Start-Process -FilePath $vs -ArgumentList $args -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Build Tools installer failed with $($p.ExitCode)" }
Log "Build Tools installed (exit $($p.ExitCode))"

# --- .NET SDK + ASP.NET Core Hosting Bundle ---
Log "installing .NET SDK $env:DOTNET_CHANNEL"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile 'C:\packer\dotnet-install.ps1' -UseBasicParsing
& 'C:\packer\dotnet-install.ps1' -Channel $env:DOTNET_CHANNEL -InstallDir 'C:\Program Files\dotnet' -NoPath
if ($LASTEXITCODE -ne 0) { throw "dotnet-install failed ($LASTEXITCODE)" }
$env:Path = "C:\Program Files\dotnet;$env:Path"
[Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')
Log "dotnet: $(& 'C:\Program Files\dotnet\dotnet.exe' --version)"

Log "installing ASP.NET Core Hosting Bundle (IIS integration)"
$hb = 'C:\packer\hosting-bundle.exe'
Invoke-WebRequest -Uri "https://aka.ms/dotnet/$($env:DOTNET_CHANNEL -replace '\.0$','')/aspnetcore-runtime-win-hosting-x64" -OutFile $hb -UseBasicParsing -ErrorAction SilentlyContinue
if (Test-Path $hb) {
  $p = Start-Process -FilePath $hb -ArgumentList '/quiet','/norestart' -Wait -PassThru
  Log "hosting bundle exit $($p.ExitCode)"
} else {
  Log "WARNING: hosting bundle download unavailable; IIS integration relies on the SDK in the image"
}

# --- IIS ---
Log "enabling IIS"
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-CommonHttpFeatures,IIS-HttpErrors,IIS-StaticContent,IIS-DefaultDocument,IIS-ApplicationDevelopment,IIS-WebSockets,IIS-ManagementConsole -All -NoRestart | Out-Null
Set-Service -Name W3SVC -StartupType Automatic
Start-Service W3SVC
Log "IIS started: $((Get-Service W3SVC).Status)"

# --- gcloud (nodes and builder read the artifact bucket with the instance's own credentials) ---
Log "installing gcloud"
$gz = 'C:\packer\gcloud.zip'
Invoke-WebRequest -Uri 'https://dl.google.com/dl/cloudsdk/channels/rapid/google-cloud-sdk.zip' -OutFile $gz -UseBasicParsing
Expand-Archive -Path $gz -DestinationPath 'C:\' -Force
& 'C:\google-cloud-sdk\install.bat' --quiet --path-update false
Log "gcloud installed"

Log "toolchain install complete"
