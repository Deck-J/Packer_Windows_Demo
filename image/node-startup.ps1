<#
  node-startup.ps1 — runs on each Windows node at first boot (windows-startup-script-ps1).

  It delivers the EXACT package published to GitHub Packages on this run: the workflow staged those bytes
  in GCS and passed the URL and sha256 in instance metadata, so the node verifies what it installs rather
  than trusting the bucket. If anything fails, IIS is stopped so the load balancer can never report a node
  healthy that is not running the published artifact.

  C:\app\status.json is written at every stage — that file is the evidence used when a node misbehaves.
#>
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Get-Meta($name) {
  Invoke-RestMethod -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$name" `
    -Headers @{ 'Metadata-Flavor' = 'Google' } -TimeoutSec 10
}
function Set-Status($stage, $detail = '') {
  $obj = [ordered]@{
    stage    = $stage
    detail   = $detail
    version  = $script:Version
    instance = $env:COMPUTERNAME
    at       = (Get-Date).ToString('o')
  }
  New-Item -ItemType Directory -Force -Path C:\app | Out-Null
  $obj | ConvertTo-Json | Set-Content C:\app\status.json -Encoding UTF8
  Write-Output "status: $stage $detail"
}

function Install-Dynatrace {
    <#
      Installs Dynatrace OneAgent with the API token fetched from Secret Manager by the node's own service
      account. The token is never in instance metadata, never in the image and never in this script: a node
      that cannot read the secret simply reports that monitoring is off.

      Metadata used:
        dynatrace-tenant        environment id (empty = skip)
        dynatrace-host-group    host group name
        dynatrace-token-secret  Secret Manager secret name holding a PaaS token
    #>
    $tenant = $null
    try { $tenant = Get-Meta 'dynatrace-tenant' } catch { }
    if (-not $tenant) { Set-Status 'dynatrace' 'not configured'; return }

    $secretName = Get-Meta 'dynatrace-token-secret'
    $hostGroup  = Get-Meta 'dynatrace-host-group'
    Set-Status 'dynatrace' "tenant $tenant, group $hostGroup"

    $token = (& gcloud secrets versions access latest --secret=$secretName 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $token) {
        throw "cannot read Dynatrace token secret '$secretName' (the node service account needs secretAccessor)"
    }

    $msi = 'C:\app\oneagent.msi'
    $url = "https://$tenant.live.dynatrace.com/api/v1/deployment/installer/agent/windows/default/latest?arch=x86&flavor=default"
    Invoke-WebRequest -Uri $url -Headers @{ Authorization = "Api-Token $token" } -OutFile $msi -UseBasicParsing
    if (-not (Test-Path $msi) -or (Get-Item $msi).Length -lt 1MB) { throw 'OneAgent installer download failed or is implausibly small' }

    $msiArgs = @(
        '/i', $msi, '/qn', '/norestart',
        'INSTALL_PATH="C:\Program Files\dynatrace\oneagent"',
        "TENANT=$tenant", "TENANT_TOKEN=$token"
    )
    if ($hostGroup) { $msiArgs += "HOST_GROUP=$hostGroup" }
    $p = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "OneAgent install failed ($($p.ExitCode))" }

    # The agent registers asynchronously; wait for its services rather than assuming.
    $deadline = (Get-Date).AddMinutes(5)
    do {
        $running = (Get-Service -Name 'Dynatrace*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running').Count
        if ($running -ge 1) { break }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    if ($running -lt 1) { throw 'OneAgent services never started' }

    $ctl = 'C:\Program Files\dynatrace\oneagent\agent\tools\oneagentctl.exe'
    if (Test-Path $ctl) {
        $tags = (& $ctl --get-host-tags) -join ' '
        Set-Status 'dynatrace' "running; host tags: $tags"
    } else {
        Set-Status 'dynatrace' "running ($running service(s)), oneagentctl not found"
    }

    # The token is only needed for the install.
    Remove-Item $msi -Force -ErrorAction SilentlyContinue
    $token = $null
}

$script:Version = Get-Meta 'app-version'
$pkgUrl = Get-Meta 'package-url'
$pkgSha = Get-Meta 'package-sha256'
$nupkg  = 'C:\app\package.nupkg'

try {
  Set-Status 'start' 'beginning package install'
  New-Item -ItemType Directory -Force -Path C:\app | Out-Null

  # 1. Fetch the package with the node's own least-privilege service account.
  Set-Status 'download' $pkgUrl
  & gcloud storage cp $pkgUrl $nupkg --quiet
  if ($LASTEXITCODE -ne 0) { throw "gcloud storage cp failed ($LASTEXITCODE)" }

  # 2. Verify it is the artifact that was published, not a stale or tampered object.
  Set-Status 'verify' $pkgSha
  $actual = (Get-FileHash -Algorithm SHA256 -Path $nupkg).Hash.ToLower()
  if ($actual -ne $pkgSha.ToLower()) { throw "sha256 mismatch: got $actual, expected $pkgSha" }

  # 3. Expand and stage the payload.
  Set-Status 'install'
  $stage = 'C:\app\stage'
  if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
  Expand-Archive -Path $nupkg -DestinationPath $stage -Force
  $payload = Get-ChildItem $stage -Recurse -Filter 'payload' -Directory | Select-Object -First 1
  if (-not $payload) { throw 'package has no payload directory' }
  $site = 'C:\app\site'
  if (Test-Path $site) { Remove-Item $site -Recurse -Force }
  Copy-Item $payload.FullName $site -Recurse

  # 4. Serve it: IIS + ASP.NET Core Hosting Bundle are baked into the image by the build.
  Set-Status 'configure'
  Import-Module WebAdministration
  if (-not (Get-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue)) {
    New-WebAppPool -Name 'WinBuildApp' -ErrorAction SilentlyContinue | Out-Null
    New-Website -Name 'WinBuildApp' -PhysicalPath $site -Port 80 -ApplicationPool 'WinBuildApp' -Force | Out-Null
  }
  Set-ItemProperty 'IIS:\Sites\WinBuildApp' -Name physicalPath -Value $site
  Start-Website -Name 'WinBuildApp' -ErrorAction SilentlyContinue
  Set-Service -Name W3SVC -StartupType Automatic
  Start-Service W3SVC -ErrorAction SilentlyContinue

  # 4b. Monitoring agent, when the environment declares one.
  Install-Dynatrace

  # 5. Self-check before declaring done: the LB trusts /healthz, so prove it locally first.
  Set-Status 'selfcheck'
  $ok = $false
  for ($i = 1; $i -le 30; $i++) {
    try {
      $r = Invoke-WebRequest -Uri 'http://localhost/healthz' -UseBasicParsing -TimeoutSec 5
      if ($r.StatusCode -eq 200) { $ok = $true; break }
    } catch { Start-Sleep -Seconds 2 }
  }
  if (-not $ok) { throw '/healthz did not return 200 on localhost' }

  $served = (Invoke-WebRequest -Uri 'http://localhost/version' -UseBasicParsing).Content
  Set-Status 'done' "serving $served"
}
catch {
  Set-Status 'failed' $_.Exception.Message
  Write-Output "STARTUP FAILED: $($_.Exception.Message)"
  Stop-Service W3SVC -Force -ErrorAction SilentlyContinue
  exit 1
}
