<#
  Generalise the image. Without this the captured image keeps the builder's machine identity (SID, hostname,
  activation state), and every node cloned from it misbehaves in the same subtle way.
#>
$ErrorActionPreference = 'Stop'
Write-Output 'running sysprep /generalize /oobe /shutdown'
& "$env:SystemRoot\System32\Sysprep\sysprep.exe" /generalize /oobe /shutdown /quiet
Start-Sleep -Seconds 20
