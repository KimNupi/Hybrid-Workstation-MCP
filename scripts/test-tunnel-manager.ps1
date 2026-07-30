[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0

$ManagerPath = Join-Path $PSScriptRoot "tunnel-manager.ps1"
$Tokens = $null
$ParseErrors = $null
$ManagerAst = [Management.Automation.Language.Parser]::ParseFile(
  $ManagerPath,
  [ref]$Tokens,
  [ref]$ParseErrors
)
if (@($ParseErrors).Count -ne 0) {
  throw "tunnel-manager.ps1 has PowerShell parser errors: $($ParseErrors -join '; ')"
}

function Get-ManagerFunctionAst([string]$Name) {
  $Matches = @(
    $ManagerAst.FindAll(
      {
        param($Node)
        $Node -is [Management.Automation.Language.FunctionDefinitionAst] -and
          $Node.Name -ceq $Name
      },
      $true
    )
  )
  if ($Matches.Count -ne 1) { throw "Expected exactly one manager function named $Name." }
  return $Matches[0]
}

foreach ($FunctionName in @(
  "Test-HybridManagedStatusActive",
  "Invoke-HybridBoundedWorkers",
  "Get-HybridStartAllPlan",
  "Invoke-HybridLifecycleBatch"
)) {
  Invoke-Expression (Get-ManagerFunctionAst $FunctionName).Extent.Text
}

$SharedState = [hashtable]::Synchronized(@{ Active = 0; MaximumActive = 0 })
$Requests = @(
  for ($Index = 0; $Index -lt 8; $Index += 1) {
    [pscustomobject]@{ index = $Index; profileId = "profile-$Index"; state = $SharedState }
  }
)
$SyntheticWorker = {
  param([object]$Request)

  [Threading.Monitor]::Enter($Request.state.SyncRoot)
  try {
    $Request.state.Active = [int]$Request.state.Active + 1
    if ([int]$Request.state.Active -gt [int]$Request.state.MaximumActive) {
      $Request.state.MaximumActive = [int]$Request.state.Active
    }
  } finally {
    [Threading.Monitor]::Exit($Request.state.SyncRoot)
  }

  try {
    Start-Sleep -Milliseconds 150
    if ([int]$Request.index -eq 4) { throw "synthetic worker failure" }
    [pscustomobject]@{
      index = [int]$Request.index
      profileId = [string]$Request.profileId
      success = $true
      exitCode = 0
      output = "synthetic success"
      error = $null
      value = [pscustomobject]@{ ordinal = [int]$Request.index }
    }
  } finally {
    [Threading.Monitor]::Enter($Request.state.SyncRoot)
    try { $Request.state.Active = [int]$Request.state.Active - 1 }
    finally { [Threading.Monitor]::Exit($Request.state.SyncRoot) }
  }
}

$WorkerResults = @(Invoke-HybridBoundedWorkers -Requests $Requests -ThrottleLimit 3 -WorkerScript $SyntheticWorker)
if ($WorkerResults.Count -ne $Requests.Count) { throw "Bounded workers did not preserve one result per request." }
if ((@($WorkerResults | ForEach-Object { [string]$_.profileId }) -join "|") -cne (@($Requests | ForEach-Object { [string]$_.profileId }) -join "|")) {
  throw "Bounded workers did not preserve request order."
}
if ([int]$SharedState.MaximumActive -ne 3) {
  throw "Bounded workers used $($SharedState.MaximumActive) concurrent workers instead of 3."
}
$SyntheticFailure = @($WorkerResults | Where-Object { [int]$_.index -eq 4 })
if ($SyntheticFailure.Count -ne 1 -or [bool]$SyntheticFailure[0].success -or [string]::IsNullOrWhiteSpace([string]$SyntheticFailure[0].error)) {
  throw "A bounded worker failure did not remain isolated in one result."
}
$EmptyResults = @(Invoke-HybridBoundedWorkers -Requests @() -ThrottleLimit 3 -WorkerScript { throw "empty batch ran" })
if ($EmptyResults.Count -ne 0) { throw "An empty bounded batch returned results." }

$CallerRunspaceId = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
$SingleResults = @(Invoke-HybridBoundedWorkers -Requests @(
  [pscustomobject]@{ index = 0; profileId = "single-profile" }
) -ThrottleLimit 3 -WorkerScript {
  param([object]$Request)
  [pscustomobject]@{
    index = [int]$Request.index
    profileId = [string]$Request.profileId
    success = $true
    exitCode = 0
    output = ""
    error = $null
    value = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
  }
})
if ($SingleResults.Count -ne 1 -or [string]$SingleResults[0].value -cne $CallerRunspaceId) {
  throw "A single-profile worker did not execute directly in the caller runspace."
}

$Plan = Get-HybridStartAllPlan -StatusRecords @(
  [pscustomobject]@{ id = "ready"; error = $null; status = [pscustomobject]@{ running = $true; supervised = $true; desiredRunning = $true; stopRequested = $false; recoveryState = "ready" } }
  [pscustomobject]@{ id = "recovering"; error = $null; status = [pscustomobject]@{ running = $false; supervised = $false; desiredRunning = $true; stopRequested = $false; recoveryState = "backoff" } }
  [pscustomobject]@{ id = "stopped"; error = $null; status = [pscustomobject]@{ running = $false; supervised = $false; desiredRunning = $false; stopRequested = $false; recoveryState = $null } }
  [pscustomobject]@{ id = "unverified"; error = "synthetic status failure"; status = $null }
)
if ((@($Plan.activeProfileIds) -join "|") -cne "ready|recovering") {
  throw "Start-all planning did not skip exactly the active and recovering profiles."
}
if ((@($Plan.targetProfileIds) -join "|") -cne "stopped|unverified") {
  throw "Start-all planning did not retain stopped and unverified profiles."
}

$script:ControlScript = "synthetic-control.ps1"
$script:PowerShellPath = "synthetic-powershell.exe"
$FullyHandled = @(
  Invoke-HybridLifecycleBatch `
    -ProfileIds @() `
    -LifecycleAction start `
    -OperationName "synthetic-start-all" `
    -SkippedCount 4 `
    -TotalProfileCount 4 `
    -ThrottleLimit 3 `
    -WorkerScript { throw "fully handled batch ran a worker" }
)
if (($FullyHandled -join [Environment]::NewLine) -cnotmatch "4/4 profile\(s\) handled; 4 skipped, 0 succeeded") {
  throw "A fully active batch did not complete without workers."
}

$PartialFailed = $false
try {
  Invoke-HybridLifecycleBatch `
    -ProfileIds @("alpha", "beta", "gamma") `
    -LifecycleAction start `
    -OperationName "synthetic-start-all" `
    -SkippedCount 1 `
    -TotalProfileCount 4 `
    -ThrottleLimit 3 `
    -WorkerScript {
      param([object]$Request)
      $Failed = [string]$Request.profileId -ceq "beta"
      [pscustomobject]@{
        index = [int]$Request.index
        profileId = [string]$Request.profileId
        success = -not $Failed
        exitCode = if ($Failed) { 23 } else { 0 }
        output = if ($Failed) { "synthetic lifecycle failure" } else { "synthetic lifecycle success" }
        error = $null
        value = $null
      }
    }
} catch {
  $PartialFailed = $true
  $Message = [string]$_.Exception.Message
  if ($Message -cnotmatch "3/4 profile\(s\) handled" -or $Message -cnotmatch "\[beta\].*synthetic lifecycle failure") {
    throw "Partial lifecycle failure did not retain aggregate and profile-scoped detail."
  }
}
if (-not $PartialFailed) { throw "A partial lifecycle failure did not fail the aggregate action." }

$AssignmentMatches = @(
  $ManagerAst.FindAll(
    {
      param($Node)
      $Node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $Node.Left.Extent.Text -ceq '$HybridLifecycleWorkerScript'
    },
    $true
  )
)
if ($AssignmentMatches.Count -ne 1) { throw "Expected exactly one lifecycle worker assignment." }
Invoke-Expression $AssignmentMatches[0].Extent.Text
$FixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ("hybrid-tunnel-manager-test-" + [guid]::NewGuid().ToString("N"))
try {
  New-Item -ItemType Directory -Path $FixtureRoot -Force | Out-Null
  $FixtureControl = Join-Path $FixtureRoot "fixture-control.ps1"
  [IO.File]::WriteAllText(
    $FixtureControl,
    @'
param([string]$Action, [string]$ProfileId)
if ($Action -cne "start") { [Console]::Error.WriteLine("unexpected action"); exit 31 }
if ($ProfileId -ceq "fixture-fail") { [Console]::Error.WriteLine("fixture failure: $ProfileId"); exit 23 }
Write-Output "fixture success: $ProfileId"
'@,
    [Text.UTF8Encoding]::new($false)
  )
  $ActualResults = @(Invoke-HybridBoundedWorkers -Requests @(
    [pscustomobject]@{ index = 0; profileId = "fixture-alpha"; action = "start"; controlScript = $FixtureControl; powerShellPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source }
    [pscustomobject]@{ index = 1; profileId = "fixture-fail"; action = "start"; controlScript = $FixtureControl; powerShellPath = (Get-Command powershell.exe -CommandType Application -ErrorAction Stop).Source }
  ) -ThrottleLimit 2 -WorkerScript $HybridLifecycleWorkerScript)
  if ($ActualResults.Count -ne 2 -or -not [bool]$ActualResults[0].success -or [int]$ActualResults[1].exitCode -ne 23) {
    throw "The real child PowerShell lifecycle worker did not preserve exit results."
  }
} finally {
  Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

. (Join-Path $PSScriptRoot "profile-registry.ps1")
$Existing = @(
  [pscustomobject]@{
    Id = "alpha"
    ProfilePath = "C:\HybridProfiles\Alpha\tools\chatgpt-hybrid-mcp\profile.json"
    ProfileSha256 = ("a" * 64)
    RepoRoot = "C:\HybridProfiles\Alpha"
    HttpPort = 2098
  }
)
$Merged = @(Merge-HybridProfileRegistryEntry `
  -ExistingProfiles $Existing `
  -ProfileId "beta" `
  -ProfilePath "C:\HybridProfiles\Beta\tools\chatgpt-hybrid-mcp\profile.json" `
  -ProfileSha256 ("b" * 64) `
  -RepoRoot "C:\HybridProfiles\Beta" `
  -HttpPort 2099)
if ($Merged.Count -ne 2 -or [string]$Merged[0].id -cne "alpha" -or [string]$Merged[1].id -cne "beta") {
  throw "Registry merge did not preserve the existing profile before the new profile."
}
foreach ($Conflict in @(
  @{ Id = "beta"; Root = "C:\HybridProfiles\Beta"; Port = 2098; Fragment = "reuses registered httpPort" },
  @{ Id = "beta"; Root = "C:\HybridProfiles\Alpha\Nested"; Port = 2099; Fragment = "must not overlap" },
  @{ Id = "alpha"; Root = "C:\HybridProfiles\Alpha"; Port = 2098; Fragment = "already registered" }
)) {
  $Failed = $false
  try {
    Merge-HybridProfileRegistryEntry `
      -ExistingProfiles $Existing `
      -ProfileId ([string]$Conflict.Id) `
      -ProfilePath (Join-Path ([string]$Conflict.Root) "tools\chatgpt-hybrid-mcp\profile.json") `
      -ProfileSha256 ("c" * 64) `
      -RepoRoot ([string]$Conflict.Root) `
      -HttpPort ([int]$Conflict.Port) | Out-Null
  } catch {
    $Failed = $true
    if ([string]$_.Exception.Message -cnotmatch [regex]::Escape([string]$Conflict.Fragment)) {
      throw "Registry merge returned the wrong conflict detail."
    }
  }
  if (-not $Failed) { throw "Registry merge accepted an expected conflict." }
}

Write-Output "TUNNEL_MANAGER_TEST_OK"
