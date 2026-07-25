[CmdletBinding()]
param(
  [string]$OutputRoot
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3.0
$ToolRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..") -ErrorAction Stop).Path
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $ToolRoot "runtime-distribution\window-capture\win-x64"
} else {
  $OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
}
$ProjectPath = Join-Path $ToolRoot "native\window-capture\HybridWindowCapture.csproj"
$Dotnet = Get-Command dotnet.exe -CommandType Application -ErrorAction Stop
$Version = (& $Dotnet.Source --version).Trim()
if ([version]$Version -lt [version]"10.0.100") { throw "The release helper requires .NET SDK 10.0.100 or newer; found $Version." }
$PublishRoot = Join-Path $env:TEMP ("HybridWindowCapture-" + [guid]::NewGuid().ToString("N"))
try {
  $PublishOutput = @(& $Dotnet.Source publish $ProjectPath -c Release -r win-x64 --self-contained true -p:PublishAot=true -p:StripSymbols=true -p:InvariantGlobalization=true -o $PublishRoot -v minimal 2>&1)
  if ($LASTEXITCODE -ne 0) {
    throw "Native window capture publish failed: $($PublishOutput -join [Environment]::NewLine)"
  }
  Write-Verbose ($PublishOutput -join [Environment]::NewLine)
  $Executable = Join-Path $PublishRoot "HybridWindowCapture.exe"
  $Item = Get-Item -LiteralPath $Executable -ErrorAction Stop
  if ($Item.Length -lt 100000 -or $Item.Length -gt 33554432) { throw "Native window capture executable size is outside its expected range." }
  $SelfTest = (& $Executable --self-test | Out-String).Trim() | ConvertFrom-Json
  if (-not $SelfTest.ok -or [string]$SelfTest.architecture -cne "X64") { throw "Native window capture self-test failed." }
  New-Item -ItemType Directory -Path $OutputRoot -Force | Out-Null
  $Destination = Join-Path $OutputRoot "HybridWindowCapture.exe"
  Copy-Item -LiteralPath $Executable -Destination $Destination -Force
  $Hash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
  [IO.File]::WriteAllText((Join-Path $OutputRoot "HybridWindowCapture.exe.sha256"), "$Hash  HybridWindowCapture.exe`n", [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{ executable=$Destination; sha256=$Hash; bytes=(Get-Item $Destination).Length; selfTest=$SelfTest } | ConvertTo-Json -Depth 4
} finally {
  if (Test-Path -LiteralPath $PublishRoot) { Remove-Item -LiteralPath $PublishRoot -Recurse -Force }
}
