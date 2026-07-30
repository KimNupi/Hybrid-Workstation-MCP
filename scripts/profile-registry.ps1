Set-StrictMode -Version 3.0

function Get-HybridToolRoot {
  return (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
}

function Get-HybridEngineRoot {
  return (Get-HybridToolRoot)
}

function Get-HybridRunsRoot {
  return (Join-Path (Get-HybridToolRoot) "runtime")
}

function Assert-HybridRegularFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [long]$MaximumBytes,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $ResolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
  $Item = Get-Item -LiteralPath $ResolvedPath -Force -ErrorAction Stop
  if (
    $Item.PSIsContainer -or
    ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
    $Item.Length -lt 1 -or
    $Item.Length -gt $MaximumBytes
  ) {
    throw "$Description is not a bounded regular file: $ResolvedPath"
  }
  return $Item
}

function Read-HybridUtf8Json {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [long]$MaximumBytes,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $Item = Assert-HybridRegularFile -Path $Path -MaximumBytes $MaximumBytes -Description $Description
  $Utf8 = [System.Text.UTF8Encoding]::new($false, $true)
  try {
    $Raw = [IO.File]::ReadAllText($Item.FullName, $Utf8)
    $Value = $Raw | ConvertFrom-Json -ErrorAction Stop
  } catch {
    throw "$Description is not valid strict UTF-8 JSON: $($Item.FullName)"
  }
  if ($null -eq $Value) {
    throw "$Description is empty JSON: $($Item.FullName)"
  }
  return [pscustomobject]@{
    Path = $Item.FullName
    Value = $Value
  }
}

function Assert-HybridPathHasNoReparsePoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$Description
  )

  $FullPath = [IO.Path]::GetFullPath($Path)
  $Current = [IO.Path]::GetPathRoot($FullPath)
  $RelativePath = $FullPath.Substring($Current.Length)
  foreach ($Segment in $RelativePath.Split([char[]]@('\', '/'), [StringSplitOptions]::RemoveEmptyEntries)) {
    $Current = Join-Path $Current $Segment
    if (-not (Test-Path -LiteralPath $Current)) {
      throw "$Description is missing: $FullPath"
    }
    $Item = Get-Item -LiteralPath $Current -Force -ErrorAction Stop
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "$Description cannot traverse a reparse point: $($Item.FullName)"
    }
  }
  return $FullPath
}

function Test-HybridPathWithinOrEqual {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Root,

    [Parameter(Mandatory = $true)]
    [string]$Candidate
  )

  $RootPath = [IO.Path]::GetFullPath($Root)
  $CandidatePath = [IO.Path]::GetFullPath($Candidate)
  if ($CandidatePath.Equals($RootPath, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  if (
    -not $RootPath.EndsWith([string][IO.Path]::DirectorySeparatorChar, [StringComparison]::Ordinal) -and
    -not $RootPath.EndsWith([string][IO.Path]::AltDirectorySeparatorChar, [StringComparison]::Ordinal)
  ) {
    $RootPath += [IO.Path]::DirectorySeparatorChar
  }
  return $CandidatePath.StartsWith($RootPath, [StringComparison]::OrdinalIgnoreCase)
}

function Merge-HybridProfileRegistryEntry {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$ExistingProfiles,

    [Parameter(Mandatory = $true)]
    [string]$ProfileId,

    [Parameter(Mandatory = $true)]
    [string]$ProfilePath,

    [Parameter(Mandatory = $true)]
    [string]$ProfileSha256,

    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1024, 65535)]
    [int]$HttpPort,

    [switch]$AllowReplace
  )

  if ($ProfileId -cnotmatch "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$" -or $ProfileId.Length -gt 32) {
    throw "Hybrid profile id is invalid."
  }
  if (-not [IO.Path]::IsPathRooted($ProfilePath)) { throw "Hybrid profile path must be absolute." }
  if ($ProfileSha256 -cnotmatch "^[A-Fa-f0-9]{64}$") { throw "Hybrid profile hash is invalid." }

  $NewProfilePath = [IO.Path]::GetFullPath($ProfilePath)
  $NewRepoRoot = [IO.Path]::GetFullPath($RepoRoot)
  $Merged = @()
  $Replaced = $false
  foreach ($Existing in @($ExistingProfiles)) {
    $ExistingId = [string]$Existing.Id
    if ($ExistingId -ceq $ProfileId) {
      if (-not $AllowReplace) { throw "Hybrid profile $ProfileId is already registered; use Force only after reviewing the replacement." }
      if ($Replaced) { throw "Hybrid profile $ProfileId is registered more than once." }
      $Merged += [pscustomobject]@{
        id = $ProfileId
        profilePath = $NewProfilePath
        profileSha256 = $ProfileSha256
      }
      $Replaced = $true
      continue
    }

    $ExistingProfilePath = [IO.Path]::GetFullPath([string]$Existing.ProfilePath)
    if ($ExistingProfilePath.Equals($NewProfilePath, [StringComparison]::OrdinalIgnoreCase)) {
      throw "Hybrid profile path is already registered by $ExistingId."
    }
    if ([int]$Existing.HttpPort -eq $HttpPort) {
      throw "Hybrid profile $ProfileId reuses registered httpPort $HttpPort from $ExistingId."
    }
    $ExistingRepoRoot = [IO.Path]::GetFullPath([string]$Existing.RepoRoot)
    if (
      (Test-HybridPathWithinOrEqual -Root $ExistingRepoRoot -Candidate $NewRepoRoot) -or
      (Test-HybridPathWithinOrEqual -Root $NewRepoRoot -Candidate $ExistingRepoRoot)
    ) {
      throw "Hybrid profile roots must not overlap: $ExistingId, $ProfileId."
    }
    $Merged += [pscustomobject]@{
      id = $ExistingId
      profilePath = $ExistingProfilePath
      profileSha256 = [string]$Existing.ProfileSha256
    }
  }

  if (-not $Replaced) {
    $Merged += [pscustomobject]@{
      id = $ProfileId
      profilePath = $NewProfilePath
      profileSha256 = $ProfileSha256
    }
  }
  return @($Merged)
}

