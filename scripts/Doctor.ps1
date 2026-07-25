[CmdletBinding()]
param(
  [string]$ProfileId = "workstation",
  [switch]$Online
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "profile-registry.ps1")
$Profile = Get-HybridProfile -ProfileId $ProfileId -RequireTunnelConfig
$TunnelExecutable = Get-HybridTunnelExecutablePath
$Stdio = Get-HybridStdioRuntime
$Credential = Initialize-HybridControlPlaneCredential
$ToolRoot = Get-HybridToolRoot
$CaptureExecutable = Join-Path $ToolRoot "runtime-distribution\window-capture\win-x64\HybridWindowCapture.exe"
$CaptureHashPath = "$CaptureExecutable.sha256"
$CaptureBackend = "print_window_fallback_only"
if ((Test-Path -LiteralPath $CaptureExecutable -PathType Leaf) -xor (Test-Path -LiteralPath $CaptureHashPath -PathType Leaf)) {
  throw "Native window capture distribution is incomplete."
}
if (Test-Path -LiteralPath $CaptureExecutable -PathType Leaf) {
  $HashText = (Get-Content -Raw -LiteralPath $CaptureHashPath).Trim()
  if ($HashText -notmatch '^([a-fA-F0-9]{64})\s+HybridWindowCapture\.exe$') { throw "Native window capture checksum file is malformed." }
  $ObservedHash = (Get-FileHash -LiteralPath $CaptureExecutable -Algorithm SHA256).Hash
  if (-not $ObservedHash.Equals($Matches[1], [StringComparison]::OrdinalIgnoreCase)) { throw "Native window capture checksum mismatch." }
  $SelfTest = (& $CaptureExecutable --self-test | Out-String).Trim() | ConvertFrom-Json
  if (-not $SelfTest.ok -or [string]$SelfTest.architecture -cne "X64") { throw "Native window capture self-test failed." }
  $CaptureBackend = if ($SelfTest.captureSupported) { "windows_graphics_capture_with_print_window_fallback" } else { "print_window_fallback_only" }
}
& (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId -ValidateOnly
if ($Online) {
  & $TunnelExecutable doctor --profile-file $Profile.TunnelConfigPath --explain
  if ($LASTEXITCODE -ne 0) { throw "Online tunnel-client doctor failed." }
}
[pscustomobject]@{
  ok = $true
  profileId = $Profile.Id
  permissionPreset = $Profile.PermissionPreset
  profileRoot = $Profile.RepoRoot
  node = $Stdio.NodePath
  tunnelClient = $TunnelExecutable
  windowCapture = $CaptureBackend
  credentialSource = $Credential.Source
  onlineDoctor = [bool]$Online
} | ConvertTo-Json -Depth 4
