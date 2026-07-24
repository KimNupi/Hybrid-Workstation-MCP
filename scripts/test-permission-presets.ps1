[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
$SourceRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$TempRoot = Join-Path $env:TEMP ("HybridMcp-PresetTest-" + [guid]::NewGuid().ToString("N"))
$ToolRoot = Join-Path $TempRoot "tool"
$ScriptRoot = Join-Path $ToolRoot "scripts"
$RuntimeRoot = Join-Path $ToolRoot "runtime"
$ProjectRoot = Join-Path $TempRoot "project"
$ProfileDirectory = Join-Path $ProjectRoot "tools\chatgpt-hybrid-mcp"
$ProfilePath = Join-Path $ProfileDirectory "profile.json"
$RegistryPath = Join-Path $RuntimeRoot "profile_registry.json"
$Utf8 = [Text.UTF8Encoding]::new($false)

try {
  New-Item -ItemType Directory -Path $ScriptRoot, $RuntimeRoot, $ProfileDirectory, (Join-Path $ProjectRoot ".git") -Force | Out-Null
  Copy-Item -LiteralPath (Join-Path $SourceRoot "scripts\profile-registry.ps1") -Destination $ScriptRoot
  Copy-Item -LiteralPath (Join-Path $SourceRoot "scripts\Set-Permission-Preset.ps1") -Destination $ScriptRoot

  $Profile = [ordered]@{
    id = "preset-test"
    displayName = "Preset Test"
    appName = "Preset Test"
    serverName = "preset-test-workstation"
    defaultWorkingDirectoryRelative = "."
    httpPort = 23991
    bootstrapFiles = @()
    identityMarkers = @([ordered]@{ relativePath = "marker.txt"; expectedLiteral = "identity=preset-test" })
  }
  [IO.File]::WriteAllText((Join-Path $ProjectRoot "marker.txt"), "identity=preset-test`n", $Utf8)
  [IO.File]::WriteAllText($ProfilePath, ($Profile | ConvertTo-Json -Depth 10) + [Environment]::NewLine, $Utf8)
  $Hash = (Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash
  $Registry = [ordered]@{
    version = 1
    profiles = @([ordered]@{ id = "preset-test"; profilePath = $ProfilePath; profileSha256 = $Hash })
  }
  [IO.File]::WriteAllText($RegistryPath, ($Registry | ConvertTo-Json -Depth 10) + [Environment]::NewLine, $Utf8)

  $SetScript = Join-Path $ScriptRoot "Set-Permission-Preset.ps1"
  & $SetScript -ProfileId "preset-test" -PermissionPreset "readonly" | Out-Null
  $ObservedProfile = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json
  $ObservedRegistry = Get-Content -Raw -LiteralPath $RegistryPath | ConvertFrom-Json
  if ([string]$ObservedProfile.permissionPreset -cne "readonly") { throw "readonly preset was not persisted." }
  $ObservedHash = (Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash
  if (-not $ObservedHash.Equals([string]$ObservedRegistry.profiles[0].profileSha256, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Registry hash was not updated with the profile."
  }

  & $SetScript -ProfileId "preset-test" -PermissionPreset "workstation" | Out-Null
  $ObservedProfile = Get-Content -Raw -LiteralPath $ProfilePath | ConvertFrom-Json
  if ([string]$ObservedProfile.permissionPreset -cne "workstation") { throw "workstation preset was not persisted." }

  Write-Output "Permission preset update test passed."
} finally {
  if (Test-Path -LiteralPath $TempRoot) { Remove-Item -LiteralPath $TempRoot -Recurse -Force }
}
