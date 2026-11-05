#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SpecPath,
    [switch]$ApproveAlways
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding UTF8 | ConvertFrom-Json
$expectedPath = (Resolve-Path -LiteralPath $spec.AssemblyPath).Path
$expectedHash = [string]$spec.AssemblySha256
if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'A specific SHA256 is required.' }
$targetId = [int]$spec.ProcessId
$recordedStart = [DateTimeOffset]$spec.ProcessStartedUtc
$timeout = [int]$spec.TimeoutSeconds
if ($targetId -le 0 -or $timeout -lt 1 -or $timeout -gt 600) { throw 'Invalid process ID or timeout.' }
$resultPath = [IO.Path]::GetFullPath($spec.ResultPath)
if ((Test-Path -LiteralPath $resultPath) -or (Test-Path -LiteralPath ($resultPath + '.intent.json'))) {
    throw 'An approval result or intent already exists; inspect it before retrying.'
}
Add-Type -AssemblyName UIAutomationClient

function Save-ApprovalResult([string]$status, [bool]$invoked, [string]$detail, [string]$dialogTitle) {
    $record = [ordered]@{
        Status=$status; ActionInvoked=$invoked; ProcessId=$targetId
        AssemblyPath=$expectedPath; AssemblySha256=$expectedHash
        PersistentTrustRequested=[bool]$ApproveAlways; DialogTitle=$dialogTitle
        Detail=$detail; Utc=[DateTime]::UtcNow.ToString('o')
    }
    [IO.File]::WriteAllText($resultPath, ($record | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [pscustomobject]$record
}

function Get-ElementById($element, [string]$id) {
    return $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
}

function Get-TargetProcess {
    $process = Get-Process -Id $targetId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    if ($process.ProcessName -ine 'Revit' -or $process.StartTime.ToUniversalTime().Ticks -ne $recordedStart.UtcDateTime.Ticks) {
        throw 'The target process name or start time no longer matches.'
    }
    return $process
}

$deadline = [DateTime]::UtcNow.AddSeconds($timeout)
$actionInvoked = $false
$approvedHandle = 0
while ([DateTime]::UtcNow -lt $deadline) {
    if ($spec.PSObject.Properties.Name -contains 'ParentRunPath') {
        $parentRun = Get-Content -LiteralPath $spec.ParentRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($parentRun.State -in @('TimedOut', 'LauncherFailed')) {
            Save-ApprovalResult 'LauncherStopped' $actionInvoked 'The original launcher stopped; no further actions permitted.' ''
            return
        }
    }
    if ($null -eq (Get-TargetProcess)) {
        $status = if ($actionInvoked) { 'InvokedAndProcessExited' } else { 'ProcessExitedWithoutAction' }
        Save-ApprovalResult $status $actionInvoked 'Verify the test runner signal/result separately.' ''
        return
    }
    if ((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -ne $expectedHash) { throw 'The approved DLL bytes changed.' }
    if ($actionInvoked -and (Test-Path -LiteralPath $spec.StartedSignalPath -PathType Leaf)) {
        Save-ApprovalResult 'RunnerStartedAfterInvoke' $true 'The expected runner wrote its startup signal.' ''
        return
    }
    if (-not $actionInvoked -and (Test-Path -LiteralPath $spec.StartedSignalPath -PathType Leaf)) {
        Save-ApprovalResult 'RunnerAlreadyStarted' $false 'No approval click was needed or performed.' ''
        return
    }
    $windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
        [System.Windows.Automation.TreeScope]::Children,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty, $targetId))
    $dialogCandidates = @()
    foreach ($window in $windows) {
        $dialogs = $window.FindAll([System.Windows.Automation.TreeScope]::Subtree,
            [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770'))
        foreach ($dialog in $dialogs) {
            $always = Get-ElementById $dialog 'CommandButton_1001'
            $once = Get-ElementById $dialog 'CommandButton_1002'
            $deny = Get-ElementById $dialog 'CommandButton_1003'
            $content = Get-ElementById $dialog 'ContentText'
            $instruction = Get-ElementById $dialog 'MainInstruction'
            if ($null -eq $always -or $null -eq $once -or $null -eq $deny -or $null -eq $content -or $null -eq $instruction) { continue }
            $buttonName = $always.Current.Name.Replace('&', '').Trim()
            # English / simplified Chinese labels observed on unsigned-addin prompts.
            if ($buttonName -notmatch '^(?:Always\s*Load|\u603B\u662F(?:\u8F7D\u5165|\u52A0\u8F7D)|\u59CB\u7EC8(?:\u8F7D\u5165|\u52A0\u8F7D))$') { continue }
            if ($instruction.Current.Name -notmatch '(?i)publisher|\u53D1\u5E03\u8005') { continue }
            # Some providers escape backslashes/newlines. Parse the DLL field first;
            # decoding \n globally would corrupt ordinary folder names like \new.
            $text = $content.Current.Name
            $paths = @([regex]::Matches($text, '(?im)[:\uFF1A]\s*(?<path>[A-Z]:\\[^\r\n]+?\.dll)(?=\s*(?:[\r\n]|$|\\[nr]))') | ForEach-Object { $_.Groups['path'].Value.Trim().Replace('\\', '\') })
            if ($paths.Count -ne 1 -or -not [string]::Equals($paths[0], $expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                Save-ApprovalResult 'BlockedByOtherAddin' $actionInvoked 'The dialog DLL path is absent, ambiguous or outside the explicit expected DLL.' $dialog.Current.Name
                return
            }
            $dialogCandidates += [pscustomobject]@{ Dialog=$dialog; Button=$always; Title=$dialog.Current.Name; Handle=$dialog.Current.NativeWindowHandle }
        }
    }
    if ($dialogCandidates.Count -gt 1) { throw 'Multiple matching dialogs; refusing an ambiguous action.' }
    if ($dialogCandidates.Count -eq 1) {
        $match = $dialogCandidates[0]
        if (-not $ApproveAlways) {
            Save-ApprovalResult 'ObservedOnly' $false 'Matching process, DLL path, SHA256 and Always Load control. No action performed.' $match.Title
            return
        }
        if ($actionInvoked) {
            if ($match.Handle -ne $approvedHandle) { throw 'Another matching dialog appeared after the single permitted invocation.' }
        }
        else {
            if ($null -eq (Get-TargetProcess)) { throw 'The target exited before invocation.' }
            if ((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -ne $expectedHash) { throw 'DLL changed before invocation.' }
            if (-not $match.Button.Current.IsEnabled -or $match.Dialog.Current.ProcessId -ne $targetId) { throw 'The matched dialog is no longer actionable.' }
            $pattern = $match.Button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
            $approvedHandle = $match.Handle
            # Set this before invoking: an exception leaves the outcome uncertain; never retry blindly.
            $actionInvoked = $true
            [IO.File]::WriteAllText($resultPath + '.intent.json', (@{ProcessId=$targetId;AssemblyPath=$expectedPath;Sha256=$expectedHash;Button=$match.Button.Current.Name} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
            try { $pattern.Invoke() }
            catch {
                Save-ApprovalResult 'InvocationOutcomeUnknown' $true $_.Exception.Message $match.Title
                throw
            }
        }
    }
    Start-Sleep -Milliseconds 400
}
Save-ApprovalResult 'TimedOut' $actionInvoked 'Target process preserved; inspect the original run before retrying.' ''
