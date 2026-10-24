<#
  The application contract — the checks that must hold wherever the app is running.

  Runs twice with the same code:
    build phase   against http://localhost on the builder, after the site is configured
    deploy phase  against the load-balancer address, from the runner, after the nodes are up

  Because it is the same file in both phases, "it worked on the builder" and "it works behind the LB"
  cannot drift apart.
#>
param(
    [ValidateSet('build', 'deploy')] [string] $Phase = 'build',
    [string] $BaseUrl = 'http://localhost',
    [string] $ExpectedVersion = ''
)

Write-Output "app contract against $BaseUrl (phase: $Phase)"

$health = Assert-HttpOk -Url "$BaseUrl/healthz" -Because '/healthz must answer 200'
if ($health) {
    Assert-Equal -Actual $health.Content.Trim() -Expected 'ok' -Because '/healthz body must be exactly ok'
    Assert-True -Condition ($health.Headers.Contains('X-Served-By')) -Because 'every response must identify the node that served it'
    Assert-True -Condition (-not $health.Headers.Contains('X-Powered-By')) -Because 'X-Powered-By should be stripped by our web.config'
}

$version = (Assert-HttpOk -Url "$BaseUrl/version" -Because '/version must answer').Content.Trim()
if ($ExpectedVersion) {
    Assert-Equal -Actual $version -Expected $ExpectedVersion -Because '/version must equal the version that was published'
} else {
    Assert-Match -Actual $version -Pattern '\d+\.\d+' -Because '/version must look like a version'
}

$sw = [System.Diagnostics.Stopwatch]::StartNew()
Assert-HttpOk -Url "$BaseUrl/healthz" -Because 'a second request must also succeed' | Out-Null
$sw.Stop()
Assert-True -Condition ($sw.ElapsedMilliseconds -lt 3000) -Because "health check must answer inside 3s (took $($sw.ElapsedMilliseconds)ms)"

# A 404 proves the app is routing rather than serving a default page for everything.
try {
    $r = Invoke-WebRequest -Uri "$BaseUrl/definitely-not-a-route" -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
    Assert-Equal -Actual $r.StatusCode -Expected 404 -Because 'unknown routes must 404'
} catch {
    $code = $_.Exception.Response.StatusCode.value__
    Assert-Equal -Actual $code -Expected 404 -Because 'unknown routes must 404'
}

# Telemetry is part of the app contract now: /telemetry says whether it is exporting and where.
$telResponse = Assert-HttpOk -Url "$BaseUrl/telemetry" -Because '/telemetry must answer'
if ($telResponse) {
    $tel = $telResponse.Content | ConvertFrom-Json
    Assert-Match -Actual $tel.service -Pattern 'WinBuild\.SampleApp' -Because 'telemetry must report the service name'
    Assert-Match -Actual $tel.version -Pattern '\d+\.\d+' -Because 'telemetry must report the running version'
    if ($env:EXPECT_OTEL -eq 'true') {
        Assert-True -Condition ($tel.enabled -eq $true) -Because 'OTLP export must be enabled when an endpoint is configured'
        Assert-True -Condition ($tel.endpoint -ne 'none') -Because 'an enabled exporter must name its endpoint'
    } else {
        Write-Output "  telemetry: enabled=$($tel.enabled) endpoint=$($tel.endpoint)"
    }
}

# The demo endpoint exercises the manual instrumentation: spans, a counter and a histogram.
$demoResponse = Assert-HttpOk -Url "$BaseUrl/demo/checkout?items=2" -Because '/demo/checkout must answer'
if ($demoResponse) {
    $order = $demoResponse.Content | ConvertFrom-Json
    Assert-True -Condition ($order.total -gt 0) -Because 'the demo checkout must compute a total'
    if ($env:EXPECT_OTEL -eq 'true') {
        Assert-True -Condition ($order.traceId -ne 'no-trace') -Because 'an instrumented request must produce a trace id'
    }
}

if ($Phase -eq 'deploy') {
    # Distribution is the load balancer's job, and this is where we can see it: several requests must
    # not all come from one node, or the "two nodes tested" claim is false.
    $served = 1..12 | ForEach-Object {
        try { (Invoke-WebRequest -Uri "$BaseUrl/healthz" -UseBasicParsing -TimeoutSec 10).Headers['X-Served-By'] }
        catch { 'error' }
    }
    $distinct = ($served | Sort-Object -Unique)
    Write-Output ("  served by: {0}" -f ($distinct -join ', '))
    Assert-True -Condition ($distinct.Count -ge 2) -Because 'traffic must be distributed across at least two nodes'
}
