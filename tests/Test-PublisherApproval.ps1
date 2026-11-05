#Requires -Version 5.1
[CmdletBinding()]
param([string]$TestRoot = (Join-Path ([IO.Path]::GetTempPath()) ('revit-publisher-tests-' + [Guid]::NewGuid().ToString('N'))))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
$helper = Join-Path $repository 'scripts\Approve-RevitTestDll.ps1'
$encoding = [Text.UTF8Encoding]::new($false)
$root = [IO.Path]::GetFullPath($TestRoot)
if (Test-Path -LiteralPath $root) { throw 'Use a new, dedicated test directory.' }
New-Item -ItemType Directory -Path $root | Out-Null
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$fixtureExe = Join-Path $root 'Revit.exe'
# The synthetic executable needs this name to exercise the real PID/name check.
# It does not load Revit, change DLL trust, or open a model.
& $compiler /nologo /target:winexe /platform:x64 "/out:$fixtureExe" "/win32manifest:$(Join-Path $PSScriptRoot 'fixtures\PublisherDialogProcess.manifest')" (Join-Path $PSScriptRoot 'fixtures\PublisherDialogProcess.cs')
if ($LASTEXITCODE -ne 0) { throw 'Could not compile the native-dialog test double.' }
$shellName = if ($PSVersionTable.PSVersion.Major -ge 7) { 'pwsh.exe' } else { 'powershell.exe' }
$testProcesses = [Collections.Generic.List[object]]::new()
$assertionCount = 0

function Assert-Test([bool]$condition, [string]$message) {
    if (-not $condition) { throw "FAIL: $message. Evidence: $root" }
    $script:assertionCount++
}

function New-TestCase([string]$name, [string]$mode, [int]$timeout = 3) {
    $directory = Join-Path $root $name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $runner = Join-Path $directory 'Runner.dll'
    [IO.File]::WriteAllText($runner, 'Synthetic bytes, never loaded.', $encoding)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $fixtureExe
    $start.Arguments = '"{0}" {1}' -f $directory, $mode
    $start.UseShellExecute = $false
    # The synthetic dialogs must be visible for their UI Automation provider;
    # helper consoles remain hidden.
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $process = [Diagnostics.Process]::Start($start)
    $testProcesses.Add($process)
    $spec = [ordered]@{
        ProcessId=$process.Id; ProcessStartedUtc=$process.StartTime.ToUniversalTime().ToString('o')
        AssemblyPath=$runner; AssemblySha256=(Get-FileHash -LiteralPath $runner -Algorithm SHA256).Hash
        TimeoutSeconds=$timeout; StartedSignalPath=(Join-Path $directory 'started.txt')
        ResultPath=(Join-Path $directory 'approval-result.json')
    }
    return [pscustomobject]@{ Directory=$directory; Process=$process; Spec=$spec; SpecPath=(Join-Path $directory 'spec.json') }
}

