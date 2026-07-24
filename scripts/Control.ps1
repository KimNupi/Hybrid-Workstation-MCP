[CmdletBinding()]
param(
  [ValidateSet("menu", "start", "stop", "status", "doctor")]
  [string]$Action = "menu",
  [string]$ProfileId = "workstation"
)

$ErrorActionPreference = "Stop"
function Invoke-ControlAction([string]$Selected) {
  switch ($Selected) {
    "start" { & (Join-Path $PSScriptRoot "start-tunnel.ps1") -ProfileId $ProfileId }
    "stop" { & (Join-Path $PSScriptRoot "stop-tunnel.ps1") -ProfileId $ProfileId }
    "status" { & (Join-Path $PSScriptRoot "tunnel-status.ps1") -ProfileId $ProfileId -Snapshot }
    "doctor" { & (Join-Path $PSScriptRoot "Doctor.ps1") -ProfileId $ProfileId -Online }
  }
}

if ($Action -ne "menu") { Invoke-ControlAction $Action; return }
Write-Host "Hybrid Workstation MCP" -ForegroundColor Cyan
Write-Host "1. Start"
Write-Host "2. Status"
Write-Host "3. Stop"
Write-Host "4. Doctor"
Write-Host "0. Exit"
$Choice = Read-Host "Select"
$Selected = switch ($Choice) { "1" { "start" } "2" { "status" } "3" { "stop" } "4" { "doctor" } default { $null } }
if ($Selected) { Invoke-ControlAction $Selected }
if ($Host.Name -match "ConsoleHost") { Read-Host "Press Enter to close" | Out-Null }