function Assert-HybridRestrictedCredentialAcl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $Acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
  if (-not $Acl.AreAccessRulesProtected) {
    throw "Local tunnel credential ACL inheritance must be disabled."
  }

  $CurrentUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $AllowedSids = @{
    $CurrentUserSid = $true
    "S-1-5-18" = $true
    "S-1-5-32-544" = $true
  }
  try {
    $OwnerSid = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
  } catch {
    throw "Local tunnel credential has an unreadable ACL owner."
  }
  if (-not $AllowedSids.ContainsKey($OwnerSid)) {
    throw "Local tunnel credential owner is not the current user, SYSTEM, or Administrators."
  }

  $Rules = $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
  foreach ($Rule in $Rules) {
    $RuleSid = $Rule.IdentityReference.Value
    if (-not $AllowedSids.ContainsKey($RuleSid)) {
      throw "Local tunnel credential ACL grants an unapproved principal."
    }
  }
}

function Assert-HybridControlPlaneKeyValue {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string]$Value
  )

  if (
    [string]::IsNullOrWhiteSpace($Value) -or
    $Value.Length -gt 4096 -or
    $Value -cnotmatch '^[\x21-\x7e]+$'
  ) {
    throw "CONTROL_PLANE_API_KEY must be a non-empty bounded visible-ASCII value."
  }
}

function Read-HybridControlPlaneCredentialFile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $null = Assert-HybridPathHasNoReparsePoint -Path $Path -Description "Local tunnel credential"
  $Item = Assert-HybridRegularFile -Path $Path -MaximumBytes 8192 -Description "Local tunnel credential"
  Assert-HybridRestrictedCredentialAcl -Path $Item.FullName

  $Utf8 = [Text.UTF8Encoding]::new($false, $true)
  try {
    $Raw = [IO.File]::ReadAllText($Item.FullName, $Utf8)
  } catch {
    throw "Local tunnel credential is not strict UTF-8 text."
  }
  if ($Raw.Contains([char]0)) {
    throw "Local tunnel credential contains invalid control data."
  }

  $Normalized = $Raw.Replace("`r`n", "`n")
  if ($Normalized.Contains("`r")) {
    throw "Local tunnel credential uses malformed line endings."
  }
  if ($Normalized.EndsWith("`n", [StringComparison]::Ordinal)) {
    $Normalized = $Normalized.Substring(0, $Normalized.Length - 1)
  }
  $Lines = $Normalized.Split("`n")
  $NamedLines = @($Lines | Where-Object { $_ -match '^CONTROL_PLANE_API_KEY=' })
  if ($NamedLines.Count -gt 1) {
    throw "Local tunnel credential contains duplicate CONTROL_PLANE_API_KEY entries."
  }
  if ($Lines.Count -ne 1 -or $NamedLines.Count -ne 1) {
    throw "Local tunnel credential must contain exactly one CONTROL_PLANE_API_KEY entry."
  }
  if ($Lines[0] -notmatch '^CONTROL_PLANE_API_KEY=([\x21-\x7e]+)$') {
    throw "Local tunnel credential has malformed CONTROL_PLANE_API_KEY syntax."
  }
  $Value = $Matches[1]
  Assert-HybridControlPlaneKeyValue -Value $Value
  return $Value
}

