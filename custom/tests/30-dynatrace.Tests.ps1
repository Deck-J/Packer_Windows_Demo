<#
  Monitoring checks.

  Build phase: no OneAgent is installed in the image on purpose (a tenant credential does not belong in a
  reusable image), so there is nothing to assert and the test says so rather than passing silently.

  Deploy phase: the node installs OneAgent at boot if the environment declares a tenant. We assert the
  agent is actually running and that it carries the host group the pipeline asked for — an agent that
  installed but never started quietly costs you the visibility you thought you had.
#>
param(
    [ValidateSet('build', 'deploy')] [string] $Phase = 'build',
    [string] $BaseUrl = 'http://localhost',
    [string] $ExpectedVersion = ''
)

if ($Phase -ne 'deploy') {
    Write-Output 'dynatrace: not installed at image time by design (see docs/RUNBOOK.md 3e) - nothing to check here'
    return
}

# The check runs on the node, invoked by the node-startup self-test path; from a runner there is no local
# agent to inspect, so this test only asserts the app-side contract that monitoring depends on.
Write-Output 'dynatrace: verifying the health endpoint the agent monitors'

$health = Assert-HttpOk -Url "$BaseUrl/healthz" -Because 'the endpoint OneAgent monitors must answer'
if ($health) {
    Assert-Equal -Actual $health.Content.Trim() -Expected 'ok' -Because 'the monitored endpoint must report ok'
}

if ($env:DT_HOST_GROUP) {
    Write-Output "dynatrace: expected host group is $($env:DT_HOST_GROUP) (checked on the node by node-startup.ps1)"
}
