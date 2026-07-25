[CmdletBinding()]
param(
  [ValidateSet("menu", "list", "grant", "trust", "clear")]
  [string]$Action = "menu",
  [string]$ProfileId = "workstation",
  [int]$WindowIndex = 0,
  [string]$TitleContains
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot "profile-registry.ps1")
$null = Get-HybridProfile -ProfileId $ProfileId
$ConfiguredPath = [Environment]::GetEnvironmentVariable("CHATGPT_HYBRID_UI_GRANTS_PATH", "Process")
if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) { $ConfiguredPath = Join-Path (Get-HybridRunsRoot) "ui_grants.json" }
elseif (-not [IO.Path]::IsPathRooted($ConfiguredPath)) { throw "CHATGPT_HYBRID_UI_GRANTS_PATH must be absolute." }
$StorePath = [IO.Path]::GetFullPath($ConfiguredPath)
$Observer = Join-Path $PSScriptRoot "window-observer.ps1"
$Utf8 = [Text.UTF8Encoding]::new($false)

function New-Store {
  [ordered]@{ version = 2; grants = @(); trustedApps = @() }
}

function Read-Store {
  if (-not (Test-Path -LiteralPath $StorePath -PathType Leaf)) { return (New-Store) }
  $Item = Get-Item -LiteralPath $StorePath -Force
  if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $Item.Length -gt 1MB) {
    throw "Window grant store is unsafe."
  }
  $Value = Get-Content -Raw -LiteralPath $StorePath | ConvertFrom-Json
  if ([string]$Value.version -ceq "1") {
    return [ordered]@{ version = 2; grants = @($Value.grants); trustedApps = @() }
  }
  if ([string]$Value.version -cne "2") { throw "Window grant store version is unsupported." }
  return [ordered]@{ version = 2; grants = @($Value.grants); trustedApps = @($Value.trustedApps) }
}

