# Custom build entrypoint.
#
# This is the seam between the pipeline and whatever the application actually needs. The build contract is
# a folder — `custom/` — containing this runner, a config file, and any scripts or files the build needs.
# The pipeline copies the folder onto the builder and executes it; nothing else about the build is fixed.
#
# Contract
#   custom/build.config.json      what to run (see build.config.example.json)
#   custom/scripts/…              any PowerShell, .cmd, .exe, .msi, or source files
#   C:\packer\custom.log          everything this runner and its steps printed
#   C:\packer\custom-manifest.json  sha256 of every file used, for provenance
#
# Exit non-zero from any step and the whole build fails. Nothing is swallowed.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$root     = 'C:\packer\custom'
$configPath = Join-Path $root 'build.config.json'
$logPath  = 'C:\packer\custom.log'
$manifestPath = 'C:\packer\custom-manifest.json'

function Log($message) {
    $line = "$(Get-Date -Format o) $message"
    Write-Output $line
    Add-Content -Path $logPath -Value $line
}

Log "custom build entrypoint starting"
Log "runner: $PSVersionTable.PSVersion on $env:COMPUTERNAME"

if (-not (Test-Path $configPath)) {
    Log "no build.config.json present - nothing custom to do (this is not an error)"
    exit 0
}

# --- config ------------------------------------------------------------------
try {
    $config = Get-Content $configPath -Raw | ConvertFrom-Json
} catch {
    Log "build.config.json is not valid JSON: $($_.Exception.Message)"
    exit 2
}

# Environment for every step. Values may reference $env: or config values; keep it explicit.
if ($config.env) {
    foreach ($p in $config.env.PSObject.Properties) {
        [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process')
        Log "env $($p.Name) set"
    }
}

$workdir = if ($config.workingDirectory) { $config.workingDirectory } else { $root }
if (-not (Test-Path $workdir)) { New-Item -ItemType Directory -Force -Path $workdir | Out-Null }
Log "working directory: $workdir"

# --- provenance --------------------------------------------------------------
$manifest = @()
Get-ChildItem -Path $root -Recurse -File | ForEach-Object {
    $manifest += [ordered]@{
        path   = $_.FullName.Substring($root.Length).TrimStart('\')
        bytes  = $_.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -Path $_.FullName).Hash.ToLower()
    }
}
@{
    generatedAt = (Get-Date).ToString('o')
    instance    = $env:COMPUTERNAME
    files       = $manifest
} | ConvertTo-Json -Depth 5 | Set-Content -Path $manifestPath -Encoding UTF8
Log "manifest written for $($manifest.Count) file(s)"

if (-not $config.steps) {
    Log "config has no steps - nothing to run"
    exit 0
}

# --- steps -------------------------------------------------------------------
$index = 0
foreach ($step in $config.steps) {
    $index++
    $name = if ($step.name) { $step.name } else { "step-$index" }
    if ($step.enabled -eq $false) { Log "[$name] disabled, skipping"; continue }

    $timeout = if ($step.timeoutSeconds) { [int]$step.timeoutSeconds } else { 3600 }
    Log "[$name] starting (timeout ${timeout}s): $($step.command)"

    $started = Get-Date
    $proc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', $step.command) `
        -WorkingDirectory $workdir -PassThru -NoNewWindow `
        -RedirectStandardOutput "$env:TEMP\$name.out" -RedirectStandardError "$env:TEMP\$name.err"

    if (-not $proc.WaitForExit($timeout * 1000)) {
        try { $proc.Kill() } catch { }
        Log "[$name] TIMED OUT after ${timeout}s"
        exit 3
    }

    $out = Get-Content "$env:TEMP\$name.out" -Raw -ErrorAction SilentlyContinue
    $err = Get-Content "$env:TEMP\$name.err" -Raw -ErrorAction SilentlyContinue
    if ($out) { Add-Content $logPath $out; Write-Output $out }
    if ($err) { Add-Content $logPath $err; Write-Error $err -ErrorAction Continue }

    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    if ($proc.ExitCode -ne 0) {
        Log "[$name] FAILED with exit code $($proc.ExitCode) after ${elapsed}s"
        exit $proc.ExitCode
    }
    Log "[$name] ok in ${elapsed}s"
}

Log "custom build entrypoint complete"
exit 0
