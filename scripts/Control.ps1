[CmdletBinding()]
param(
  [ValidateSet("menu", "profiles", "start", "stop", "restart", "status", "status-all", "start-all", "stop-all", "restart-all", "doctor", "preset", "windows")]
  [string]$Action = "menu",
  [string]$ProfileId = "workstation",
  [ValidateSet("readonly", "workstation")]
  [string]$PermissionPreset
)

$ErrorActionPreference = "Stop"
$ManagerScript = Join-Path $PSScriptRoot "tunnel-manager.ps1"
function Invoke-ControlAction([string]$Selected) {
  switch ($Selected) {
    "start" { & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId }
    "stop" { & (Join-Path $PSScriptRoot "stop-tunnel.ps1") -ProfileId $ProfileId }
    "restart" {
      & (Join-Path $PSScriptRoot "stop-tunnel.ps1") -ProfileId $ProfileId
      & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId
    }
    "status" { & (Join-Path $PSScriptRoot "tunnel-status.ps1") -ProfileId $ProfileId -Snapshot }
    { $_ -in @("profiles", "status-all", "start-all", "stop-all", "restart-all") } {
      & $ManagerScript -Action $Selected
    }
    "doctor" { & (Join-Path $PSScriptRoot "Doctor.ps1") -ProfileId $ProfileId -Online }
    "windows" { & (Join-Path $PSScriptRoot "Manage-Window-Grants.ps1") -ProfileId $ProfileId }
    "preset" {
      $Status = (& (Join-Path $PSScriptRoot "tunnel-status.ps1") -ProfileId $ProfileId -Snapshot | Out-String) | ConvertFrom-Json
      $WasActive = [bool]$Status.running -or [bool]$Status.supervised -or [bool]$Status.desiredRunning
      if ($WasActive) {
        Write-Host "Temporarily stopping the tunnel..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "stop-tunnel.ps1") -ProfileId $ProfileId
      }

      try {
        $Arguments = @{ ProfileId = $ProfileId }
        if (-not [string]::IsNullOrWhiteSpace($PermissionPreset)) { $Arguments.PermissionPreset = $PermissionPreset }
        & (Join-Path $PSScriptRoot "Set-Permission-Preset.ps1") @Arguments
      } catch {
        if ($WasActive) {
          Write-Host "The preset change failed; restarting the previous configuration..." -ForegroundColor Yellow
          & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId
        }
        throw
      }

      if ($WasActive) {
        Write-Host "Restarting the tunnel with the new preset..." -ForegroundColor Yellow
        & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId
      }
    }
  }
}

if ($Action -ne "menu") { Invoke-ControlAction $Action; return }
Write-Host "Hybrid Workstation MCP" -ForegroundColor Cyan
Write-Host "1. Start"
Write-Host "2. Status"
Write-Host "3. Stop"
Write-Host "4. Doctor"
Write-Host "5. Read-only lock settings"
Write-Host "6. Window access"
Write-Host "7. Start all registered profiles"
Write-Host "8. Status of all registered profiles"
Write-Host "9. Stop all registered profiles"
Write-Host "10. Restart active profiles"
Write-Host "0. Exit"
$Choice = Read-Host "Select"
$Selected = switch ($Choice) {
  "1" { "start" }
  "2" { "status" }
  "3" { "stop" }
  "4" { "doctor" }
  "5" { "preset" }
  "6" { "windows" }
  "7" { "start-all" }
  "8" { "status-all" }
  "9" { "stop-all" }
  "10" { "restart-all" }
  default { $null }
}
if ($Selected) { Invoke-ControlAction $Selected }
if ($Host.Name -match "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
