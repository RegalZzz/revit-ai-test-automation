#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RunDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$runRoot = (Resolve-Path -LiteralPath $RunDirectory).Path
$run = Get-Content -LiteralPath (Join-Path $runRoot 'run.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$targetId = [int]$run.ProcessId
if ($targetId -le 0) { throw 'The run does not identify a launched test process.' }
$recordedStart = [DateTimeOffset]$run.ProcessStartedUtc
$process = Get-Process -Id $targetId -ErrorAction SilentlyContinue
if ($null -eq $process) { throw 'The recorded test process has exited; inspect its saved logs.' }
if ($process.ProcessName -ine 'Revit' -or $process.StartTime.ToUniversalTime().Ticks -ne $recordedStart.UtcDateTime.Ticks) {
    throw 'The target process name or start time no longer matches.'
}

Add-Type -AssemblyName UIAutomationClient
$windowCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $targetId)
$dialogCondition = [System.Windows.Automation.PropertyCondition]::new(
    [System.Windows.Automation.AutomationElement]::ClassNameProperty, '#32770')
$windows = [System.Windows.Automation.AutomationElement]::RootElement.FindAll(
    [System.Windows.Automation.TreeScope]::Children, $windowCondition)
$windowRecords = [Collections.Generic.List[object]]::new()
$dialogRecords = [Collections.Generic.List[object]]::new()
foreach ($window in $windows) {
    $windowRecords.Add([pscustomobject]@{
        Title=$window.Current.Name; ClassName=$window.Current.ClassName
        ProcessId=$window.Current.ProcessId; Handle=$window.Current.NativeWindowHandle
    })
    # Observe only this process's native modal dialogs, never the full Ribbon.
    foreach ($dialog in $window.FindAll([System.Windows.Automation.TreeScope]::Subtree, $dialogCondition)) {
        $controls = [Collections.Generic.List[object]]::new()
        foreach ($element in $dialog.FindAll([System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition)) {
            $controls.Add([pscustomobject]@{
                AutomationId=$element.Current.AutomationId; Name=$element.Current.Name
                ControlType=$element.Current.ControlType.ProgrammaticName
                IsEnabled=$element.Current.IsEnabled; ProcessId=$element.Current.ProcessId
            })
        }
        $dialogRecords.Add([pscustomobject]@{
            Title=$dialog.Current.Name; ClassName=$dialog.Current.ClassName
            ProcessId=$dialog.Current.ProcessId; Handle=$dialog.Current.NativeWindowHandle
            Controls=$controls.ToArray()
        })
    }
}
# This script never invokes controls, changes focus, sends keys, or writes files.
[pscustomobject]@{
    ReadOnly=$true; ProcessId=$targetId; ProcessStartedUtc=$recordedStart.ToString('o')
    Status=if ($dialogRecords.Count -eq 0) { 'NoModalDialogObserved' } else { 'ModalDialogsObserved' }
    Windows=$windowRecords.ToArray(); Dialogs=$dialogRecords.ToArray()
} | ConvertTo-Json -Depth 8
