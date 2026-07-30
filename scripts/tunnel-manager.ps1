[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("profiles", "status-all", "start-all", "stop-all", "restart-all")]
  [string]$Action
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
. (Join-Path $PSScriptRoot "profile-registry.ps1")

$ControlScript = Join-Path $PSScriptRoot "Control.ps1"
$StatusScript = Join-Path $PSScriptRoot "tunnel-status.ps1"
$PowerShellPath = Get-HybridPowerShellExecutablePath
foreach ($RequiredPath in @($ControlScript, $StatusScript, $PowerShellPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath -PathType Leaf)) {
    throw "Multi-profile tunnel dependency is missing: $RequiredPath"
  }
}

function Test-HybridManagedStatusActive {
  param([object]$Status)

  if ($null -eq $Status) { return $false }
  if ([bool]$Status.running -or [bool]$Status.supervised) { return $true }
  if (-not [bool]$Status.desiredRunning -or [bool]$Status.stopRequested) { return $false }
  return [string]$Status.recoveryState -in @("starting", "backoff", "recovering", "restarting", "ready")
}

function Invoke-HybridBoundedWorkers {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Requests,

    [ValidateRange(1, 4)]
    [int]$ThrottleLimit = 3,

    [Parameter(Mandatory = $true)]
    [scriptblock]$WorkerScript
  )

  if (@($Requests).Count -eq 0) { return @() }

  if (@($Requests).Count -eq 1) {
    $Request = $Requests[0]
    $Candidate = $null
    $WorkerError = $null
    try {
      $Output = @(& $WorkerScript $Request)
      if ($Output.Count -eq 1) {
        $Candidate = $Output[0]
      } else {
        $WorkerError = "Worker returned $($Output.Count) result objects instead of one."
      }
    } catch {
      $WorkerError = [string]$_.Exception.Message
    }
    if ($null -eq $Candidate) {
      return @([pscustomobject]@{
        index = [int]$Request.index
        profileId = [string]$Request.profileId
        success = $false
        exitCode = -1
        output = ""
        error = $WorkerError
        value = $null
      })
    }
    return @([pscustomobject]@{
      index = [int]$Candidate.index
      profileId = [string]$Candidate.profileId
      success = [bool]$Candidate.success
      exitCode = [int]$Candidate.exitCode
      output = [string]$Candidate.output
      error = [string]$Candidate.error
      value = $Candidate.value
    })
  }

  $RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $ThrottleLimit)
  $Invocations = @()
  try {
    $RunspacePool.Open()
    foreach ($Request in @($Requests)) {
      $Pipeline = $null
      try {
        $Pipeline = [PowerShell]::Create()
        $Pipeline.RunspacePool = $RunspacePool
        $null = $Pipeline.AddScript($WorkerScript.ToString()).AddArgument($Request)
        $AsyncResult = $Pipeline.BeginInvoke()
        $Invocations += [pscustomobject]@{
          Request = $Request
          Pipeline = $Pipeline
          AsyncResult = $AsyncResult
          BeginError = $null
        }
      } catch {
        $BeginError = [string]$_.Exception.Message
        if ($null -ne $Pipeline) { $Pipeline.Dispose() }
        $Invocations += [pscustomobject]@{
          Request = $Request
          Pipeline = $null
          AsyncResult = $null
          BeginError = $BeginError
        }
      }
    }

    $Results = @(
      foreach ($Invocation in $Invocations) {
        $Candidate = $null
        $WorkerError = [string]$Invocation.BeginError
        if ($null -ne $Invocation.Pipeline) {
          try {
            $Output = @($Invocation.Pipeline.EndInvoke($Invocation.AsyncResult))
            if ($Output.Count -eq 1) {
              $Candidate = $Output[0]
            } else {
              $WorkerError = "Worker returned $($Output.Count) result objects instead of one."
            }
          } catch {
            $WorkerError = [string]$_.Exception.Message
          }
        }

        if ($null -eq $Candidate) {
          [pscustomobject]@{
            index = [int]$Invocation.Request.index
            profileId = [string]$Invocation.Request.profileId
            success = $false
            exitCode = -1
            output = ""
            error = $WorkerError
            value = $null
          }
        } else {
          [pscustomobject]@{
            index = [int]$Candidate.index
            profileId = [string]$Candidate.profileId
            success = [bool]$Candidate.success
            exitCode = [int]$Candidate.exitCode
            output = [string]$Candidate.output
            error = [string]$Candidate.error
            value = $Candidate.value
          }
        }
      }
    )
    return @($Results)
  } finally {
    foreach ($Invocation in $Invocations) {
      if ($null -ne $Invocation.Pipeline) { $Invocation.Pipeline.Dispose() }
    }
    $RunspacePool.Close()
    $RunspacePool.Dispose()
  }
}

