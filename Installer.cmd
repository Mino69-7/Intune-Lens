@echo off
setlocal
title Intune Lens - setup
rem Intune Lens setup for the current user (double-click, once).
rem 1. Finds PowerShell 7 (offers to install it with winget if missing).
rem 2. Unblocks this folder's files ("downloaded from the Internet" mark); the execution policy is left as is.
rem 3. Runs setup\Install-IntuneLens.ps1: Microsoft Graph module (with consent) and the "Intune Lens" shortcut.
cd /d "%~dp0"
set "IAL_ROOT=%~dp0"
set "PWSH="
for %%P in (pwsh.exe) do set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined PWSH goto :run

echo.
echo  PowerShell 7 is required and is not installed on this computer.
echo  It installs with winget (Microsoft tool included in Windows):
echo      winget install --id Microsoft.PowerShell --exact --source winget
echo  Windows may ask for administrator approval. On a company computer,
echo  use the Company Portal or your IT department instead.
echo.
choice /c YN /m " Install it now"
if errorlevel 2 goto :end
winget install --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --accept-package-agreements
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined PWSH goto :run
echo.
echo  PowerShell 7 still not found: close this window, then run Installer.cmd again.
goto :end

:run
"%PWSH%" -NoLogo -NoProfile -Command "$r = $env:IAL_ROOT; $p = Get-ExecutionPolicy; if ($p -in 'Restricted', 'AllSigned') { Write-Host ('  Execution policy ' + $p + ': unsigned scripts are blocked on this computer. Check with your IT department.') -ForegroundColor Red; exit 2 }; Get-ChildItem -LiteralPath $r -Recurse -File | Unblock-File; & (Join-Path $r 'setup\Install-IntuneLens.ps1')"

:end
echo.
pause
