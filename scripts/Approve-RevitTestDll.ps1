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
if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') { throw 'A specific runner SHA256 is required.' }
$targetId = [int]$spec.ProcessId
$recordedStart = [DateTimeOffset]$spec.ProcessStartedUtc
$timeout = [int]$spec.TimeoutSeconds
if ($targetId -le 0 -or $timeout -lt 1 -or $timeout -gt 86400) { throw 'Invalid process ID or timeout.' }
$resultPath = [IO.Path]::GetFullPath($spec.ResultPath)
$existingIntent = Get-ChildItem -LiteralPath ([IO.Path]::GetDirectoryName($resultPath)) -File -ErrorAction Stop |
    Where-Object { $_.Name.StartsWith([IO.Path]::GetFileName($resultPath), [StringComparison]::OrdinalIgnoreCase) -and $_.Name.EndsWith('.intent.json', [StringComparison]::OrdinalIgnoreCase) }
if ((Test-Path -LiteralPath $resultPath) -or $existingIntent) {
    throw 'An approval result or intent already exists; inspect it before retrying.'
}
Add-Type -AssemblyName UIAutomationClient
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace RevitPublisherAutomation {
    public static class DialogWindows {
        private delegate bool EnumWindow(IntPtr window, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindow callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumWindow callback, IntPtr parameter);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr window, StringBuilder name, int length);
        [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
        [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll")] private static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
        public static bool CanClick(IntPtr window, int targetId) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            return processId == targetId && name.ToString() == "Button" && IsWindowEnabled(window);
        }
        public static bool Click(IntPtr window, int targetId, int controlId) {
            // TDM_CLICK_BUTTON uses the ID read from the identified control.
            // Unlike BM_CLICK it also works while another dialog is active.
            if (!CanClick(window, targetId)) return false;
            IntPtr dialog = GetAncestor(window, 2);
            uint processId;
            GetWindowThreadProcessId(dialog, out processId);
            var name = new StringBuilder(256);
            GetClassName(dialog, name, name.Capacity);
            return processId == targetId && name.ToString() == "#32770" && controlId > 0 &&
                PostMessage(dialog, 0x400 + 102, new IntPtr(controlId), IntPtr.Zero);
        }
        private static void AddDialog(IntPtr window, int targetId, HashSet<IntPtr> dialogs) {
            uint processId;
            GetWindowThreadProcessId(window, out processId);
            if (processId != targetId) return;
            var name = new StringBuilder(256);
            GetClassName(window, name, name.Capacity);
            if (name.ToString() == "#32770") dialogs.Add(window);
        }
        public static IntPtr[] Find(int targetId) {
            var dialogs = new HashSet<IntPtr>();
            EnumWindow child = delegate(IntPtr window, IntPtr parameter) {
                AddDialog(window, targetId, dialogs);
                return true;
            };
            EnumWindow top = delegate(IntPtr window, IntPtr parameter) {
                uint processId;
                GetWindowThreadProcessId(window, out processId);
                if (processId == targetId) {
                    AddDialog(window, targetId, dialogs);
                    EnumChildWindows(window, child, IntPtr.Zero);
                }
                return true;
            };
            EnumWindows(top, IntPtr.Zero);
            return new List<IntPtr>(dialogs).ToArray();
        }
    }
}
'@

# ASCII regex escapes keep localized labels usable in Windows PowerShell 5.1.
$alwaysLabel = '^(?:Always\s*Load|\u603B\u662F(?:\u8F7D\u5165|\u52A0\u8F7D)|\u59CB\u7EC8(?:\u8F7D\u5165|\u52A0\u8F7D))$'
$onceLabel = '^(?:Load\s*Once|(?:\u8F7D\u5165|\u52A0\u8F7D)\u4E00\u6B21)$'
$denyLabel = '^(?:Do\s*Not\s*Load|\u4E0D(?:\u8F7D\u5165|\u52A0\u8F7D))$'
$approvedDlls = [Collections.Generic.List[object]]::new()
$skippedDialogs = [Collections.Generic.List[object]]::new()
$approvedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$skippedKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$actionNumber = 0
$actionInvoked = $false