$HybridStatusWorkerScript = {
  param([object]$Request)

  $ErrorActionPreference = "Stop"
  try {
    $Raw = (& ([string]$Request.statusScript) -ProfileId ([string]$Request.profileId) -Snapshot | Out-String).Trim()
    $Status = $Raw | ConvertFrom-Json -ErrorAction Stop
    [pscustomobject]@{
      index = [int]$Request.index
      profileId = [string]$Request.profileId
      success = $true
      exitCode = 0
      output = ""
      error = $null
      value = $Status
    }
  } catch {
    [pscustomobject]@{
      index = [int]$Request.index
      profileId = [string]$Request.profileId
      success = $false
      exitCode = 1
      output = ""
      error = [string]$_.Exception.Message
      value = $null
    }
  }
}

$HybridLifecycleWorkerScript = {
  param([object]$Request)

  $ErrorActionPreference = "Continue"
  try {
    $CommandOutput = @(
      & ([string]$Request.powerShellPath) `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -File ([string]$Request.controlScript) `
        -Action ([string]$Request.action) `
        -ProfileId ([string]$Request.profileId) 2>&1
    )
    $ExitCode = [int]$LASTEXITCODE
    $OutputText = (@($CommandOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
    if ($OutputText.Length -gt 8000) { $OutputText = $OutputText.Substring(0, 8000) + "..." }
    [pscustomobject]@{
      index = [int]$Request.index
      profileId = [string]$Request.profileId
      success = $ExitCode -eq 0
      exitCode = $ExitCode
      output = $OutputText
      error = $null
      value = $null
    }
  } catch {
    [pscustomobject]@{
      index = [int]$Request.index
      profileId = [string]$Request.profileId
      success = $false
      exitCode = -1
      output = ""
      error = [string]$_.Exception.Message
      value = $null
    }
  }
}

function Get-HybridAllStatusRecords {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$Profiles,

    [ValidateRange(1, 4)]
    [int]$ThrottleLimit = 4,

    [scriptblock]$WorkerScript = $HybridStatusWorkerScript
  )

  $Requests = @(
    for ($Index = 0; $Index -lt @($Profiles).Count; $Index += 1) {
      [pscustomobject]@{
        index = $Index
        profileId = [string]$Profiles[$Index].Id
        statusScript = $StatusScript
      }
    }
  )
  $Results = @(Invoke-HybridBoundedWorkers -Requests $Requests -ThrottleLimit $ThrottleLimit -WorkerScript $WorkerScript)
  if ($Results.Count -ne @($Profiles).Count) {
    throw "status-all received $($Results.Count) worker results for $(@($Profiles).Count) profiles."
  }

  return @(
    for ($Index = 0; $Index -lt @($Profiles).Count; $Index += 1) {
      $Profile = $Profiles[$Index]
      $Result = $Results[$Index]
      [pscustomobject]@{
        id = [string]$Profile.Id
        displayName = [string]$Profile.DisplayName
        permissionPreset = [string]$Profile.PermissionPreset
        status = if ([bool]$Result.success) { $Result.value } else { $null }
        error = if ([bool]$Result.success) { $null } else {
          $Detail = ([string]$Result.error).Trim()
          if ([string]::IsNullOrWhiteSpace($Detail)) { "Status worker failed with exit code $([int]$Result.exitCode)." } else { $Detail }
        }
      }
    }
  )
}

function Get-HybridStartAllPlan {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [object[]]$StatusRecords
  )

  $ActiveProfileIds = @(
    foreach ($Record in @($StatusRecords)) {
      if (
        [string]::IsNullOrWhiteSpace([string]$Record.error) -and
        (Test-HybridManagedStatusActive $Record.status)
      ) {
        [string]$Record.id
      }
    }
  )
  $ActiveSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($ProfileId in $ActiveProfileIds) { $null = $ActiveSet.Add($ProfileId) }
  [pscustomobject]@{
    activeProfileIds = $ActiveProfileIds
    targetProfileIds = @($StatusRecords | Where-Object { -not $ActiveSet.Contains([string]$_.id) } | ForEach-Object { [string]$_.id })
  }
}

function Invoke-HybridLifecycleBatch {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [string[]]$ProfileIds,

    [Parameter(Mandatory = $true)]
    [ValidateSet("start", "stop", "restart")]
    [string]$LifecycleAction,

    [Parameter(Mandatory = $true)]
    [string]$OperationName,

    [ValidateRange(0, 256)]
    [int]$SkippedCount = 0,

    [ValidateRange(0, 256)]
    [int]$TotalProfileCount = @($ProfileIds).Count,

    [ValidateRange(1, 4)]
    [int]$ThrottleLimit = 3,

    [scriptblock]$WorkerScript = $HybridLifecycleWorkerScript
  )

  if ($SkippedCount + @($ProfileIds).Count -ne $TotalProfileCount) {
    throw "$OperationName received inconsistent profile counts."
  }
  $Requests = @(
    for ($Index = 0; $Index -lt @($ProfileIds).Count; $Index += 1) {
      [pscustomobject]@{
        index = $Index
        profileId = [string]$ProfileIds[$Index]
        action = $LifecycleAction
        controlScript = $ControlScript
        powerShellPath = $PowerShellPath
      }
    }
  )
  $Results = @(Invoke-HybridBoundedWorkers -Requests $Requests -ThrottleLimit $ThrottleLimit -WorkerScript $WorkerScript)
  if ($Results.Count -ne @($ProfileIds).Count) {
    throw "$OperationName received $($Results.Count) worker results for $(@($ProfileIds).Count) profiles."
  }

  $SucceededCount = 0
  $Failures = @()
  foreach ($Result in $Results) {
    $OutputText = ([string]$Result.output).Trim()
    if ([bool]$Result.success) {
      $SucceededCount += 1
      if (-not [string]::IsNullOrWhiteSpace($OutputText)) { Write-Output $OutputText }
      continue
    }

    $Detail = ([string]$Result.error).Trim()
    if ([string]::IsNullOrWhiteSpace($Detail)) { $Detail = $OutputText }
    if ([string]::IsNullOrWhiteSpace($Detail)) {
      $Detail = "$LifecycleAction worker exited with code $([int]$Result.exitCode)."
    }
    $Prefix = "[$([string]$Result.profileId)]"
    if (-not $Detail.StartsWith($Prefix, [StringComparison]::Ordinal)) { $Detail = "$Prefix $Detail" }
    $Failures += $Detail
  }

  $CompletedCount = $SkippedCount + $SucceededCount
  if ($Failures.Count -gt 0) {
    throw "$OperationName partially completed: $CompletedCount/$TotalProfileCount profile(s) handled; $SkippedCount skipped, $SucceededCount succeeded, $($Failures.Count) failed: $($Failures -join ' | ')"
  }
  Write-Output "$OperationName completed: $CompletedCount/$TotalProfileCount profile(s) handled; $SkippedCount skipped, $SucceededCount succeeded."
}

$Registry = Get-HybridRegistry
$Profiles = @($Registry.Profiles)

switch ($Action) {
  "profiles" {
    [pscustomobject]@{
      schema = "hybrid.profileList.v1"
      profiles = @($Profiles | ForEach-Object {
        [pscustomobject]@{
          id = [string]$_.Id
          displayName = [string]$_.DisplayName
          permissionPreset = [string]$_.PermissionPreset
        }
      })
    } | ConvertTo-Json -Depth 5
  }
  "status-all" {
    $Records = @(Get-HybridAllStatusRecords -Profiles $Profiles -ThrottleLimit 4)
    [pscustomobject]@{
      schema = "hybrid.multiProfileStatus.v1"
      capturedAt = [DateTimeOffset]::UtcNow.ToString("o")
      profileCount = $Profiles.Count
      concurrencyLimit = 4
      profiles = $Records
    } | ConvertTo-Json -Depth 10
  }
  "start-all" {
    $Records = @(Get-HybridAllStatusRecords -Profiles $Profiles -ThrottleLimit 4)
    $Plan = Get-HybridStartAllPlan -StatusRecords $Records
    $ActiveIds = @($Plan.activeProfileIds)
    $TargetIds = @($Plan.targetProfileIds)
    if ($ActiveIds.Count -gt 0) {
      Write-Output "start-all skipped $($ActiveIds.Count) active or recovering profile(s): $($ActiveIds -join ', ')"
    }
    Invoke-HybridLifecycleBatch `
      -ProfileIds $TargetIds `
      -LifecycleAction "start" `
      -OperationName "start-all" `
      -SkippedCount $ActiveIds.Count `
      -TotalProfileCount $Profiles.Count `
      -ThrottleLimit 3
  }
  "stop-all" {
    Invoke-HybridLifecycleBatch `
      -ProfileIds @($Profiles | ForEach-Object { [string]$_.Id }) `
      -LifecycleAction "stop" `
      -OperationName "stop-all" `
      -TotalProfileCount $Profiles.Count `
      -ThrottleLimit 3
  }
  "restart-all" {
    $Records = @(Get-HybridAllStatusRecords -Profiles $Profiles -ThrottleLimit 4)
    $StatusFailures = @($Records | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.error) })
    if ($StatusFailures.Count -gt 0) {
      throw "restart-all stopped before mutation because $($StatusFailures.Count) profile status result(s) could not be verified."
    }
    $ActiveIds = @($Records | Where-Object { Test-HybridManagedStatusActive $_.status } | ForEach-Object { [string]$_.id })
    $StoppedCount = $Profiles.Count - $ActiveIds.Count
    Invoke-HybridLifecycleBatch `
      -ProfileIds $ActiveIds `
      -LifecycleAction "restart" `
      -OperationName "restart-all" `
      -SkippedCount $StoppedCount `
      -TotalProfileCount $Profiles.Count `
      -ThrottleLimit 3
  }
}
