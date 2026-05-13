@echo off
set CRIMSON_DEPLOYER_ROOT=C:\Users\spama\Desktop\Webapp Projekt\Tools\Deployment
echo Starte Crimson Deploy Tool Debug...
"C:\WINDOWS\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "C:\Users\spama\Desktop\Webapp Projekt\Tools\Deployment\runtime\crimson-deployer-wpf-1.0.1.ps1"
echo.
echo Exit Code: %ERRORLEVEL%
pause
