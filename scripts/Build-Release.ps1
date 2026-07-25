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
$NativeDistribution = Join-Path $StagingRoot "runtime-distribution\window-capture\win-x64"
$Include = @(
  ".gitattributes", ".gitignore", "AGENTS.md", "Configure Tunnel.cmd", "Hybrid MCP Control.cmd", "Install.cmd",
  "README.md", "SECURITY.md", "THIRD_PARTY_NOTICES.md", "LICENSE", "package.json", "package-lock.json",
  "tsconfig.json", "docs", "native", "scripts", "src", "templates", "tests"
)
$TextExtensions = @(".cmd", ".cs", ".csproj", ".gitattributes", ".gitignore", ".json", ".md", ".mjs", ".ps1", ".ts", ".txt", ".yaml", ".yml")

New-Item -ItemType Directory -Path $StagingRoot -Force | Out-Null
try {
  foreach ($RelativePath in $Include) {
    $Source = Join-Path $ToolRoot $RelativePath
    if (-not (Test-Path -LiteralPath $Source)) { throw "Release input is missing: $RelativePath" }
    Copy-Item -LiteralPath $Source -Destination (Join-Path $StagingRoot $RelativePath) -Recurse -Force
  }
  Get-ChildItem -LiteralPath (Join-Path $StagingRoot "native") -Recurse -Directory -Force |
    Where-Object { $_.Name -in @("bin", "obj") } |
    Sort-Object FullName -Descending |
    Remove-Item -Recurse -Force

  $NativeBuildText = (& (Join-Path $ToolRoot "scripts\Build-Native.ps1") -OutputRoot $NativeDistribution | Out-String).Trim()
  $NativeBuild = $NativeBuildText | ConvertFrom-Json
  $NativeExecutable = Join-Path $NativeDistribution "HybridWindowCapture.exe"
  $NativeHashPath = "$NativeExecutable.sha256"
  if (-not (Test-Path -LiteralPath $NativeExecutable -PathType Leaf) -or -not (Test-Path -LiteralPath $NativeHashPath -PathType Leaf)) {
    throw "Release staging is missing the native window capture distribution."
  }
  $NativeSelfTest = (& $NativeExecutable --self-test | Out-String).Trim() | ConvertFrom-Json
  if (-not $NativeSelfTest.ok -or [string]$NativeSelfTest.architecture -cne "X64") { throw "Release native window capture self-test failed." }

  $ForbiddenFiles = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -Force | Where-Object {
    $_.Name -in @(".env.local", "tunnel.local.yaml", "profile_registry.json", "ui_grants.json") -or
    $_.FullName -match '[\\/](?:runtime|node_modules|dist|artifacts|bin|obj)[\\/]'
  })
  if ($ForbiddenFiles.Count -gt 0) { throw "Release staging contains forbidden runtime or build material." }

  $PersonalPatterns = @(@([Environment]::UserName, [Environment]::GetFolderPath("UserProfile")) | Where-Object {
    -not [string]::IsNullOrWhiteSpace($_)
  })
  $TextFiles = @(Get-ChildItem -LiteralPath $StagingRoot -Recurse -File | Where-Object {
    $TextExtensions -contains $_.Extension.ToLowerInvariant() -or $_.Name -in @("LICENSE", "AGENTS.md")
  })
  $PersonalMatches = @(if ($PersonalPatterns.Count -gt 0) {
    $TextFiles | Select-String -SimpleMatch -Pattern $PersonalPatterns -ErrorAction Stop
  })
  if ($PersonalMatches.Count -gt 0) { throw "Release staging contains a personal path or user name." }
  $NativeText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($NativeExecutable))
  foreach ($Pattern in $PersonalPatterns) {
    if ($NativeText.IndexOf($Pattern, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
      throw "Native release helper contains a personal path or user name."
    }
  }

  New-Item -ItemType Directory -Path $ReleaseRoot -Force | Out-Null
  Remove-Item -LiteralPath $ArchivePath -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $HashPath -Force -ErrorAction SilentlyContinue
  Compress-Archive -LiteralPath $StagingRoot -DestinationPath $ArchivePath -CompressionLevel Optimal
  $Hash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText($HashPath, "$Hash  $ArchiveName`n", [Text.UTF8Encoding]::new($false))

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $Zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
  try {
    if ($Zip.Entries.Count -lt 30) { throw "Release archive contains too few entries." }
    $NormalizedEntries = @($Zip.Entries | ForEach-Object {
      [pscustomobject]@{ Entry=$_; Name=$_.FullName.Replace([char]92, [char]47) }
    })
    $ForbiddenEntry = $NormalizedEntries | Where-Object {
      $_.Name -match '(?:^|/)(?:runtime|node_modules|dist|artifacts|bin|obj)/|(?:^|/)(?:\.env\.local|tunnel\.local\.yaml|profile_registry\.json|ui_grants\.json)$'
    } | Select-Object -First 1
    if ($ForbiddenEntry) { throw "Release archive contains forbidden entry: $($ForbiddenEntry.Name)" }
    foreach ($RequiredEntry in @(
      "Hybrid-Workstation-MCP/runtime-distribution/window-capture/win-x64/HybridWindowCapture.exe",
      "Hybrid-Workstation-MCP/runtime-distribution/window-capture/win-x64/HybridWindowCapture.exe.sha256",
      "Hybrid-Workstation-MCP/native/window-capture/Program.cs"
    )) {
      if (-not ($NormalizedEntries | Where-Object { $_.Name -ceq $RequiredEntry })) {
        throw "Release archive is missing: $RequiredEntry"
      }
    }
  } finally {
    $Zip.Dispose()
  }

  [pscustomobject]@{
    Archive=$ArchivePath
    Sha256=$Hash
    Bytes=(Get-Item -LiteralPath $ArchivePath).Length
    NativeSha256=$NativeBuild.sha256
    NativeBytes=$NativeBuild.bytes
  } | ConvertTo-Json
} finally {
  if (Test-Path -LiteralPath $StagingParent) { Remove-Item -LiteralPath $StagingParent -Recurse -Force }
}
