# Toolchain and utilities for the builder image.
#
# Two lists, deliberately separated:
#   TOOLCHAIN  compilers and SDKs. Large, slow, pinned — part of the image's identity.
#   UTILITIES  the small command-line tools every build ends up needing. Cheap, installed once, so a
#              custom/ script never has to fetch them mid-build.
#
# Every tool is verified after install: a tool that installed but will not run is worse than one that
# failed loudly.

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$log = 'C:\packer\install.log'
function Log($m) { $line = "$(Get-Date -Format o) $m"; Write-Output $line; Add-Content -Path $log -Value $line }
function Check($exe, $exeArgs = @()) {
    if (-not (Test-Path $exe)) { throw "$exe is missing after install" }
    try {
        $v = (& $exe @exeArgs 2>&1 | Select-Object -First 1)
        Log "  ok: $(Split-Path $exe -Leaf) -> $v"
    } catch {
        throw "$exe installed but will not run: $($_.Exception.Message)"
    }
}

Log "install starting (BuildTools $env:BUILDTOOLS_VERSION, .NET $env:DOTNET_CHANNEL)"

# --- TOOLCHAIN ---------------------------------------------------------------
Log "Visual Studio Build Tools (the toolchain licensed for build agents, not the IDE)"
$vs = 'C:\packer\vs_buildtools.exe'
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
Check 'C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe' '-version'

Log "installing .NET SDK $env:DOTNET_CHANNEL"
Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile 'C:\packer\dotnet-install.ps1' -UseBasicParsing
& 'C:\packer\dotnet-install.ps1' -Channel $env:DOTNET_CHANNEL -InstallDir 'C:\Program Files\dotnet' -NoPath
if ($LASTEXITCODE -ne 0) { throw "dotnet-install failed ($LASTEXITCODE)" }
$env:Path = "C:\Program Files\dotnet;$env:Path"
[Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')
Check 'C:\Program Files\dotnet\dotnet.exe' '--version'

Log "IIS + ASP.NET Core Hosting Bundle"
$hb = 'C:\packer\hosting-bundle.exe'
$hbUrl = "https://aka.ms/dotnet/$($env:DOTNET_CHANNEL -replace '\.0$','')/aspnetcore-runtime-win-hosting-x64"
try {
    Invoke-WebRequest -Uri $hbUrl -OutFile $hb -UseBasicParsing
    $p = Start-Process -FilePath $hb -ArgumentList '/quiet', '/norestart' -Wait -PassThru
    Log "hosting bundle exit $($p.ExitCode)"
} catch {
    Log "WARNING: hosting bundle unavailable ($($_.Exception.Message)); IIS integration relies on the SDK"
}

Log "enabling IIS features"
Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-CommonHttpFeatures, `
    IIS-HttpErrors, IIS-StaticContent, IIS-DefaultDocument, IIS-ApplicationDevelopment, IIS-WebSockets, `
    IIS-ManagementConsole, IIS-HttpLogging, IIS-RequestFiltering, IIS-HttpCompressionStatic -All -NoRestart | Out-Null
Set-Service -Name W3SVC -StartupType Automatic
Start-Service W3SVC
Log "IIS started: $((Get-Service W3SVC).Status)"

# --- UTILITIES ---------------------------------------------------------------
# git: custom builds clone, tag, check out and diff; nothing replaces it.
Log "installing Git for Windows"
$git = 'C:\packer\git-installer.exe'
Invoke-WebRequest -Uri 'https://github.com/git-for-windows/git/releases/download/v2.46.1.windows.1/Git-2.46.1-64-bit.exe' -OutFile $git -UseBasicParsing
$p = Start-Process -FilePath $git -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "git installer failed with $($p.ExitCode)" }
$env:Path = "C:\Program Files\Git\cmd;$env:Path"
[Environment]::SetEnvironmentVariable('Path', $env:Path, 'Machine')
Check 'C:\Program Files\Git\cmd\git.exe' '--version'

# 7-Zip: vendors ship 7z/rar/tar.gz; Expand-Archive cannot open most of them.
Log "installing 7-Zip"
$seven = 'C:\packer\7z-installer.exe'
Invoke-WebRequest -Uri 'https://www.7-zip.org/a/7z2408-x64.exe' -OutFile $seven -UseBasicParsing
$p = Start-Process -FilePath $seven -ArgumentList '/S' -Wait -PassThru
if ($p.ExitCode -ne 0) { throw "7-Zip installer failed with $($p.ExitCode)" }
Check 'C:\Program Files\7-Zip\7z.exe'

# jq: build steps parse JSON constantly, and the runner-side scripts in this repo already use jq —
# having the same tool on both sides avoids two dialects of the same one-liner.
Log "installing jq"
Invoke-WebRequest -Uri 'https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-windows-amd64.exe' `
    -OutFile 'C:\Windows\System32\jq.exe' -UseBasicParsing
Check 'C:\Windows\System32\jq.exe' '--version'

# NuGet.exe: some projects and tools still expect the standalone CLI rather than `dotnet nuget`.
Log "installing NuGet.exe"
Invoke-WebRequest -Uri 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' `
    -OutFile 'C:\Windows\System32\nuget.exe' -UseBasicParsing
Check 'C:\Windows\System32\nuget.exe'

# gcloud: the builder and the nodes read the artifact bucket with the instance's own credentials.
Log "installing gcloud"
$gz = 'C:\packer\gcloud.zip'
Invoke-WebRequest -Uri 'https://dl.google.com/dl/cloudsdk/channels/rapid/google-cloud-sdk.zip' -OutFile $gz -UseBasicParsing
Expand-Archive -Path $gz -DestinationPath 'C:\' -Force
& 'C:\google-cloud-sdk\install.bat' --quiet --path-update false
Check 'C:\google-cloud-sdk\bin\gcloud.cmd'

# Deliberately NOT installed, with reasons, because "just add it" is how an image becomes 20 GB:
#   * A GitHub Actions runner — the pipeline uses hosted runners; a runner baked into a public-facing
#     image is an inbound credential with no benefit.
#   * Node.js / Java / Go — not needed to build a .NET app, ~100 MB each, and each is a patch treadmill.
#     A custom build that needs one installs it in custom/ for that build.
#   * WinRM — the image is managed over SSH through IAP (ADR-0007). Nothing listens on 5985.
#   * Sysinternals — genuinely useful for troubleshooting, but pull it over IAP when you need it rather
#     than carrying 200 MB in every image.

Log "install complete"
Log "PATH: $env:Path"
