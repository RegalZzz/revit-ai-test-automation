@echo off
setlocal
rem Let the selected engine rebuild its own module paths, without inheriting another edition's paths.
set "PSModulePath="
if "%~1"=="" goto usage
where pwsh.exe >nul 2>&1
if errorlevel 1 goto windows_powershell
pwsh.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Invoke-RevitIntegrationTest.ps1" %*
exit /b %errorlevel%

:windows_powershell
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0Invoke-RevitIntegrationTest.ps1" %*
exit /b %errorlevel%

:usage
echo Usage: Run-RevitIntegrationTest.cmd -ProjectPath "test.csproj" -RevitInstallDir "Revit folder" -ModelPath "test.rvt" [-PrepareOnly]
exit /b 2