function Initialize-HybridControlPlaneCredential {
  $ExistingValue = [Environment]::GetEnvironmentVariable("CONTROL_PLANE_API_KEY", "Process")
  if ($null -ne $ExistingValue -and $ExistingValue.Length -gt 0) {
    Assert-HybridControlPlaneKeyValue -Value $ExistingValue
    return [pscustomobject]@{ Source = "process-environment" }
  }

  $ExpectedPath = [IO.Path]::GetFullPath((Join-Path (Get-HybridRunsRoot) ".env.local"))
  $Value = Read-HybridControlPlaneCredentialFile -Path $ExpectedPath
  [Environment]::SetEnvironmentVariable("CONTROL_PLANE_API_KEY", $Value, "Process")
  return [pscustomobject]@{ Source = "protected-local-file" }
}

function Get-HybridStdioRuntime {
  param(
    [string]$ToolRoot = (Get-HybridToolRoot)
  )

  $ResolvedToolRoot = (Resolve-Path -LiteralPath $ToolRoot -ErrorAction Stop).Path
  $null = Assert-HybridPathHasNoReparsePoint -Path $ResolvedToolRoot -Description "Shared MCP tool root"
  $StdioPath = Join-Path $ResolvedToolRoot "dist\stdio.js"
  $StdioFile = Assert-HybridRegularFile -Path $StdioPath -MaximumBytes 16777216 -Description "Shared MCP stdio build"
  $null = Assert-HybridPathHasNoReparsePoint -Path $StdioFile.FullName -Description "Shared MCP stdio build"

  $PackageJson = Read-HybridUtf8Json `
    -Path (Join-Path $ResolvedToolRoot "package.json") `
    -MaximumBytes 1048576 `
    -Description "Shared MCP package manifest"
  $Dependencies = @(
    foreach ($PackageName in @("@modelcontextprotocol/sdk", "zod")) {
      $ExpectedProperty = $PackageJson.Value.dependencies.PSObject.Properties[$PackageName]
      if ($null -eq $ExpectedProperty -or [string]::IsNullOrWhiteSpace([string]$ExpectedProperty.Value)) {
        throw "Shared MCP package manifest is missing runtime dependency $PackageName."
      }
      $ManifestPath = Join-Path $ResolvedToolRoot ("node_modules\" + $PackageName.Replace("/", "\") + "\package.json")
      $null = Assert-HybridPathHasNoReparsePoint -Path $ManifestPath -Description "Installed MCP runtime dependency $PackageName"
      $InstalledJson = Read-HybridUtf8Json `
        -Path $ManifestPath `
        -MaximumBytes 1048576 `
        -Description "Installed MCP runtime dependency $PackageName"
      $LockedVersion = [string]$ExpectedProperty.Value
      $InstalledVersion = [string]$InstalledJson.Value.version
      if ($InstalledVersion -cne $LockedVersion) {
        throw "Installed MCP runtime dependency $PackageName does not match package.json."
      }
      [pscustomobject]@{ Name = $PackageName; Version = $InstalledVersion }
    }
  )

  $NodeCommand = Get-Command node.exe -CommandType Application -ErrorAction Stop
  $NodePath = (Resolve-Path -LiteralPath $NodeCommand.Source -ErrorAction Stop).Path
  $NodeFile = Assert-HybridRegularFile -Path $NodePath -MaximumBytes 268435456 -Description "Node.js runtime"
  return [pscustomobject]@{
    NodePath = $NodeFile.FullName
    StdioPath = $StdioFile.FullName
    Dependencies = $Dependencies
  }
}

