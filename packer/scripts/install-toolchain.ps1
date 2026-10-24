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

Log "install starting (VS edition $env:VS_EDITION, .NET $env:DOTNET_CHANNEL)"

# --- TOOLCHAIN ---------------------------------------------------------------
# Visual Studio: Build Tools by default, the full IDE when a project genuinely needs it.
#
# Build Tools covers almost everything a build server does - MSBuild, the Windows SDK, the compiler - and is
# the correct licence for an unattended agent. Some project types are only buildable with the IDE installed
# because their MSBuild tasks or workloads ship with Visual Studio itself or with a VSIX extension:
#   * UWP / WinUI, MAUI (Android/iOS), Office and VSTO add-ins, SSDT/SSIS/SSRS, Windows Application Packaging
#     (MSIX) projects, and driver projects that depend on IDE-integrated tooling.
# If the build fails with "the task X was not found" or a missing workload SDK, that is the signal to switch
# edition rather than to guess.
$edition = if ($env:VS_EDITION) { $env:VS_EDITION.ToLower() } else { 'buildtools' }
$bootstrappers = @{
    'buildtools'   = 'https://aka.ms/vs/17/release/vs_buildtools.exe'
    'community'    = 'https://aka.ms/vs/17/release/vs_community.exe'
    'professional' = 'https://aka.ms/vs/17/release/vs_professional.exe'
    'enterprise'   = 'https://aka.ms/vs/17/release/vs_enterprise.exe'
}
if (-not $bootstrappers.ContainsKey($edition)) { throw "VS_EDITION '$edition' is not one of: $($bootstrappers.Keys -join ', ')" }
$installPath = if ($edition -eq 'buildtools') { 'C:\BuildTools' } else { 'C:\Program Files\Microsoft Visual Studio\2022\' + (Get-Culture).TextInfo.ToTitleCase($edition) }
Log "Visual Studio edition: $edition (install to $installPath)"

$vs = 'C:\packer\vs_installer.exe'
Invoke-WebRequest -Uri $bootstrappers[$edition] -OutFile $vs -UseBasicParsing

# Workloads come from the pipeline, so a project that needs UWP or MAUI tools asks for them explicitly
# instead of every image carrying 40 GB of IDE it will never use.
$workloads = @()
if ($env:VS_WORKLOADS) { $workloads = $env:VS_WORKLOADS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
if ($workloads.Count -eq 0) {
    $workloads = @(
        'Microsoft.VisualStudio.Workload.ManagedDesktopBuildTools',
        'Microsoft.VisualStudio.Workload.NativeDesktopBuildTools',
        'Microsoft.VisualStudio.Component.Windows11SDK.22621',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        'Microsoft.Net.Component.4.8.TargetingPack',
        'Microsoft.Net.Component.4.8.SDK'
    )
}
Log ("workloads: " + ($workloads -join ' '))

$vsArgs = @('--quiet', '--wait', '--norestart', '--nocache', '--installPath', $installPath)
foreach ($w in $workloads) { $vsArgs += @('--add', $w) }
$vsArgs += '--includeRecommended'

Log "installing Visual Studio (this is the slow step: 15-40 minutes for Build Tools, longer for the IDE)"
$p = Start-Process -FilePath $vs -ArgumentList $vsArgs -Wait -PassThru
if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Visual Studio installer failed with $($p.ExitCode)" }
Log "Visual Studio installed (exit $($p.ExitCode))"
$msbuild = if ($edition -eq 'buildtools') { 'C:\BuildTools\MSBuild\Current\Bin\MSBuild.exe' }
           else { "$installPath\MSBuild\Current\Bin\MSBuild.exe" }
Check $msbuild '-version'

# Optional VSIX extensions: some project types need one (Installer Projects for .vdproj, for example).
# A URL that cannot be fetched fails the build rather than shipping an image that cannot build the project
# it was asked for.
if ($env:VS_EXTRA_VSIX) {
    if ($edition -eq 'buildtools') { throw "VS_EXTRA_VSIX is set but the image is Build Tools; set vs_edition to install extensions" }
    $vsixInstaller = Join-Path $installPath 'Common7\IDE\VSIXInstaller.exe'
    if (-not (Test-Path $vsixInstaller)) { throw "VSIXInstaller.exe not found at $vsixInstaller" }
    New-Item -ItemType Directory -Force -Path 'C:\packer\vsix' | Out-Null
    $i = 0
    foreach ($url in ($env:VS_EXTRA_VSIX -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $i++
        $file = "C:\packer\vsix\$i.vsix"
        Log "downloading extension $i from $url"
        Invoke-WebRequest -Uri $url -OutFile $file -UseBasicParsing
        if ((Get-Item $file).Length -lt 10KB) { throw "extension $i looks truncated ($((Get-Item $file).Length) bytes)" }
        Log "installing extension $i"
        $p = Start-Process -FilePath $vsixInstaller -ArgumentList @('/q', '/a', $file) -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw "VSIXInstaller failed for $url (exit $($p.ExitCode))" }
        Log "extension $i installed"
    }
}

# Some legacy project types - .vdproj installers, SSDT/SSRS report projects, VSTO and Office add-ins - fail
# from the command line because devenv builds them out of process. Visual Studio ships a tool that turns
# that off; it writes a per-user registry value, so it must run as the account that will do the builds.
if ($env:VS_DISABLE_OUT_OF_PROC -eq 'true') {
    if ($edition -eq 'buildtools') {
        Log "WARNING: VS_DISABLE_OUT_OF_PROC is set but this image is Build Tools, which has no devenv - ignoring"
    } else {
        $tool = Join-Path $installPath 'Common7\IDE\CommonExtensions\Microsoft\VSI\DisableOutOfProcBuild\DisableOutOfProcBuild.exe'
        if (-not (Test-Path $tool)) {
            throw "VS_DISABLE_OUT_OF_PROC is set but DisableOutOfProcBuild.exe is not at $tool"
        }
        Log "disabling out-of-proc build for $edition (per-user registry value)"
        $p = Start-Process -FilePath $tool -Wait -PassThru
        Log "DisableOutOfProcBuild exit $($p.ExitCode)"
        # Report what actually changed rather than assuming the tool worked.
        $hits = Get-ChildItem 'HKCU:\Software\Microsoft\VisualStudio' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    $v = Get-ItemProperty -Path $_.PSPath -Name 'EnableOutOfProcBuild' -ErrorAction SilentlyContinue
                    if ($null -ne $v) { "$($_.PSChildName): EnableOutOfProcBuild=$($v.EnableOutOfProcBuild)" }
                }
        if ($hits) { $hits | ForEach-Object { Log "  $_" } }
        else { Log "  WARNING: no EnableOutOfProcBuild value found; the tool may have failed silently" }
    }
}
 

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