function Save-ApprovalResult([string]$status, [string]$detail, [string]$dialogTitle) {
    $record = [ordered]@{
        Status=$status; ActionInvoked=$actionInvoked; ActionCount=$approvedDlls.Count
        AttemptCount=$actionNumber; ProcessId=$targetId
        AssemblyPath=$expectedPath; AssemblySha256=$expectedHash
        PersistentTrustRequested=[bool]$ApproveAlways; DialogTitle=$dialogTitle
        RunnerStarted=(Test-Path -LiteralPath $spec.StartedSignalPath -PathType Leaf)
        ApprovedDlls=$approvedDlls.ToArray(); SkippedDialogs=$skippedDialogs.ToArray()
        Detail=$detail; Utc=[DateTime]::UtcNow.ToString('o')
    }
    $temporary = $resultPath + '.tmp'
    [IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $resultPath) {
        $previous = $resultPath + '.previous'
        [IO.File]::Replace($temporary, $resultPath, $previous)
        [IO.File]::Delete($previous)
    }
    else { [IO.File]::Move($temporary, $resultPath) }
    # Keep redirected stdout small even after many approvals.
    [pscustomobject]@{ Status=$status; ActionInvoked=$actionInvoked; ActionCount=$approvedDlls.Count }
}

function Get-ElementById($element, [string]$id) {
    return $element.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::AutomationIdProperty, $id))
}

function Get-LoadButton($dialog, [string]$id, [string]$label) {
    $button = Get-ElementById $dialog $id
    if ($null -eq $button) { $button = Get-ElementById $dialog ($id.Replace('CommandButton_', 'CommandLink_')) }
    if ($null -ne $button -and $button.Current.Name.Replace('&', '').Trim() -match $label) { return $button }
    $buttons = $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($candidate in $buttons) {
        if ($candidate.Current.Name.Replace('&', '').Trim() -match $label) {
            $invoke = $null
            if ($candidate.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { return $candidate }
            if ([RevitPublisherAutomation.DialogWindows]::CanClick([IntPtr]$candidate.Current.NativeWindowHandle, $targetId)) { return $candidate }
        }
    }
    return $null
}

function Get-TargetProcess {
    $process = Get-Process -Id $targetId -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $null }
    if ($process.ProcessName -ine 'Revit' -or $process.StartTime.ToUniversalTime().Ticks -ne $recordedStart.UtcDateTime.Ticks) {
        throw 'The target process name or start time no longer matches.'
    }
    return $process
}

