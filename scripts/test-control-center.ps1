[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$ControlCenterPath = Join-Path $PSScriptRoot "ControlCenter.ps1"
$Tokens = $null
$ParseErrors = $null
$null = [Management.Automation.Language.Parser]::ParseFile(
  $ControlCenterPath,
  [ref]$Tokens,
  [ref]$ParseErrors
)
if (@($ParseErrors).Count -ne 0) {
  throw "ControlCenter.ps1 has PowerShell parser errors: $($ParseErrors -join '; ')"
}

$PowerShellPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source
$Output = @(
  & $PowerShellPath `
    -NoProfile `
    -NonInteractive `
    -STA `
    -ExecutionPolicy Bypass `
    -File $ControlCenterPath `
    -ValidateOnly 2>&1
)
if ($LASTEXITCODE -ne 0) {
  throw "Control Center validation process failed: $($Output -join [Environment]::NewLine)"
}
$Validation = (($Output | Out-String).Trim() | ConvertFrom-Json -ErrorAction Stop)
if (
  [string]$Validation.schema -cne "hybrid.controlCenterValidation.v1" -or
  -not [bool]$Validation.windowLoaded -or
  [int]$Validation.height -lt 600 -or
  [int]$Validation.height -gt 650 -or
  [int]$Validation.requiredControlCount -lt 20 -or
  [int]$Validation.requiredControlCount -ne [int]$Validation.resolvedControlCount -or
  -not [bool]$Validation.multiProfileControlsAvailable
) {
  throw "Control Center XAML validation contract is invalid."
}
if ((@($Validation.fixtureStates) -join "|") -cne "stopped|connected|recovering|issue") {
  throw "Control Center status presentation fixtures did not preserve the expected states."
}
if ((@($Validation.fixtureActions) -join "|") -cne "start|stop|stop|doctor") {
  throw "Control Center status presentation fixtures did not preserve the expected primary actions."
}

$Text = Get-Content -Raw -LiteralPath $ControlCenterPath -Encoding utf8
foreach ($RequiredScript in @(
  "tunnel-status.ps1",
  "start-tunnel.ps1",
  "stop-tunnel.ps1",
  "Control.ps1",
  "tunnel-manager.ps1",
  "Doctor.ps1",
  "Configure-Tunnel.ps1"
)) {
  if ($Text.IndexOf($RequiredScript, [StringComparison]::Ordinal) -lt 0) {
    throw "Control Center does not delegate to required existing script: $RequiredScript"
  }
}
if ($Text -match '(?i)CONTROL_PLANE_API_KEY\s*=|tunnel_[a-f0-9]{32}') {
  throw "Control Center source appears to embed a credential or tunnel identifier."
}

$ToolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$EntryPointText = Get-Content -Raw -LiteralPath (Join-Path $ToolRoot "Hybrid MCP Control.cmd") -Encoding utf8
if (
  $EntryPointText -cnotmatch 'ControlCenter\.ps1' -or
  $EntryPointText -cnotmatch '(?i)-STA' -or
  $EntryPointText -cnotmatch '(?i)-NonInteractive'
) {
  throw "The double-click entry point does not launch the STA Control Center."
}

$InstallText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "Install.ps1") -Encoding utf8
if (
  $InstallText -cnotmatch 'ControlCenter\.ps1' -or
  $InstallText -cnotmatch '(?i)-STA' -or
  $InstallText -cnotmatch '(?i)-NonInteractive' -or
  $InstallText -cnotmatch '(?i)-WindowStyle Hidden'
) {
  throw "The installer shortcut does not launch the hidden-console STA Control Center."
}

$ReleaseText = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot "Build-Release.ps1") -Encoding utf8
foreach ($RequiredReleaseEntry in @(
  "Hybrid-Workstation-MCP/scripts/ControlCenter.ps1",
  "Hybrid-Workstation-MCP/scripts/test-control-center.ps1",
  "Hybrid-Workstation-MCP/scripts/tunnel-manager.ps1",
  "Hybrid-Workstation-MCP/scripts/test-tunnel-manager.ps1"
)) {
  if ($ReleaseText.IndexOf($RequiredReleaseEntry, [StringComparison]::Ordinal) -lt 0) {
    throw "The release contract is missing Control Center entry: $RequiredReleaseEntry"
  }
}

$Package = Get-Content -Raw -LiteralPath (Join-Path $ToolRoot "package.json") -Encoding utf8 | ConvertFrom-Json
if (
  [string]$Package.scripts.'test:control-center' -cnotmatch 'test-control-center\.ps1' -or
  [string]$Package.scripts.check -cnotmatch 'test:control-center'
) {
  throw "package.json does not include the Control Center validation gate."
}
if ($Text -cnotmatch 'HybridWorkstationMcp-ControlCenter') {
  throw "Control Center does not enforce a single manager instance lock."
}
foreach ($RequiredMultiProfileContract in @("ProfileSelector", "AllProfilesButton", "status-all", "start-all", "stop-all")) {
  if ($Text.IndexOf($RequiredMultiProfileContract, [StringComparison]::Ordinal) -lt 0) {
    throw "Control Center is missing multi-profile contract: $RequiredMultiProfileContract"
  }
}

Write-Output "CONTROL_CENTER_TEST_OK"
