[CmdletBinding()]
param(
  [ValidateSet("menu", "start", "stop", "status", "doctor", "preset")]
  [string]$Action = "menu",
  [string]$ProfileId = "workstation",
  [ValidateSet("readonly", "workstation")]
  [string]$PermissionPreset
)

$ErrorActionPreference = "Stop"
function Invoke-ControlAction([string]$Selected) {
  switch ($Selected) {
    "start" { & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId }
    "stop" { & (Join-Path $PSScriptRoot "stop-tunnel.ps1") -ProfileId $ProfileId }
    "status" { & (Join-Path $PSScriptRoot "tunnel-status.ps1") -ProfileId $ProfileId -Snapshot }
    "doctor" { & (Join-Path $PSScriptRoot "Doctor.ps1") -ProfileId $ProfileId -Online }
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
Write-Host "0. Exit"
$Choice = Read-Host "Select"
$Selected = switch ($Choice) { "1" { "start" } "2" { "status" } "3" { "stop" } "4" { "doctor" } "5" { "preset" } default { $null } }
if ($Selected) { Invoke-ControlAction $Selected }
if ($Host.Name -match "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
