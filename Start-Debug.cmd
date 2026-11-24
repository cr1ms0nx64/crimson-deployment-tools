@echo off
set "CRIMSON_DEPLOYER_ROOT=%~dp0"
set "CRIMSON_SCRIPT=%~dp0src-wpf\app.ps1"
if not exist "%CRIMSON_SCRIPT%" set "CRIMSON_SCRIPT=%~dp0runtime\crimson-deployer-wpf-1.0.1.ps1"
echo Starte Crimson Deploy Tool Debug...
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%CRIMSON_SCRIPT%"
echo.
echo Exit Code: %ERRORLEVEL%
pause