function Get-HybridRegistryPath {
  $ConfiguredPath = [Environment]::GetEnvironmentVariable("CHATGPT_HYBRID_PROFILE_REGISTRY", "Process")
  if ([string]::IsNullOrWhiteSpace($ConfiguredPath)) {
    $ConfiguredPath = Join-Path (Get-HybridRunsRoot) "profile_registry.json"
  } elseif (-not [IO.Path]::IsPathRooted($ConfiguredPath)) {
    throw "CHATGPT_HYBRID_PROFILE_REGISTRY must be an absolute path."
  }
  return (Resolve-Path -LiteralPath $ConfiguredPath -ErrorAction Stop).Path
}

function Assert-HybridProfileLocation {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo]$ProfileFile
  )

  $ProfileDirectory = $ProfileFile.Directory
  $ToolsDirectory = if ($ProfileDirectory) { $ProfileDirectory.Parent } else { $null }
  $RepoDirectory = if ($ToolsDirectory) { $ToolsDirectory.Parent } else { $null }
  if (
    $null -eq $ProfileDirectory -or
    $null -eq $ToolsDirectory -or
    $null -eq $RepoDirectory -or
    $ProfileFile.Name -cne "profile.json" -or
    $ProfileDirectory.Name -cne "chatgpt-hybrid-mcp" -or
    $ToolsDirectory.Name -cne "tools"
  ) {
    throw "Hybrid profile must be stored at <repo>\tools\chatgpt-hybrid-mcp\profile.json: $($ProfileFile.FullName)"
  }

  foreach ($Directory in @($ProfileDirectory, $ToolsDirectory, $RepoDirectory)) {
    if (($Directory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
      throw "Hybrid profile location cannot traverse a reparse-point directory: $($Directory.FullName)"
    }
  }

  $ExpectedPath = [IO.Path]::GetFullPath((Join-Path $RepoDirectory.FullName "tools\chatgpt-hybrid-mcp\profile.json"))
  if (-not $ProfileFile.FullName.Equals($ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Hybrid profile path does not match its derived repository location: $($ProfileFile.FullName)"
  }

  $GitPath = Join-Path $RepoDirectory.FullName ".git"
  if (-not (Test-Path -LiteralPath $GitPath -PathType Container)) {
    throw "Hybrid profile repository root is missing its canonical .git directory: $($RepoDirectory.FullName)"
  }
  $GitDirectory = Get-Item -LiteralPath $GitPath -Force -ErrorAction Stop
  if (($GitDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Hybrid profile repository .git directory cannot be a reparse point: $GitPath"
  }
  return $RepoDirectory.FullName
}

function Get-HybridRegistry {
  $ToolRoot = Get-HybridToolRoot
  $EngineRoot = Get-HybridEngineRoot
  $RunsRoot = Get-HybridRunsRoot
  $RegistryJson = Read-HybridUtf8Json -Path (Get-HybridRegistryPath) -MaximumBytes 1048576 -Description "Hybrid profile registry"
  $Registry = $RegistryJson.Value

  if ([string]$Registry.version -cne "1") {
    throw "Hybrid profile registry has an unsupported version."
  }
  $Entries = @($Registry.profiles)
  if ($Entries.Count -lt 1 -or $Entries.Count -gt 256) {
    throw "Hybrid profile registry must contain between 1 and 256 profiles."
  }

  $SeenIds = @{}
  $SeenPaths = @{}
  $SeenHttpPorts = @{}
  $Profiles = @(
    foreach ($Entry in $Entries) {
      if ($null -eq $Entry) {
        throw "Hybrid profile registry contains a null entry."
      }
      $ProfileId = [string]$Entry.id
      $ProfilePathText = [string]$Entry.profilePath
      $ExpectedHash = [string]$Entry.profileSha256
      if (
        [string]::IsNullOrWhiteSpace($ProfileId) -or
        $ProfileId -cnotmatch "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$" -or
        $ProfileId.Length -gt 32
      ) {
        throw "Hybrid profile registry contains an invalid profile id."
      }
      if ($SeenIds.ContainsKey($ProfileId)) {
        throw "Hybrid profile registry contains duplicate profile id $ProfileId."
      }
      $SeenIds[$ProfileId] = $true

      if ([string]::IsNullOrWhiteSpace($ProfilePathText) -or -not [IO.Path]::IsPathRooted($ProfilePathText)) {
        throw "Hybrid profile $ProfileId must use an absolute profilePath."
      }
      if ($ExpectedHash -cnotmatch "^[A-Fa-f0-9]{64}$") {
        throw "Hybrid profile $ProfileId has an invalid profileSha256."
      }

      $ProfileFile = Assert-HybridRegularFile -Path $ProfilePathText -MaximumBytes 262144 -Description "Hybrid profile $ProfileId"
      if ($SeenPaths.ContainsKey($ProfileFile.FullName)) {
        throw "Hybrid profile registry points multiple ids at $($ProfileFile.FullName)."
      }
      $SeenPaths[$ProfileFile.FullName] = $true

      $RepoRoot = Assert-HybridProfileLocation -ProfileFile $ProfileFile
      $ObservedHash = (Get-FileHash -LiteralPath $ProfileFile.FullName -Algorithm SHA256).Hash
      if (-not $ObservedHash.Equals($ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Hybrid profile $ProfileId failed its registry SHA-256 check."
      }

      $ProfileJson = Read-HybridUtf8Json -Path $ProfileFile.FullName -MaximumBytes 262144 -Description "Hybrid profile $ProfileId"
      $Profile = $ProfileJson.Value
      if ($Profile.id -isnot [string] -or $Profile.id -cne $ProfileId) {
        throw "Hybrid profile file id does not match registry id $ProfileId."
      }
      if (
        $Profile.displayName -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Profile.displayName) -or
        $Profile.displayName.Length -gt 80 -or
        $Profile.displayName -ne $Profile.displayName.Trim() -or
        [regex]::IsMatch($Profile.displayName, "[\x00-\x1f\x7f]")
      ) {
        throw "Hybrid profile $ProfileId has an invalid displayName."
      }
      $PermissionPreset = if ($null -eq $Profile.PSObject.Properties["permissionPreset"]) { "workstation" } else { [string]$Profile.permissionPreset }
      if ($PermissionPreset -cnotin @("readonly", "workstation")) {
        throw "Hybrid profile $ProfileId has an invalid permissionPreset."
      }

      $HttpPort = 0
      if (
        $Profile.httpPort -is [string] -or
        -not [int]::TryParse([string]$Profile.httpPort, [ref]$HttpPort) -or
        $HttpPort -lt 1024 -or
        $HttpPort -gt 65535
      ) {
        throw "Hybrid profile $ProfileId has an invalid httpPort."
      }
      if ($SeenHttpPorts.ContainsKey($HttpPort)) {
        throw "Hybrid profile $ProfileId reuses registered httpPort $HttpPort."
      }
      $SeenHttpPorts[$HttpPort] = $ProfileId

      [pscustomobject]@{
        Id = $ProfileId
        DisplayName = $Profile.displayName
        PermissionPreset = $PermissionPreset
        HttpPort = $HttpPort
        ProfilePath = $ProfileFile.FullName
        ProfileSha256 = $ObservedHash
        RepoRoot = $RepoRoot
        TunnelConfigPath = Join-Path $ProfileFile.DirectoryName "tunnel.local.yaml"
        RuntimeRoot = Join-Path $RepoRoot "artifacts\chatgpt-hybrid-mcp"
        RegistryPath = $RegistryJson.Path
      }
    }
  )

  for ($LeftIndex = 0; $LeftIndex -lt $Profiles.Count; $LeftIndex += 1) {
    for ($RightIndex = $LeftIndex + 1; $RightIndex -lt $Profiles.Count; $RightIndex += 1) {
      $Left = $Profiles[$LeftIndex]
      $Right = $Profiles[$RightIndex]
      if (
        (Test-HybridPathWithinOrEqual -Root $Left.RepoRoot -Candidate $Right.RepoRoot) -or
        (Test-HybridPathWithinOrEqual -Root $Right.RepoRoot -Candidate $Left.RepoRoot)
      ) {
        throw "Hybrid profile roots must not overlap: $($Left.Id), $($Right.Id)."
      }
    }
  }

  return [pscustomobject]@{
    RegistryPath = $RegistryJson.Path
    ToolRoot = $ToolRoot
    EngineRoot = $EngineRoot
    RunsRoot = $RunsRoot
    Profiles = $Profiles
  }
}

function Get-HybridProfile {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileId,

    [switch]$RequireTunnelConfig
  )

  if ($ProfileId -cnotmatch "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$" -or $ProfileId.Length -gt 32) {
    throw "Requested hybrid profile id is invalid."
  }
  $Registry = Get-HybridRegistry
  $Matches = @($Registry.Profiles | Where-Object { $_.Id -ceq $ProfileId })
  if ($Matches.Count -ne 1) {
    throw "Hybrid profile $ProfileId is not registered exactly once."
  }
  $Profile = $Matches[0]
  if ($RequireTunnelConfig) {
    $null = Assert-HybridRegularFile -Path $Profile.TunnelConfigPath -MaximumBytes 1048576 -Description "Tunnel config for hybrid profile $ProfileId"
  }
  return $Profile
}

function Get-HybridTunnelExecutablePath {
  $Path = Join-Path (Get-HybridRunsRoot) "tunnel-client\v0.0.10\tunnel-client.exe"
  $Item = Assert-HybridRegularFile -Path $Path -MaximumBytes 268435456 -Description "Verified tunnel-client v0.0.10"
  $ExpectedHash = "D893D8127EEE35070D265C1BE29BFE008F8D9FCB476E7FEBF56C8FDC6C0615C8"
  $ObservedHash = (Get-FileHash -LiteralPath $Item.FullName -Algorithm SHA256).Hash
  if (-not $ObservedHash.Equals($ExpectedHash, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Shared tunnel-client v0.0.10 failed its pinned SHA-256 check."
  }
  return $Item.FullName
}

function Get-HybridCommandLineOptionValues {
  param(
    [Parameter(Mandatory = $true)]
    [string]$CommandLine,

    [Parameter(Mandatory = $true)]
    [string]$OptionName
  )

  $Pattern = '(?:^|\s)' + [regex]::Escape($OptionName) + '(?:\s+|=)(?:"([^"]+)"|([^\s"]+))'
  return @(
    foreach ($Match in [regex]::Matches($CommandLine, $Pattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
      if ($Match.Groups[1].Success) {
        $Match.Groups[1].Value
      } else {
        $Match.Groups[2].Value
      }
    }
  )
}

function Get-HybridTunnelRuntimePaths {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Profile
  )

  $RuntimeRoot = Join-Path $Profile.RuntimeRoot "tunnel"
  return [pscustomobject]@{
    RuntimeRoot = $RuntimeRoot
    TunnelPidPath = Join-Path $RuntimeRoot "tunnel.pid"
    SupervisorPidPath = Join-Path $RuntimeRoot "supervisor.pid"
    HealthUrlPath = Join-Path $RuntimeRoot "health.url"
    DesiredRunningPath = Join-Path $RuntimeRoot "desired.running"
    StopRequestPath = Join-Path $RuntimeRoot "stop.requested"
    RecoveryStatePath = Join-Path $RuntimeRoot "recovery.json"
    TunnelProcessStdoutPath = Join-Path $RuntimeRoot "tunnel.process.stdout.log"
    TunnelStderrPath = Join-Path $RuntimeRoot "tunnel.stderr.log"
    TunnelLogPath = Join-Path $RuntimeRoot "tunnel.log"
    SupervisorStdoutPath = Join-Path $RuntimeRoot "supervisor.process.stdout.log"
    SupervisorStderrPath = Join-Path $RuntimeRoot "supervisor.process.stderr.log"
    SupervisorStdinPath = Join-Path $RuntimeRoot "supervisor.process.stdin"
    SupervisorLogPath = Join-Path $RuntimeRoot "supervisor.log"
  }
}

function Get-HybridTunnelSupervisorScriptPath {
  return (Join-Path $PSScriptRoot "tunnel-supervisor.ps1")
}

function Get-HybridPowerShellExecutablePath {
  $Path = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
  return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
}

function Enter-HybridProfileRegistryLock {
  param(
    [int]$TimeoutSeconds = 30
  )

  if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) {
    throw "Profile registry lock timeout is outside its bounded range."
  }
  $Mutex = [Threading.Mutex]::new($false, "Local\HybridWorkstationMcp-ProfileRegistry")
  $Acquired = $false
  try {
    try {
      $Acquired = $Mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [Threading.AbandonedMutexException] {
      $Acquired = $true
    }
    if (-not $Acquired) { throw "Timed out waiting for the hybrid profile registry lock." }
    return [pscustomobject]@{ Mutex = $Mutex; Acquired = $true }
  } catch {
    $Mutex.Dispose()
    throw
  }
}

function Exit-HybridProfileRegistryLock {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Lock
  )

  if ($Lock.Acquired) { $Lock.Mutex.ReleaseMutex() }
  $Lock.Mutex.Dispose()
}

function Enter-HybridTunnelOperationLock {
  param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileId,

    [int]$TimeoutSeconds = 30
  )

  if ($ProfileId -cnotmatch "^[a-z0-9](?:[a-z0-9-]{0,30}[a-z0-9])?$" -or $ProfileId.Length -gt 32) {
    throw "Requested hybrid profile id is invalid."
  }
  if ($TimeoutSeconds -lt 1 -or $TimeoutSeconds -gt 300) {
    throw "Tunnel operation-lock timeout is outside its bounded range."
  }

  $Mutex = [Threading.Mutex]::new($false, "Local\HybridWorkstationMcp-Tunnel-$ProfileId")
  $Acquired = $false
  try {
    try {
      $Acquired = $Mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
    } catch [Threading.AbandonedMutexException] {
      $Acquired = $true
    }
    if (-not $Acquired) {
      throw "Timed out waiting for the tunnel operation lock for profile $ProfileId."
    }
    return [pscustomobject]@{ Mutex = $Mutex; Acquired = $true }
  } catch {
    $Mutex.Dispose()
    throw
  }
}

