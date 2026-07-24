[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
$ToolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$Package = Get-Content -Raw -LiteralPath (Join-Path $ToolRoot "package.json") | ConvertFrom-Json
$Version = [string]$Package.version
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw "package.json version is invalid." }
$VersionParts = $Version.Split('.')
$ReleaseVersion = if ($VersionParts[2] -eq '0') { "$($VersionParts[0]).$($VersionParts[1])" } else { $Version }

$ReleaseRoot = Join-Path $ToolRoot "release"
$ArchiveName = "Hybrid-Workstation-MCP-v$ReleaseVersion.zip"
$ArchivePath = Join-Path $ReleaseRoot $ArchiveName
$HashPath = "$ArchivePath.sha256"
$StagingParent = Join-Path $env:TEMP ("HybridMcp-Release-" + [guid]::NewGuid().ToString("N"))
$StagingRoot = Join-Path $StagingParent "Hybrid-Workstation-MCP"
$Include = @(
  ".gitattributes", ".gitignore", "AGENTS.md", "Configure Tunnel.cmd", "Hybrid MCP Control.cmd", "Install.cmd",
  "README.md", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "package.json", "package-lock.json",
  "tsconfig.json", "docs", "scripts", "src", "templates", "tests"
)

New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
try {
  foreach ($RelativePath in $Include) {
    $Source = Join-Path $ToolRoot $RelativePath
    if (-not (Test-Path -LiteralPath $Source)) { throw "Release input is missing: $RelativePath" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $StagingRoot $RelativePath) -Recurse -Force
  }

  $ForbiddenFiles = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force | Where-Object {
    $_.Name -in @(".env.local", "tunnel.local.yaml", "profile_registry.json") -or
    $_.FullName -match '[\\/](?:runtime|node_modules|dist|artifacts)[\\/]'
  })
  if ($ForbiddenFiles.Count -gt 0) { throw "Release staging contains forbidden runtime material." }

  $PersonalPatterns = @([Environment]::UserName, [Environment]::GetFolderPath("UserProfile")) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  $PersonalMatches = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File | Select-String -SimpleMatch -Pattern $PersonalPatterns -ErrorAction Stop)
  if ($PersonalMatches.Count -gt 0) { throw "Release staging contains a personal path or user name." }

  New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
  Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HashPath -Force -ErrorAction SilentlyContinue
  Compress-Archive -LiteralPath $StagingRoot -DestinationPath $ArchivePath -CompressionLevel Optimal
  $Hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText($HashPath, "$Hash  $ArchiveName`n", [Text.UTF8Encoding]::new($false))

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    if ($Zip.Entries.Count -lt 20) { throw "Release archive contains too few entries." }
    $ForbiddenEntry = $Zip.Entries | Where-Object { $_.FullName -match '(?:^|/)(?:runtime|node_modules|dist|artifacts)/|(?:^|/)(?:\.env\.local|tunnel\.local\.yaml|profile_registry\.json)$' } | Select-Object -First 1
    if ($ForbiddenEntry) { throw "Release archive contains forbidden entry: $($ForbiddenEntry.FullName)" }
  } finally {
    $Zip.Dispose()
  }

  [pscustomobject]@{ Archive=$ArchivePath; Sha256=$Hash; Bytes=(Get-Item -LiteralPath $ArchivePath).Length } | ConvertTo-Json
} finally {
  if (Test-Path -LiteralPath $StagingParent) { Remove-Item -LiteralPath $StagingParent -Recurse -Force }
}
