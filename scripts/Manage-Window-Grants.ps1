[CmdletBinding()]
param(
  [ValidateSet("menu", "list", "grant", "clear")]
  [string]$Action = "menu",
  [string]$ProfileId = "workstation",
  [int]$WindowIndex = 0
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

function Read-Store {
  if (-not (Test-Path -LiteralPath $StorePath -PathType Leaf)) { return [ordered]@{ version=1; grants=@() } }
  $Value = Get-Content -Raw -LiteralPath $StorePath | ConvertFrom-Json
  if ([string]$Value.version -cne "1") { throw "Window grant store version is unsupported." }
  return [ordered]@{ version=1; grants=@($Value.grants) }
}
function Write-Store([object]$Store) {
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
  } finally { Remove-Item -LiteralPath $Temp -Force -ErrorAction SilentlyContinue }
}
function Show-Grants {
  $Items = @((Read-Store).grants | Where-Object { [string]$_.profileId -ceq $ProfileId })
  if ($Items.Count -eq 0) { Write-Output "No windows are granted for $ProfileId."; return }
  $Items | Select-Object label,createdAt,@{n='windowRef';e={$_.ref}} | Format-Table -AutoSize
}

if ($Action -eq "menu") {
  Write-Host "Window access for $ProfileId" -ForegroundColor Cyan
  Write-Host "1. Grant one currently open window"
  Write-Host "2. List grants"
  Write-Host "3. Clear grants"
  Write-Host "0. Exit"
  $Action = switch (Read-Host "Select") { "1" { "grant" } "2" { "list" } "3" { "clear" } default { return } }
}
if ($Action -eq "list") { Show-Grants; return }
if ($Action -eq "clear") {
  $Store = Read-Store
  $Store.grants = @($Store.grants | Where-Object { [string]$_.profileId -cne $ProfileId })
  Write-Store $Store
  Write-Output "Cleared window grants for $ProfileId."
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
$Remaining = @($Store.grants | Where-Object { [string]$_.profileId -cne $ProfileId })
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
    executablePath = [string]$Selected.executablePath
  }
}
$Store.grants = @($Remaining + $Grant)
Write-Store $Store
Write-Output "Granted one window to ${ProfileId}: $($Grant.label)"
Write-Output "The grant expires automatically when that application process closes or restarts."