function Assert-ApprovalContext {
    if ($spec.PSObject.Properties.Name -contains 'ParentRunPath') {
        $parentRun = Get-Content -LiteralPath $spec.ParentRunPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($parentRun.State -in @('TimedOut', 'LauncherFailed')) { return 'LauncherStopped' }
    }
    if ($null -eq (Get-TargetProcess)) { return 'ProcessExited' }
    if ((Get-FileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash -ne $expectedHash) { throw 'The runner DLL bytes changed.' }
    return 'Active'
}

function Get-DllPaths([string]$text) {
    # Paths are evidence only. Unusual formatting must not block an identified
    # load prompt. Decode backslashes only inside a path, never global \n text.
    foreach ($item in [regex]::Matches($text, '(?im)(?<path>[A-Z]:\\[^\r\n"]+?\.dll)(?=\s*(?:["\r\n]|$|\\[nr]))')) {
        $item.Groups['path'].Value.Trim().Replace('\\', '\')
    }
}

$deadline = [DateTime]::UtcNow.AddSeconds($timeout)
Save-ApprovalResult 'Monitoring' 'Monitoring all DLL load prompts in the target Revit process.' '' | Out-Null
while ([DateTime]::UtcNow -lt $deadline) {
    $context = Assert-ApprovalContext
    if ($context -eq 'LauncherStopped') {
        Save-ApprovalResult 'LauncherStopped' 'The original launcher stopped; no further actions permitted.' ''
        return
    }
    if ($context -eq 'ProcessExited') {
        $runnerStarted = Test-Path -LiteralPath $spec.StartedSignalPath -PathType Leaf
        $status = if ($runnerStarted -and $actionInvoked) { 'RunnerStartedAfterInvoke' }
            elseif ($runnerStarted) { 'RunnerAlreadyStarted' }
            elseif ($actionInvoked) { 'InvokedAndProcessExited' }
            else { 'ProcessExitedWithoutAction' }
        Save-ApprovalResult $status 'Target process exited; verify the test runner result separately.' ''
        return
    }
    $dialogCandidates = @()
    $visibleKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    # Enumerate native HWNDs before entering UI Automation. Reading the desktop
    # automation tree can block on unrelated applications or the Revit Ribbon.
    foreach ($dialogHandle in [RevitPublisherAutomation.DialogWindows]::Find($targetId)) {
        try {
            $dialog = [System.Windows.Automation.AutomationElement]::FromHandle($dialogHandle)
            if ($dialog.Current.ProcessId -ne $targetId) { continue }
            $content = Get-ElementById $dialog 'ContentText'
            if ($null -eq $content -or $content.Current.Name -notmatch '(?i)\.dll') { continue }
            $text = $content.Current.Name
            $title = $dialog.Current.Name
            $handle = $dialog.Current.NativeWindowHandle
            $key = '{0}|{1}|{2}' -f $handle, ($dialog.GetRuntimeId() -join ','), $text
            $visibleKeys.Add($key) | Out-Null
            $always = Get-LoadButton $dialog 'CommandButton_1001' $alwaysLabel
            $once = Get-LoadButton $dialog 'CommandButton_1002' $onceLabel
            $deny = Get-LoadButton $dialog 'CommandButton_1003' $denyLabel
            if ($null -eq $always -or $null -eq $once -or $null -eq $deny) {
                if ($skippedKeys.Add($key)) {
                    $skippedDialogs.Add([pscustomobject]@{
                        Title=$title; ContentText=$text; Handle=$handle
                        Reason='The standard DLL prompt controls were not all recognized.'
                    })
                    Save-ApprovalResult 'Monitoring' 'Unrecognized DLL dialog recorded; monitoring continues.' $title | Out-Null
                }
                continue
            }
            if ($approvedKeys.Contains($key) -or -not $always.Current.IsEnabled) { continue }
            $dialogCandidates += [pscustomobject]@{
                Dialog=$dialog; Button=$always; Title=$title; Key=$key; Text=$text
                Paths=@(Get-DllPaths $text)
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] {
            # A dismissed dialog can vanish during enumeration. Rescan.
            continue
        }
    }
    # Once a dialog disappears, a later prompt may legitimately reuse its HWND.
    $approvedKeys.IntersectWith($visibleKeys)
    if ($dialogCandidates.Count -gt 0) {
        $match = $dialogCandidates[0]
        if (-not $ApproveAlways) {
            Save-ApprovalResult 'ObservedOnly' $match.Text $match.Title
            return
        }
        # Recheck after enumeration, immediately before each individual action.
        if ((Assert-ApprovalContext) -ne 'Active') { continue }
        try {
            if (-not $match.Button.Current.IsEnabled -or $match.Dialog.Current.ProcessId -ne $targetId -or
                $match.Button.Current.ProcessId -ne $targetId) { continue }
            $pattern = $null
            $useInvoke = $match.Button.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$pattern)
            $buttonHandle = [IntPtr]$match.Button.Current.NativeWindowHandle
            $nativeCommand = [regex]::Match($match.Button.Current.AutomationId, '^Command(?:Button|Link)_(\d+)$')
            if (-not $useInvoke -and (-not $nativeCommand.Success -or
                -not [RevitPublisherAutomation.DialogWindows]::CanClick($buttonHandle, $targetId))) {
                throw 'The identified control supports neither InvokePattern nor a native Button click.'
            }
        }
        catch [System.Windows.Automation.ElementNotAvailableException] { continue }
        $actionNumber++
        $intent = [pscustomobject]@{
            ProcessId=$targetId; ProcessStartedUtc=$recordedStart.ToString('o')
            DllPaths=$match.Paths; ContentText=$match.Text; DialogTitle=$match.Title
            Button=$match.Button.Current.Name; Utc=[DateTime]::UtcNow.ToString('o')
            Method=if ($useInvoke) { 'InvokePattern' } else { 'TDM_CLICK_BUTTON' }
        }
        $intentPath = '{0}.action-{1:D4}.intent.json' -f $resultPath, $actionNumber
        [IO.File]::WriteAllText($intentPath, ($intent | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        $approvedKeys.Add($match.Key) | Out-Null
        # Set before invoking. An exception leaves the outcome uncertain.
        $actionInvoked = $true
        try {
            if ($useInvoke) { $pattern.Invoke() }
            elseif (-not [RevitPublisherAutomation.DialogWindows]::Click($buttonHandle, $targetId, [int]$nativeCommand.Groups[1].Value)) { throw 'The identified native Button could not be invoked.' }
        }
        catch {
            Save-ApprovalResult 'InvocationOutcomeUnknown' $_.Exception.Message $match.Title
            throw
        }
        # Use the captured values: the controls can disappear as soon as invoked.
        $approvedDlls.Add($intent)
        Save-ApprovalResult 'Monitoring' 'DLL prompt invoked; monitoring continues for subsequent prompts.' $match.Title | Out-Null
    }
    Start-Sleep -Milliseconds 400
}
Save-ApprovalResult 'TimedOut' 'Target process preserved; inspect the original run before retrying.' ''
