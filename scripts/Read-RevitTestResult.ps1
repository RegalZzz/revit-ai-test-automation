#Requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RunDirectory)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runRoot = (Resolve-Path -LiteralPath $RunDirectory).Path
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($run.State -eq 'Prepared' -or [int]$run.ProcessId -le 0) { throw 'Prepared only: no Revit test execution is recorded.' }
$resultPath = Join-Path $runRoot 'result.json'
if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "Test incomplete: no result.json. Inspect process $($run.ProcessId) and $runRoot" }
$result = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($result.SchemaVersion -ne 1 -or $run.SchemaVersion -ne 1) { throw 'Unsupported evidence schema.' }
if ($result.RunId -ne $run.RunId -or $result.ProcessId -ne $run.ProcessId) { throw 'Result belongs to a different run or process.' }
if ([string]$result.RevitVersion -ne [string]$run.ExpectedVersion) { throw 'Actual Revit version does not match the requested version.' }
if (-not $result.Complete -or -not $result.Success -or @($result.Failures).Count -gt 0) {
    throw "Test failed or incomplete. Failures: $($result.Failures -join '; '). See $resultPath"
}
if (-not $result.RollbackVerified -or -not $result.ClosedWithoutSaving -or [int]$result.AssertionCount -lt 1) {
    throw 'Missing assertions, verified rollback or no-save document closure.'
}
if ([string]::IsNullOrWhiteSpace($result.Scope)) { throw 'Missing test scope.' }
if ([IO.Path]::GetFullPath($result.ModelPath) -ne [IO.Path]::GetFullPath($run.ModelPath)) { throw 'The result model is not the recorded copy.' }
if ([IO.Path]::GetFullPath($result.TestAssemblyPath) -ne [IO.Path]::GetFullPath($run.TestAssemblyPath)) { throw 'Unexpected test runner assembly location.' }
$assemblyHash = (Get-FileHash -LiteralPath $run.TestAssemblyPath -Algorithm SHA256).Hash
if ($assemblyHash -ne $run.TestAssemblySha256 -or $result.TestAssemblySha256 -ne $assemblyHash) { throw 'Test runner assembly hash mismatch.' }
foreach ($inputFile in @($run.InputFiles)) {
    if ((Get-FileHash -LiteralPath $inputFile.Source -Algorithm SHA256).Hash -ne $inputFile.Sha256) { throw "Source input changed: $($inputFile.Source)" }
    if ((Get-FileHash -LiteralPath $inputFile.Copy -Algorithm SHA256).Hash -ne $inputFile.Sha256) { throw "Input copy changed on disk: $($inputFile.Copy)" }
}
$processAlive = $false
$process = Get-Process -Id $run.ProcessId -ErrorAction SilentlyContinue
if ($process) {
    # PowerShell 7.5 parses ISO JSON dates as DateTime; 5.1 leaves them as strings.
    $recordedStart = [DateTimeOffset]$run.ProcessStartedUtc
    $processAlive = $process.StartTime.ToUniversalTime().Ticks -eq $recordedStart.UtcDateTime.Ticks
}
[pscustomobject]@{
    Status = 'PASS'
    Scope = $result.Scope
    RevitVersion = $result.RevitVersion
    RevitBuild = $result.RevitBuild
    AssertionCount = $result.AssertionCount
    RollbackVerified = $true
    InputHashesUnchanged = $true
    ProcessStillRunning = $processAlive
    OriginalLauncherState = $run.State
    ResultPath = $resultPath
}
