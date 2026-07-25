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

$GrantStore = Join-Path (Get-HybridRunsRoot) "ui_grants.json"
$GrantStoreConfigured = Test-Path -LiteralPath $GrantStore -PathType Leaf
$TrustedRuleCount = 0
if ($GrantStoreConfigured) {
  $GrantItem = Get-Item -LiteralPath $GrantStore -Force
  if (($GrantItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $GrantItem.Length -gt 1MB) {
    throw "Window grant store is unsafe."
  }
  $GrantJson = Get-Content -Raw -LiteralPath $GrantStore | ConvertFrom-Json
  if ([string]$GrantJson.version -ceq "1") {
    $TrustedRuleCount = 0
  } elseif ([string]$GrantJson.version -ceq "2") {
    $TrustedRuleCount = @($GrantJson.trustedApps | Where-Object { [string]$_.profileId -ceq $ProfileId }).Count
  } else {
    throw "Window grant store version is unsupported."
  }

  $GrantAcl = Get-Acl -LiteralPath $GrantStore
  if (-not $GrantAcl.AreAccessRulesProtected) { throw "Window grant store ACL inheritance is not disabled." }
  $AllowedSids = @(
    [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
    "S-1-5-18",
    "S-1-5-32-544"
  )
  $UnexpectedAllow = @($GrantAcl.Access | Where-Object AccessControlType -eq Allow | Where-Object {
    $Sid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
    $AllowedSids -notcontains $Sid
  })
  if ($UnexpectedAllow.Count -gt 0) { throw "Window grant store ACL contains an unexpected allow rule." }
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
  windowGrantStoreConfigured = [bool]$GrantStoreConfigured
  trustedWindowRules = $TrustedRuleCount
  credentialSource = $Credential.Source
  onlineDoctor = [bool]$Online
} | ConvertTo-Json -Depth 4