function Invoke-TestHelper($case, [bool]$approve = $true) {
    [IO.File]::WriteAllText($case.SpecPath, ($case.Spec | ConvertTo-Json), $encoding)
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Join-Path $PSHOME $shellName
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -SpecPath "{1}"' -f $helper, $case.SpecPath
    if ($approve) { $start.Arguments += ' -ApproveAlways' }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $worker = [Diagnostics.Process]::Start($start)
    $testProcesses.Add($worker)
    if (-not $worker.WaitForExit(25000)) { throw "Helper did not finish: $($case.Directory)" }
    $stdout = $worker.StandardOutput.ReadToEnd()
    $stderr = $worker.StandardError.ReadToEnd()
    [IO.File]::WriteAllText((Join-Path $case.Directory 'stdout.log'), $stdout, $encoding)
    [IO.File]::WriteAllText((Join-Path $case.Directory 'stderr.log'), $stderr, $encoding)
    $result = $null
    if (Test-Path -LiteralPath $case.Spec.ResultPath) {
        $result = Get-Content -LiteralPath $case.Spec.ResultPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    return [pscustomobject]@{ ExitCode=$worker.ExitCode; Result=$result; Stderr=$stderr }
}

try {
    $distractor = New-TestCase 'other-process' 'single' 20
    $sequence = New-TestCase 'sequence' 'sequence' 20
    $outcome = Invoke-TestHelper $sequence
    Assert-Test ($outcome.ExitCode -eq 0) "Sequence helper failed: $($outcome.Stderr)"
    Assert-Test ($outcome.Result.Status -eq 'RunnerStartedAfterInvoke') 'Runner signal is recognized after process exit'
    Assert-Test ($outcome.Result.ActionCount -eq 4) 'All four DLL prompts were invoked'
    Assert-Test (@($outcome.Result.ApprovedDlls | Where-Object { $_.Method -in @('InvokePattern', 'TDM_CLICK_BUTTON') }).Count -eq 4) 'Every click uses a control invocation method'
    $clicks = @(Get-Content -LiteralPath (Join-Path $sequence.Directory 'clicks.log') -Encoding UTF8)
    Assert-Test ($clicks.Count -eq 4 -and @($clicks | Where-Object { -not $_.EndsWith('|1001') }).Count -eq 0) 'Only Always Load was clicked'
    Assert-Test ($clicks[0] -match 'OtherBefore.dll' -and $clicks[2] -match 'OtherAfter.dll') 'Other DLLs before and three seconds after runner startup were handled'
    Assert-Test ($outcome.Result.ApprovedDlls[3].DllPaths.Count -eq 0) 'Unusual DLL path formatting does not prevent control invocation'
    Assert-Test (@(Get-ChildItem -LiteralPath $sequence.Directory -Filter '*.intent.json').Count -eq 4) 'Each invocation has its own intent'
    Assert-Test (-not (Test-Path -LiteralPath (Join-Path $distractor.Directory 'clicks.log'))) 'Other Revit process was not touched'

    $fallback = New-TestCase 'button-name-fallback' 'fallback'
    $outcome = Invoke-TestHelper $fallback
    Assert-Test ($outcome.ExitCode -eq 0 -and $outcome.Result.ActionCount -eq 1) 'Button names work when control IDs differ'
    Assert-Test ((Get-Content -LiteralPath (Join-Path $fallback.Directory 'clicks.log') -Encoding UTF8).EndsWith('|2001')) 'Localized Always Load control was invoked'

    $standard = New-TestCase 'standard-buttons' 'standard-buttons'
    $outcome = Invoke-TestHelper $standard
    Assert-Test ($outcome.ExitCode -eq 0 -and $outcome.Result.ActionCount -eq 1) 'Standard DLL buttons are handled'
    Assert-Test ((Get-Content -LiteralPath (Join-Path $standard.Directory 'clicks.log') -Encoding UTF8).EndsWith('|1001')) 'Standard Always Load button was actually clicked'

    $observe = New-TestCase 'observe' 'single'
    $outcome = Invoke-TestHelper $observe $false
    Assert-Test ($outcome.ExitCode -eq 0 -and $outcome.Result.Status -eq 'ObservedOnly') 'Observation mode identifies the prompt'
    Assert-Test ($outcome.Result.ActionCount -eq 0 -and -not (Test-Path -LiteralPath (Join-Path $observe.Directory 'clicks.log'))) 'Observation mode never clicks'

    foreach ($mode in @('wrong-button', 'non-dll')) {
        $case = New-TestCase $mode $mode 2
        $outcome = Invoke-TestHelper $case
        Assert-Test ($outcome.ExitCode -eq 0 -and $outcome.Result.Status -eq 'TimedOut' -and $outcome.Result.ActionCount -eq 0) "$mode is not invoked"
        Assert-Test (-not $case.Process.HasExited) "$mode process is preserved on timeout"
    }

    $stopped = New-TestCase 'launcher-stopped' 'single' 900
    $runPath = Join-Path $stopped.Directory 'run.json'
    [IO.File]::WriteAllText($runPath, '{"State":"TimedOut"}', $encoding)
    $stopped.Spec.ParentRunPath = $runPath
    $outcome = Invoke-TestHelper $stopped
    Assert-Test ($outcome.ExitCode -eq 0 -and $outcome.Result.Status -eq 'LauncherStopped' -and -not $outcome.Result.ActionInvoked) 'Launcher timeout prevents further approvals'

    $identity = New-TestCase 'wrong-start-time' 'idle'
    $identity.Spec.ProcessStartedUtc = ([DateTimeOffset]$identity.Spec.ProcessStartedUtc).AddSeconds(-1).ToString('o')
    $outcome = Invoke-TestHelper $identity
    Assert-Test ($outcome.ExitCode -ne 0 -and $outcome.Stderr -match 'start time no longer matches') 'Mismatched process identity is rejected'

    $hash = New-TestCase 'wrong-runner-hash' 'idle'
    $hash.Spec.AssemblySha256 = '0' * 64
    $outcome = Invoke-TestHelper $hash
    Assert-Test ($outcome.ExitCode -ne 0 -and $outcome.Stderr -match 'runner DLL bytes changed') 'Runner hash changes are rejected'

    $intent = New-TestCase 'existing-intent' 'idle'
    [IO.File]::WriteAllText(($intent.Spec.ResultPath + '.action-0001.intent.json'), '{}', $encoding)
    $outcome = Invoke-TestHelper $intent
    Assert-Test ($outcome.ExitCode -ne 0 -and $outcome.Stderr -match 'result or intent already exists') 'Existing action intent prevents a blind retry'

    [pscustomobject]@{
        Status='PASS'; Assertions=$assertionCount; PowerShell=$PSVersionTable.PSVersion.ToString()
        EvidenceDirectory=$root; Scope='Synthetic native TaskDialogs; no real Revit or trust changes'
    } | ConvertTo-Json
}
finally {
    # Only terminate exact Process objects created by this test, never enumerate
    # or stop user Revit processes. Evidence directories remain available.
    foreach ($process in $testProcesses) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        $process.Dispose()
    }
}
