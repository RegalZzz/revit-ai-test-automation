#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProjectPath,
    [Parameter(Mandatory = $true)][string]$RevitInstallDir,
    [Parameter(Mandatory = $true)][string]$ModelPath,
    [string[]]$FixturePath = @(),
    [string]$TestRoot,
    [ValidateRange(10, 86400)][int]$TimeoutSeconds = 600,
    [switch]$PrepareOnly,
    [switch]$AutoTrustRunner
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = (Resolve-Path -LiteralPath $ProjectPath).Path
$projectRoot = Split-Path -Parent $project
$config = Get-Content -LiteralPath (Join-Path $projectRoot 'harness.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($config.SchemaVersion -ne 1) { throw 'Unsupported harness schema.' }
if ($config.AssemblyName -notmatch '^[A-Za-z][A-Za-z0-9_]{0,79}$' -or $config.ApplicationClass -ne "$($config.AssemblyName).RevitTestApplication") { throw 'Unexpected harness name or application class.' }
$addinId = [Guid]::Parse($config.AddInId)
$year = [int]$config.RevitVersion
if ($year -lt 2019 -or $year -gt 2026) { throw 'Unsupported Revit version.' }
$revitDirectory = (Resolve-Path -LiteralPath $RevitInstallDir).Path
foreach ($required in @('Revit.exe', 'RevitAPI.dll', 'RevitAPIUI.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $revitDirectory $required) -PathType Leaf)) { throw "Missing $required in RevitInstallDir." }
}
$model = (Resolve-Path -LiteralPath $ModelPath).Path
if (-not (Test-Path -LiteralPath $model -PathType Leaf) -or [IO.Path]::GetExtension($model) -ine '.rvt') { throw 'ModelPath must name a local RVT file.' }
$fixtures = @()
$fixtureNames = @{}
foreach ($path in $FixturePath) {
    $file = Get-Item -LiteralPath $path
    if ($file.PSIsContainer -or $fixtureNames.ContainsKey($file.Name)) { throw 'Fixture paths must be files with distinct filenames.' }
    $fixtureNames[$file.Name] = $true
    $fixtures += $file
}
if (-not $TestRoot) { $TestRoot = Join-Path $projectRoot '.local\revit-tests' }
$runId = [Guid]::NewGuid().ToString('N')
$runRoot = Join-Path ([IO.Path]::GetFullPath($TestRoot)) $runId
New-Item -ItemType Directory -Path $runRoot | Out-Null
$binaryRoot = Join-Path $runRoot 'bin'
$inputRoot = Join-Path $runRoot 'inputs'
New-Item -ItemType Directory -Path $inputRoot | Out-Null
$encoding = [Text.UTF8Encoding]::new($false)
$runPath = Join-Path $runRoot 'run.json'
$run = [ordered]@{
    SchemaVersion = 1; RunId = $runId; State = 'Preparing'; ExpectedVersion = "$year"
    PowerShellVersion = $PSVersionTable.PSVersion.ToString(); PowerShellEdition = $PSVersionTable.PSEdition
    AutoTrustRunnerRequested = [bool]$AutoTrustRunner
    ModelPath = (Join-Path $runRoot 'Model.rvt'); TestAssemblyPath = (Join-Path $binaryRoot "$($config.AssemblyName).dll")
    TestAssemblySha256 = ''; InputFiles = @(); ProcessId = 0; ProcessStartedUtc = ''; LauncherError = ''
}
function Save-RunMetadata {
    $temporary = $runPath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($run | ConvertTo-Json -Depth 6), $encoding)
    if (Test-Path -LiteralPath $runPath) {
        $previous = $runPath + '.previous'
        [IO.File]::Replace($temporary, $runPath, $previous)
        [IO.File]::Delete($previous)
    }
    else { [IO.File]::Move($temporary, $runPath) }
}
Save-RunMetadata
$process = $null
$registeredManifest = $null
$activeMarker = $null
$mutex = $null
$lockTaken = $false
$approvalWorker = $null
$approvalOutputCaptured = $false
function Capture-ApprovalOutput([switch]$WaitForExit) {
    if ($approvalWorker -and $WaitForExit -and -not $approvalWorker.HasExited) {
        $approvalWorker.WaitForExit(5000) | Out-Null
    }
    if ($approvalWorker -and $approvalWorker.HasExited -and -not $script:approvalOutputCaptured) {
        [IO.File]::WriteAllText((Join-Path $runRoot 'publisher-approval.stdout.log'), $approvalWorker.StandardOutput.ReadToEnd(), $encoding)
        [IO.File]::WriteAllText((Join-Path $runRoot 'publisher-approval.stderr.log'), $approvalWorker.StandardError.ReadToEnd(), $encoding)
        $script:approvalOutputCaptured = $true
        $approvalResultPath = Join-Path $runRoot 'publisher-approval-result.json'
        if (Test-Path -LiteralPath $approvalResultPath) {
            $approvalResult = Get-Content -LiteralPath $approvalResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host "Publisher approval status: $($approvalResult.Status); DLL prompts approved: $($approvalResult.ActionCount)"
            if ($approvalWorker.ExitCode -ne 0) {
                Write-Warning "Publisher approval helper exited with code $($approvalWorker.ExitCode); inspect publisher-approval.stderr.log and the original Revit process."
            }
        }
        else { Write-Warning 'Publisher approval helper did not produce a result; inspect its stderr log and the original Revit process.' }
    }
}
try {
    # Lock before building; preserve an active-child record across launcher timeouts.
    if (-not $PrepareOnly) {
        $mutex = [Threading.Mutex]::new($false, "Local\RevitIntegrationTest-$year")
        try { $lockTaken = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lockTaken = $true }
        if (-not $lockTaken) { throw 'Another test launcher is running for this Revit version.' }
        $addinRoot = Join-Path $env:APPDATA "Autodesk\Revit\Addins\$year"
        New-Item -ItemType Directory -Path $addinRoot -Force | Out-Null
        $activeMarker = Join-Path $addinRoot "revit-ai-test-automation-$year.active.json"
        if (Test-Path -LiteralPath $activeMarker) {
            $active = Get-Content -LiteralPath $activeMarker -Raw -Encoding UTF8 | ConvertFrom-Json
            $activeProcess = Get-Process -Id $active.ProcessId -ErrorAction SilentlyContinue
            $recordedStart = [DateTimeOffset]$active.ProcessStartedUtc
            if ($activeProcess -and $activeProcess.StartTime.ToUniversalTime().Ticks -eq $recordedStart.UtcDateTime.Ticks) {
                throw "Previous test process $($active.ProcessId) is still active. Inspect $($active.RunDirectory) before another run."
            }
        }
        if (Get-ChildItem -LiteralPath $addinRoot -Filter 'revit-ai-test-automation-*.addin' -File) {
            throw 'A prior temporary test manifest remains. Inspect its run and process before removing that exact manifest.'
        }
    }
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
    # Capture native stderr and exit status under both engines, even if the caller
    # enabled PowerShell 7's native-command error preference.
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $buildLines = @(& $dotnet build $project -c Release --output $binaryRoot "-p:RevitInstallDir=$revitDirectory" 2>&1)
        $buildExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousErrorAction }
    [IO.File]::WriteAllLines((Join-Path $runRoot 'build.log'), [string[]]$buildLines, $encoding)
    if ($buildExitCode -ne 0) { throw "Build failed. See $(Join-Path $runRoot 'build.log')" }
    if (-not (Test-Path -LiteralPath $run.TestAssemblyPath -PathType Leaf)) { throw 'Expected runner DLL was not produced.' }
    if (Get-ChildItem -LiteralPath $binaryRoot -Filter 'RevitAPI*.dll' -File) { throw 'Revit API DLLs must not be copied to the runner output. Set Private=False.' }
    $run.TestAssemblySha256 = (Get-FileHash -LiteralPath $run.TestAssemblyPath -Algorithm SHA256).Hash
    $inputPairs = @([pscustomobject]@{ Source = $model; Copy = $run.ModelPath })
    foreach ($fixture in $fixtures) { $inputPairs += [pscustomobject]@{ Source = $fixture.FullName; Copy = (Join-Path $inputRoot $fixture.Name) } }
    foreach ($pair in $inputPairs) {
        $hash = (Get-FileHash -LiteralPath $pair.Source -Algorithm SHA256).Hash
        Copy-Item -LiteralPath $pair.Source -Destination $pair.Copy
        if ((Get-FileHash -LiteralPath $pair.Copy -Algorithm SHA256).Hash -ne $hash) { throw 'An input changed while it was being copied.' }
        $run.InputFiles += [pscustomobject]@{ Source = $pair.Source; Copy = $pair.Copy; Sha256 = $hash }
    }
    $xmlAssembly = [Security.SecurityElement]::Escape($run.TestAssemblyPath)
    $manifest = @"
<?xml version="1.0" encoding="utf-8"?>
<RevitAddIns><AddIn Type="Application"><Name>$($config.AssemblyName)</Name><Assembly>$xmlAssembly</Assembly><AddInId>$addinId</AddInId><FullClassName>$($config.ApplicationClass)</FullClassName><VendorId>RITT</VendorId></AddIn></RevitAddIns>
"@
    $preparedManifest = Join-Path $runRoot 'test.addin'
    [IO.File]::WriteAllText($preparedManifest, $manifest, $encoding)
    $run.State = 'Prepared'
    Save-RunMetadata
    Write-Host "Run directory: $runRoot"
    if ($PrepareOnly) {
        [pscustomobject]@{ Status = 'PREPARED'; RunDirectory = $runRoot; RevitStarted = $false }
        return
    }
    $registeredManifest = Join-Path $addinRoot "revit-ai-test-automation-$runId.addin"
    Copy-Item -LiteralPath $preparedManifest -Destination $registeredManifest
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $revitDirectory 'Revit.exe'
    $startInfo.Arguments = '/nosplash'
    $startInfo.UseShellExecute = $false
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.EnvironmentVariables['REVIT_TEST_RUN_DIRECTORY'] = $runRoot
    $startInfo.EnvironmentVariables['REVIT_TEST_RUN_ID'] = $runId
    $process = [Diagnostics.Process]::Start($startInfo)
    $run.ProcessId = $process.Id
    $run.ProcessStartedUtc = $process.StartTime.ToUniversalTime().ToString('o')
    $run.State = 'Launched'
    Save-RunMetadata
    [IO.File]::WriteAllText($activeMarker, (@{ RunId = $runId; RunDirectory = $runRoot; ProcessId = $run.ProcessId; ProcessStartedUtc = $run.ProcessStartedUtc } | ConvertTo-Json), $encoding)
    Write-Host "Test Revit PID: $($process.Id)."
    if ($AutoTrustRunner) {
        $approvalSpec = [ordered]@{
            ProcessId=$run.ProcessId; ProcessStartedUtc=$run.ProcessStartedUtc
            AssemblyPath=$run.TestAssemblyPath; AssemblySha256=$run.TestAssemblySha256
            TimeoutSeconds=$TimeoutSeconds
            StartedSignalPath=(Join-Path $runRoot 'started.txt')
            ResultPath=(Join-Path $runRoot 'publisher-approval-result.json')
            ParentRunPath=$runPath
        }
        $approvalSpecPath = Join-Path $runRoot 'publisher-approval-spec.json'
        [IO.File]::WriteAllText($approvalSpecPath, ($approvalSpec | ConvertTo-Json), $encoding)
        $shellName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
        $approvalStart = [Diagnostics.ProcessStartInfo]::new()
        $approvalStart.FileName = Join-Path $PSHOME $shellName
        $approvalStart.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SpecPath "{1}" -ApproveAlways' -f (Join-Path $PSScriptRoot 'Approve-RevitTestDll.ps1'), $approvalSpecPath
        $approvalStart.UseShellExecute = $false
        $approvalStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $approvalStart.CreateNoWindow = $true
        $approvalStart.RedirectStandardOutput = $true
        $approvalStart.RedirectStandardError = $true
        $approvalWorker = [Diagnostics.Process]::Start($approvalStart)
        Write-Host 'Auto approval is restricted to this test process and approves every recognized DLL load prompt in that process.'
    }
    else { Write-Host 'Publisher/security prompts require manual handling unless -AutoTrustRunner was explicitly requested.' }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $process.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Capture-ApprovalOutput
        Start-Sleep -Seconds 2
    }
    Capture-ApprovalOutput
    if (-not $process.HasExited) {
        $run.State = 'TimedOut'
        $shellFileName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
        $resumeCommand = '& "{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -RunDirectory "{2}"' -f (Join-Path $PSHOME $shellFileName), (Join-Path $PSScriptRoot 'Read-RevitTestResult.ps1'), $runRoot
        throw "Timed out; process preserved. Inspect PID $($process.Id). Resume result reading with: $resumeCommand"
    }
    $run.State = 'ProcessExited'
    Save-RunMetadata
    Capture-ApprovalOutput -WaitForExit
    & (Join-Path $PSScriptRoot 'Read-RevitTestResult.ps1') -RunDirectory $runRoot
}
catch {
    if ($run.State -ne 'TimedOut') { $run.State = 'LauncherFailed' }
    $run.LauncherError = $_.Exception.Message
    Save-RunMetadata
    throw
}
finally {
    try {
        Capture-ApprovalOutput -WaitForExit
        if ($registeredManifest -and (Test-Path -LiteralPath $registeredManifest)) { Remove-Item -LiteralPath $registeredManifest }
        if ($activeMarker -and (Test-Path -LiteralPath $activeMarker)) {
            $marker = Get-Content -LiteralPath $activeMarker -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($marker.RunId -eq $runId -and ($null -eq $process -or $process.HasExited)) { Remove-Item -LiteralPath $activeMarker }
        }
    }
    finally {
        if ($lockTaken) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}