function Exit-HybridTunnelOperationLock {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Lock
  )

  if ($Lock.Acquired) {
    $Lock.Mutex.ReleaseMutex()
  }
  $Lock.Mutex.Dispose()
}

function Stop-HybridProcessTree {
  param(
    [Parameter(Mandatory = $true)]
    [int]$TargetProcessId
  )

  $TaskkillPath = Join-Path $env:SystemRoot "System32\taskkill.exe"
  if (Test-Path -LiteralPath $TaskkillPath -PathType Leaf) {
    $StopProcess = Start-Process `
      -FilePath $TaskkillPath `
      -ArgumentList @("/PID", [string]$TargetProcessId, "/T", "/F") `
      -WindowStyle Hidden `
      -Wait `
      -PassThru
    if ($StopProcess.ExitCode -ne 0 -and (Get-Process -Id $TargetProcessId -ErrorAction SilentlyContinue)) {
      throw "Failed to stop process tree rooted at PID $TargetProcessId (taskkill exit $($StopProcess.ExitCode))."
    }
  } else {
    Stop-Process -Id $TargetProcessId -Force -ErrorAction SilentlyContinue
  }
}

function Get-HybridVerifiedTunnelProcess {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Profile,

    [Parameter(Mandatory = $true)]
    [string]$RecordedPidPath,

    [string]$ExecutablePath = (Get-HybridTunnelExecutablePath)
  )

  if (-not (Test-Path -LiteralPath $RecordedPidPath -PathType Leaf)) {
    return $null
  }
  $PidText = (Get-Content -Raw -LiteralPath $RecordedPidPath).Trim()
  if ($PidText -notmatch "^[0-9]+$") {
    throw "Refusing to use an invalid tunnel PID file for profile $($Profile.Id)."
  }

  $TunnelPid = [int]$PidText
  $Process = Get-CimInstance Win32_Process -Filter "ProcessId = $TunnelPid" -ErrorAction SilentlyContinue
  if (-not $Process) {
    return $null
  }

  $ObservedExecutable = ([string]$Process.ExecutablePath).ToLowerInvariant()
  $ExpectedExecutable = $ExecutablePath.ToLowerInvariant()
  $CommandLine = ([string]$Process.CommandLine).Replace("/", "\")
  $ObservedProfileFiles = @(Get-HybridCommandLineOptionValues -CommandLine $CommandLine -OptionName "--profile-file")
  $ObservedPidFiles = @(Get-HybridCommandLineOptionValues -CommandLine $CommandLine -OptionName "--pid.file")
  if (
    $ObservedExecutable -ne $ExpectedExecutable -or
    $ObservedProfileFiles.Count -ne 1 -or
    -not $ObservedProfileFiles[0].Equals($Profile.TunnelConfigPath, [StringComparison]::OrdinalIgnoreCase) -or
    $ObservedPidFiles.Count -ne 1 -or
    -not $ObservedPidFiles[0].Equals($RecordedPidPath, [StringComparison]::OrdinalIgnoreCase)
  ) {
    throw "PID $TunnelPid does not match tunnel profile $($Profile.Id) and its project-local PID file."
  }
  return $Process
}

function Get-HybridVerifiedTunnelSupervisorProcess {
  param(
    [Parameter(Mandatory = $true)]
    [object]$Profile,

    [Parameter(Mandatory = $true)]
    [string]$RecordedPidPath
  )

  if (-not (Test-Path -LiteralPath $RecordedPidPath -PathType Leaf)) {
    return $null
  }
  $PidText = (Get-Content -Raw -LiteralPath $RecordedPidPath).Trim()
  if ($PidText -notmatch "^[0-9]+$") {
    throw "Refusing to use an invalid tunnel supervisor PID file for profile $($Profile.Id)."
  }

  $SupervisorPid = [int]$PidText
  $Process = Get-CimInstance Win32_Process -Filter "ProcessId = $SupervisorPid" -ErrorAction SilentlyContinue
  if (-not $Process) {
    return $null
  }

  $ObservedExecutable = ([string]$Process.ExecutablePath).ToLowerInvariant()
  $ExpectedExecutable = (Get-HybridPowerShellExecutablePath).ToLowerInvariant()
  $CommandLine = ([string]$Process.CommandLine).Replace("/", "\")
  $ExpectedScript = (Get-HybridTunnelSupervisorScriptPath)
  $ObservedScripts = @(Get-HybridCommandLineOptionValues -CommandLine $CommandLine -OptionName "-File")
  $ObservedProfiles = @(Get-HybridCommandLineOptionValues -CommandLine $CommandLine -OptionName "-ProfileId")
  if (
    $ObservedExecutable -ne $ExpectedExecutable -or
    $ObservedScripts.Count -ne 1 -or
    -not $ObservedScripts[0].Equals($ExpectedScript, [StringComparison]::OrdinalIgnoreCase) -or
    $ObservedProfiles.Count -ne 1 -or
    $ObservedProfiles[0] -cne $Profile.Id
  ) {
    throw "PID $SupervisorPid does not match the tunnel supervisor for profile $($Profile.Id)."
  }
  return $Process
}

function Read-HybridHealthBaseUrl {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $true)]
    [string]$ProfileId
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Tunnel profile $ProfileId health URL file is missing."
  }
  $RawUrl = (Get-Content -Raw -LiteralPath $Path).Trim()
  $ParsedUrl = $null
  if (-not [Uri]::TryCreate($RawUrl, [UriKind]::Absolute, [ref]$ParsedUrl)) {
    throw "Tunnel profile $ProfileId wrote an invalid health URL."
  }
  if ($ParsedUrl.Scheme -ne "http" -or $ParsedUrl.Host -ne "127.0.0.1") {
    throw "Tunnel profile $ProfileId health URL is not loopback HTTP."
  }
  return $ParsedUrl.AbsoluteUri.TrimEnd("/")
}

function Read-HybridTunnelRecoveryState {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $null
  }
  return (Read-HybridUtf8Json -Path $Path -MaximumBytes 65536 -Description "Tunnel recovery state").Value
}

function Get-HybridTunnelRecoveryDecision {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [DateTimeOffset[]]$FailureTimes,

    [Parameter(Mandatory = $true)]
    [DateTimeOffset]$Now,

    [int]$WindowSeconds = 300,

    [int]$MaxRestarts = 3
  )

  if ($WindowSeconds -lt 30 -or $WindowSeconds -gt 86400) {
    throw "Tunnel recovery window is outside its bounded range."
  }
  if ($MaxRestarts -lt 1 -or $MaxRestarts -gt 10) {
    throw "Tunnel recovery restart count is outside its bounded range."
  }

  $Cutoff = $Now.AddSeconds(-$WindowSeconds)
  $RecentFailures = @($FailureTimes | Where-Object { $_ -ge $Cutoff -and $_ -le $Now.AddMinutes(1) })
  $FailureCount = $RecentFailures.Count
  if ($FailureCount -gt $MaxRestarts) {
    return [pscustomobject]@{
      RestartAllowed = $false
      Exhausted = $true
      DelaySeconds = $null
      FailureCount = $FailureCount
      RecentFailureTimes = $RecentFailures
    }
  }

  $Delays = @(2, 10, 30)
  $DelayIndex = [Math]::Max(0, [Math]::Min($FailureCount - 1, $Delays.Count - 1))
  return [pscustomobject]@{
    RestartAllowed = $true
    Exhausted = $false
    DelaySeconds = if ($FailureCount -eq 0) { 0 } else { $Delays[$DelayIndex] }
    FailureCount = $FailureCount
    RecentFailureTimes = $RecentFailures
  }
}
