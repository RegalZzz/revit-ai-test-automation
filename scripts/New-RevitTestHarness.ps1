#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Destination,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,79}$')][string]$Name,
    [Parameter(Mandatory = $true)][ValidateRange(2019, 2026)][int]$RevitVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($Name -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { throw 'Choose a non-reserved Windows name.' }
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw "Destination already exists: $destinationPath" }
$templateRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\harness'
if (-not (Test-Path -LiteralPath $templateRoot -PathType Container)) { throw 'Harness templates are missing.' }
$framework = if ($RevitVersion -ge 2025) { 'net8.0-windows' } else { 'net48' }
$encoding = [Text.UTF8Encoding]::new($false)
New-Item -ItemType Directory -Path $destinationPath | Out-Null
foreach ($file in Get-ChildItem -LiteralPath $templateRoot -File) {
    $targetName = if ($file.Name -eq 'RevitTestHarness.csproj') { "$Name.csproj" } else { $file.Name }
    $content = [IO.File]::ReadAllText($file.FullName).Replace('__HARNESS_NAME__', $Name).Replace('__TARGET_FRAMEWORK__', $framework)
    [IO.File]::WriteAllText((Join-Path $destinationPath $targetName), $content, $encoding)
}
$config = [ordered]@{
    SchemaVersion = 1
    AssemblyName = $Name
    ApplicationClass = "$Name.RevitTestApplication"
    AddInId = [Guid]::NewGuid().ToString('D')
    RevitVersion = $RevitVersion
    TargetFramework = $framework
}
[IO.File]::WriteAllText((Join-Path $destinationPath 'harness.json'), ($config | ConvertTo-Json), $encoding)
[pscustomobject]@{
    ProjectPath = Join-Path $destinationPath "$Name.csproj"
    TargetFramework = $framework
    AddInId = $config.AddInId
    Scope = 'api-smoke; edit TestScenario.cs to add real business assertions'
}