function Write-Store([object]$Store) {
  if (@($Store.grants).Count -gt 128 -or @($Store.trustedApps).Count -gt 128) {
    throw "Window access store exceeds its bounded entry limit."
  }
  New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($StorePath)) -Force | Out-Null
  $Temp = "$StorePath.$([guid]::NewGuid().ToString('N')).tmp"
  try {
    [IO.File]::WriteAllText($Temp, ($Store | ConvertTo-Json -Depth 12) + [Environment]::NewLine, $Utf8)
    Move-Item -LiteralPath $Temp -Destination $StorePath -Force
    $Acl = [Security.AccessControl.FileSecurity]::new()
    $CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $Acl.SetOwner($CurrentSid)
    $Acl.SetAccessRuleProtection($true, $false)
    foreach ($Sid in @($CurrentSid, [Security.Principal.SecurityIdentifier]::new("S-1-5-18"), [Security.Principal.SecurityIdentifier]::new("S-1-5-32-544"))) {
      $Rule = [Security.AccessControl.FileSystemAccessRule]::new($Sid, [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow)
      $null = $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $StorePath -AclObject $Acl
  } finally {
    Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue
  }
}

function Show-Entries {
  $Store = Read-Store
  $Rows = @()
  foreach ($Grant in @($Store.grants | Where-Object { [string]$_.profileId -ceq $ProfileId })) {
    $Rows += [pscustomobject]@{ type = "one-time"; label = [string]$Grant.label; match = [string]$Grant.ref; createdAt = [string]$Grant.createdAt }
  }
  foreach ($Rule in @($Store.trustedApps | Where-Object { [string]$_.profileId -ceq $ProfileId })) {
    $Rows += [pscustomobject]@{ type = "trusted"; label = [string]$Rule.label; match = "title contains: $($Rule.titleContains)"; createdAt = [string]$Rule.createdAt }
  }
  if ($Rows.Count -eq 0) { Write-Output "No window access entries exist for $ProfileId."; return }
  $Rows | Format-Table -AutoSize
}

function Get-DefaultTitleToken([string]$Title) {
  $Value = ($Title -replace '^\s*\*+', '').Trim()
  $Separator = $Value.IndexOf(" - ", [StringComparison]::Ordinal)
  if ($Separator -ge 0) {
    $First = $Value.Substring(0, $Separator).Trim()
    if ($First.Length -ge 2) { $Value = $First }
  }
  if ($Value.Length -gt 200) { $Value = $Value.Substring(0, 200) }
  $Value
}

if ($Action -eq "menu") {
  Write-Host "Window access for $ProfileId" -ForegroundColor Cyan
  Write-Host "1. Grant one currently open window"
  Write-Host "2. Trust app and auto-rebind"
  Write-Host "3. List access entries"
  Write-Host "4. Clear profile access"
  Write-Host "0. Exit"
  $Action = switch (Read-Host "Select") {
    "1" { "grant" }
    "2" { "trust" }
    "3" { "list" }
    "4" { "clear" }
    default { return }
  }
}

if ($Action -eq "list") { Show-Entries; return }
if ($Action -eq "clear") {
  $Store = Read-Store
  $Store.grants = @($Store.grants | Where-Object { [string]$_.profileId -cne $ProfileId })
  $Store.trustedApps = @($Store.trustedApps | Where-Object { [string]$_.profileId -cne $ProfileId })
  Write-Store $Store
  Write-Output "Cleared one-time grants and trusted-app rules for $ProfileId."
  return
}

$Observed = @(((& $Observer -Action list | Out-String).Trim() | ConvertFrom-Json).windows)
if ($Observed.Count -eq 0) { throw "No eligible top-level windows are open." }
for ($Index = 0; $Index -lt $Observed.Count; $Index += 1) {
  $Item = $Observed[$Index]
  Write-Host ("{0}. [{1}] {2}" -f ($Index + 1), $Item.processName, $Item.title)
}
if ($WindowIndex -le 0) { $WindowIndex = [int](Read-Host "Window number") }
if ($WindowIndex -lt 1 -or $WindowIndex -gt $Observed.Count) { throw "Window selection is invalid." }
$Selected = $Observed[$WindowIndex - 1]
$Store = Read-Store

if ($Action -eq "grant") {
  $Remaining = @($Store.grants | Where-Object {
    [string]$_.profileId -cne $ProfileId -or
    [string]$_.identity.windowHandle -cne [string]$Selected.windowHandle -or
    [int]$_.identity.processId -ne [int]$Selected.processId -or
    [string]$_.identity.processStartedAt -cne [string]$Selected.processStartedAt
  })
  $Label = "[$($Selected.processName)] $($Selected.title)"
  if ($Label.Length -gt 1000) { $Label = $Label.Substring(0, 1000) }
  $Grant = [ordered]@{
    profileId = $ProfileId
    ref = "window:$([guid]::NewGuid().ToString())"
    label = $Label
    createdAt = [DateTimeOffset]::UtcNow.ToString("o")
    identity = [ordered]@{
      windowHandle = [string]$Selected.windowHandle
      processId = [int]$Selected.processId
      processStartedAt = [string]$Selected.processStartedAt
      executablePath = [IO.Path]::GetFullPath([string]$Selected.executablePath)
    }
  }
  $Store.grants = @($Remaining + $Grant)
  Write-Store $Store
  Write-Output "Granted one window to ${ProfileId}: $($Grant.label)"
  Write-Output "The one-time grant expires when that application process closes or restarts."
  return
}

$ExecutablePath = [IO.Path]::GetFullPath([string]$Selected.executablePath)
$DefaultToken = Get-DefaultTitleToken ([string]$Selected.title)
if ([string]::IsNullOrWhiteSpace($TitleContains)) {
  $Entered = Read-Host "Title text for auto-rebind [$DefaultToken]"
  $TitleContains = if ([string]::IsNullOrWhiteSpace($Entered)) { $DefaultToken } else { $Entered.Trim() }
} else {
  $TitleContains = $TitleContains.Trim()
}
if ($TitleContains.Length -lt 2 -or $TitleContains.Length -gt 200) { throw "TitleContains must contain 2 to 200 characters." }
$Matching = @($Observed | Where-Object {
  [string]$_.executablePath -ieq $ExecutablePath -and
  ([string]$_.title).IndexOf($TitleContains, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($Matching.Count -ne 1 -or [string]$Matching[0].windowHandle -cne [string]$Selected.windowHandle) {
  throw "The executable path and title text must identify exactly one currently open window."
}
$CrossProfile = @($Store.trustedApps | Where-Object {
  [string]$_.profileId -cne $ProfileId -and
  [string]$_.executablePath -ieq $ExecutablePath -and
  ([string]$Selected.title).IndexOf([string]$_.titleContains, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if ($CrossProfile.Count -gt 0) { throw "Another profile already has a trusted rule matching this window." }
$RemainingRules = @($Store.trustedApps | Where-Object {
  [string]$_.profileId -cne $ProfileId -or
  [string]$_.executablePath -ine $ExecutablePath -or
  [string]$_.titleContains -ine $TitleContains
})
$RuleLabel = "[$($Selected.processName)] $TitleContains"
if ($RuleLabel.Length -gt 1000) { $RuleLabel = $RuleLabel.Substring(0, 1000) }
$Trusted = [ordered]@{
  profileId = $ProfileId
  ref = "trusted-app:$([guid]::NewGuid().ToString())"
  label = $RuleLabel
  createdAt = [DateTimeOffset]::UtcNow.ToString("o")
  executablePath = $ExecutablePath
  titleContains = $TitleContains
}
$Store.trustedApps = @($RemainingRules + $Trusted)
Write-Store $Store
Write-Output "Trusted app rule added for ${ProfileId}: $RuleLabel"
Write-Output "Auto-rebind occurs only when exactly one live window matches and no profile collision exists."
