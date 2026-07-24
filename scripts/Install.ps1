[CmdletBinding()]
param(
  [string]$WorkspaceRoot = (Join-Path $env:USERPROFILE "Hybrid Workstation"),
  [string]$ProfileId = "workstation",
  [string]$DisplayName = "Hybrid Workstation",
  [ValidateSet("readonly", "coding", "workstation")]
  [string]$PermissionPreset = "coding",
  [switch]$Force,
  [switch]$SkipTunnelDownload,
  [switch]$NoDesktopShortcut
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$ToolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
$WorkspaceRoot = [IO.Path]::GetFullPath($WorkspaceRoot)
$ProfileDirectory = Join-Path $WorkspaceRoot "tools\chatgpt-hybrid-mcp"
$ProfilePath = Join-Path $ProfileDirectory "profile.json"
$RegistryPath = Join-Path $ToolRoot "runtime\profile_registry.json"
$TemplateRoot = Join-Path $ToolRoot "templates\workstation"
$Utf8 = [Text.UTF8Encoding]::new($false)

if ($env:OS -cne "Windows_NT") { throw "Hybrid Workstation MCP currently supports Windows only." }
if ($ProfileId -cnotmatch "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$") { throw "ProfileId is invalid." }
if ([string]::IsNullOrWhiteSpace($DisplayName) -or $DisplayName.Length -gt 80) { throw "DisplayName is invalid." }
if ((Test-Path -LiteralPath $ProfilePath) -and -not $Force) { throw "Profile already exists. Re-run with -Force only after reviewing it: $ProfilePath" }

foreach ($command in @("node.exe", "npm.cmd", "git.exe", "rg.exe")) {
  if (-not (Get-Command $command -CommandType Application -ErrorAction SilentlyContinue)) {
    throw "Required command is missing: $command"
  }
}
$NodeVersion = (& node.exe -p "process.versions.node").Trim()
if ([version]$NodeVersion -lt [version]"20.0.0") { throw "Node.js 20 or newer is required; found $NodeVersion." }
$NodeArchitecture = (& node.exe -p "process.arch").Trim()
if ($NodeArchitecture -cne "x64") { throw "This preview currently supports Windows x64 only; found Node architecture $NodeArchitecture." }

& npm.cmd --prefix $ToolRoot ci --ignore-scripts --no-audit --no-fund
if ($LASTEXITCODE -ne 0) { throw "npm ci failed." }
& npm.cmd --prefix $ToolRoot run check
if ($LASTEXITCODE -ne 0) { throw "MCP build or test failed." }

New-Item -ItemType Directory -Path $WorkspaceRoot -Force | Out-Null
New-Item -ItemType Directory -Path $ProfileDirectory -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WorkspaceRoot "artifacts\chatgpt-hybrid-mcp") -Force | Out-Null
foreach ($name in @("AGENTS.md", "README.md", "WORKSTATION_POLICY.md", "workstation.marker", ".gitignore")) {
  $destination = Join-Path $WorkspaceRoot $name
  if (-not (Test-Path -LiteralPath $destination) -or $Force) {
    Copy-Item -LiteralPath (Join-Path $TemplateRoot $name) -Destination $destination -Force
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".git") -PathType Container)) {
  & git.exe -C $WorkspaceRoot init --initial-branch=main | Out-Null
  if ($LASTEXITCODE -ne 0) { throw "Could not initialize the profile repository." }
}

$Profile = [ordered]@{
  id = $ProfileId
  displayName = $DisplayName
  appName = $DisplayName
  serverName = "$ProfileId-chatgpt-workstation"
  permissionPreset = $PermissionPreset
  defaultWorkingDirectoryRelative = "."
  httpPort = 2098
  bootstrapFiles = @("AGENTS.md", "README.md", "WORKSTATION_POLICY.md")
  identityMarkers = @([ordered]@{ relativePath = "workstation.marker"; expectedLiteral = "identity=hybrid-workstation" })
}
$ProfileJson = $Profile | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($ProfilePath, $ProfileJson + [Environment]::NewLine, $Utf8)
$ProfileHash = (Get-FileHash -LiteralPath $ProfilePath -Algorithm SHA256).Hash
$Registry = [ordered]@{
  version = 1
  profiles = @([ordered]@{ id = $ProfileId; profilePath = $ProfilePath; profileSha256 = $ProfileHash })
}
New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($RegistryPath)) -Force | Out-Null
[IO.File]::WriteAllText($RegistryPath, ($Registry | ConvertTo-Json -Depth 6) + [Environment]::NewLine, $Utf8)

if (-not $SkipTunnelDownload) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  $Version = "v0.0.10"
  $ArchiveName = "tunnel-client-$Version-windows-amd64.zip"
  $BaseUrl = "https://github.com/openai/tunnel-client/releases/download/$Version"
  $DownloadRoot = Join-Path $ToolRoot "runtime\downloads\$Version"
  $InstallRoot = Join-Path $ToolRoot "runtime\tunnel-client\$Version"
  $ArchivePath = Join-Path $DownloadRoot $ArchiveName
  $SumsPath = Join-Path $DownloadRoot "SHA256SUMS.txt"
  New-Item -ItemType Directory -Path $DownloadRoot -Force | Out-Null
  New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/$ArchiveName" -OutFile $ArchivePath
  Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/SHA256SUMS.txt" -OutFile $SumsPath
  $SumLine = Get-Content -LiteralPath $SumsPath | Where-Object { $_ -match ([regex]::Escape($ArchiveName) + '$') }
  if (@($SumLine).Count -ne 1 -or $SumLine -notmatch '^([a-fA-F0-9]{64})\s+') { throw "Official archive checksum was not found." }
  $ExpectedArchiveHash = $Matches[1]
  $ObservedArchiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
  if (-not $ObservedArchiveHash.Equals($ExpectedArchiveHash, [StringComparison]::OrdinalIgnoreCase)) { throw "Tunnel-client archive checksum mismatch." }
  $ExtractRoot = Join-Path $DownloadRoot "extracted"
  if (Test-Path -LiteralPath $ExtractRoot) { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force }
  Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force
  $Candidates = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -Filter "tunnel-client.exe")
  if ($Candidates.Count -ne 1) { throw "Expected exactly one tunnel-client.exe in the official archive." }
  $ExpectedExeHash = "D893D8127EEE35070D265C1BE29BFE008F8D9FCB476E7FEBF56C8FDC6C0615C8"
  $ObservedExeHash = (Get-FileHash -LiteralPath $Candidates[0].FullName -Algorithm SHA256).Hash
  if (-not $ObservedExeHash.Equals($ExpectedExeHash, [StringComparison]::OrdinalIgnoreCase)) { throw "Tunnel-client executable checksum mismatch." }
  Copy-Item -LiteralPath $Candidates[0].FullName -Destination (Join-Path $InstallRoot "tunnel-client.exe") -Force
}

if (-not $NoDesktopShortcut) {
  $Desktop = [Environment]::GetFolderPath("Desktop")
  if ($Desktop -and (Test-Path -LiteralPath $Desktop -PathType Container)) {
    $Shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Desktop "Hybrid MCP Control.lnk"))
    $Shortcut.TargetPath = (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $ToolRoot 'scripts\Control.ps1')`""
    $Shortcut.WorkingDirectory = $ToolRoot
    $Shortcut.Save()
  }
}

Write-Output "Hybrid Workstation MCP core installed."
Write-Output "Profile root: $WorkspaceRoot"
Write-Output "Permission preset: $PermissionPreset"
Write-Output "Next: run 'Configure Tunnel.cmd' and enter your own tunnel_id and runtime API key."
