[CmdletBinding()]
param(
  [string]$ProfileId = "workstation",
  [ValidateSet("readonly", "coding", "workstation")]
  [string]$PermissionPreset
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot "profile-registry.ps1")

if ([string]::IsNullOrWhiteSpace($PermissionPreset)) {
  Write-Host "1. Read-only: inspect files only"
  Write-Host "2. Coding: inspect and edit UTF-8 text files; no PowerShell"
  Write-Host "3. Workstation: all tools, including PowerShell"
  $Choice = Read-Host "Select permission preset"
  $PermissionPreset = switch ($Choice) {
    "1" { "readonly" }
    "2" { "coding" }
    "3" { "workstation" }
    default { throw "No valid permission preset was selected." }
  }
}

$Lock = Enter-HybridTunnelOperationLock -ProfileId $ProfileId
try {
  $Profile = Get-HybridProfile -ProfileId $ProfileId
  $RuntimePaths = Get-HybridTunnelRuntimePaths -Profile $Profile
  $Tunnel = if (Test-Path -LiteralPath $RuntimePaths.TunnelPidPath -PathType Leaf) {
    Get-HybridVerifiedTunnelProcess -Profile $Profile -RecordedPidPath $RuntimePaths.TunnelPidPath
  } else {
    $null
  }
  $Supervisor = if (Test-Path -LiteralPath $RuntimePaths.SupervisorPidPath -PathType Leaf) {
    Get-HybridVerifiedTunnelSupervisorProcess -Profile $Profile -RecordedPidPath $RuntimePaths.SupervisorPidPath
  } else {
    $null
  }
  if ($Tunnel -or $Supervisor) {
    throw "Stop the tunnel before changing the permission preset."
  }

  $ProfileJson = Read-HybridUtf8Json -Path $Profile.ProfilePath -MaximumBytes 262144 -Description "Hybrid profile $ProfileId"
  $RegistryJson = Read-HybridUtf8Json -Path $Profile.RegistryPath -MaximumBytes 1048576 -Description "Hybrid profile registry"
  $CurrentPreset = if ($null -eq $ProfileJson.Value.PSObject.Properties["permissionPreset"]) {
    "workstation"
  } else {
    [string]$ProfileJson.Value.permissionPreset
  }
  if ($CurrentPreset -ceq $PermissionPreset) {
    Write-Output "Permission preset is already '$PermissionPreset'."
    return
  }

  if ($null -eq $ProfileJson.Value.PSObject.Properties["permissionPreset"]) {
    $ProfileJson.Value | Add-Member -NotePropertyName permissionPreset -NotePropertyValue $PermissionPreset
  } else {
    $ProfileJson.Value.permissionPreset = $PermissionPreset
  }

  $Entries = @($RegistryJson.Value.profiles)
  $Matches = @($Entries | Where-Object { [string]$_.id -ceq $ProfileId })
  if ($Matches.Count -ne 1) { throw "Hybrid profile $ProfileId is not registered exactly once." }

  $Utf8 = [Text.UTF8Encoding]::new($false)
  $ProfileText = ($ProfileJson.Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
  $ProfileDirectory = [IO.Path]::GetDirectoryName($Profile.ProfilePath)
  $RegistryDirectory = [IO.Path]::GetDirectoryName($Profile.RegistryPath)
  $Nonce = [guid]::NewGuid().ToString("N")
  $ProfileTemp = Join-Path $ProfileDirectory "profile.$Nonce.tmp"
  $ProfileBackup = Join-Path $ProfileDirectory "profile.$Nonce.bak"
  $RegistryTemp = Join-Path $RegistryDirectory "profile_registry.$Nonce.tmp"
  $RegistryBackup = Join-Path $RegistryDirectory "profile_registry.$Nonce.bak"

  try {
    [IO.File]::WriteAllText($ProfileTemp, $ProfileText, $Utf8)
    $NewProfileHash = (Get-FileHash -LiteralPath $ProfileTemp -Algorithm SHA256).Hash
    $Matches[0].profileSha256 = $NewProfileHash
    $RegistryText = ($RegistryJson.Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
    [IO.File]::WriteAllText($RegistryTemp, $RegistryText, $Utf8)

    [IO.File]::Replace($ProfileTemp, $Profile.ProfilePath, $ProfileBackup)
    try {
      [IO.File]::Replace($RegistryTemp, $Profile.RegistryPath, $RegistryBackup)
    } catch {
      Copy-Item -LiteralPath $ProfileBackup -Destination $Profile.ProfilePath -Force
      throw
    }
  } finally {
    foreach ($Path in @($ProfileTemp, $RegistryTemp, $ProfileBackup, $RegistryBackup)) {
      Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
  }

  $Verified = Get-HybridProfile -ProfileId $ProfileId
  if ($Verified.PermissionPreset -cne $PermissionPreset) {
    throw "The permission preset update could not be verified."
  }
  Write-Output "Permission preset changed: $CurrentPreset -> $PermissionPreset"
  Write-Output "Start the tunnel again for the new tool set to appear in ChatGPT."
} finally {
  Exit-HybridTunnelOperationLock -Lock $Lock
}
