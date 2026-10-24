# Minimal assertion helpers.
#
# No Pester: a test suite that needs a module installed on the builder is a dependency the image has to
# carry and pin. These are ten lines that fail loudly and say which check failed.
#
# Usage (dot-source this, then call the Assert-* functions):
#   . "$PSScriptRoot\Assert.ps1"
#   Assert-Equal -Actual $a -Expected 'ok' -Because '/healthz must return ok'

$script:AssertFailures = @()
$script:AssertCount = 0

function Write-Assertion([string]$result, [string]$message) {
    Write-Output ("  [{0}] {1}" -f $result, $message)
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Because)
    $script:AssertCount++
    if ($Condition) { Write-Assertion 'PASS' $Because; return }
    $script:AssertFailures += $Because
    Write-Assertion 'FAIL' $Because
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory)][string]$Because)
    $script:AssertCount++
    if ("$Actual" -eq "$Expected") { Write-Assertion 'PASS' "$Because ($Actual)"; return }
    $script:AssertFailures += "$Because - expected '$Expected', got '$Actual'"
    Write-Assertion 'FAIL' "$Because - expected '$Expected', got '$Actual'"
}

function Assert-Match {
    param([string]$Actual, [string]$Pattern, [Parameter(Mandatory)][string]$Because)
    $script:AssertCount++
    if ($Actual -match $Pattern) { Write-Assertion 'PASS' "$Because ($Actual)"; return }
    $script:AssertFailures += "$Because - '$Actual' does not match /$Pattern/"
    Write-Assertion 'FAIL' "$Because - '$Actual' does not match /$Pattern/"
}

function Assert-HttpOk {
    param([string]$Url, [Parameter(Mandatory)][string]$Because)
    $script:AssertCount++
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 10
        if ($r.StatusCode -eq 200) { Write-Assertion 'PASS' "$Because (200 from $Url)"; return $r }
        $script:AssertFailures += "$Because - $Url returned $($r.StatusCode)"
        Write-Assertion 'FAIL' "$Because - $Url returned $($r.StatusCode)"
    } catch {
        $script:AssertFailures += "$Because - $Url failed: $($_.Exception.Message)"
        Write-Assertion 'FAIL' "$Because - $Url failed: $($_.Exception.Message)"
    }
    return $null
}

function Get-AssertionSummary {
    [pscustomobject]@{
        Checks   = $script:AssertCount
        Failures = $script:AssertFailures.Count
        Detail   = $script:AssertFailures
    }
}

function Assert-NoFailures {
    param([Parameter(Mandatory)][string]$Phase)
    $s = Get-AssertionSummary
    if ($s.Failures -gt 0) {
        Write-Output ""
        Write-Output "${Phase}: $($s.Failures) of $($s.Checks) checks FAILED"
        $s.Detail | ForEach-Object { Write-Output "  - $_" }
        throw "$Phase validation failed ($($s.Failures) check(s))"
    }
    Write-Output "${Phase}: all $($s.Checks) checks passed"
}
