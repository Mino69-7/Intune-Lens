@echo off
setlocal
title Intune Lens - installation
rem Installation d'Intune Lens pour l'utilisateur courant (double-clic, une seule fois).
rem 1. Trouve PowerShell 7 (propose de l'installer avec winget s'il manque).
rem 2. Debloque les fichiers de ce dossier (marque "telecharge d'Internet") : aucun contournement de la strategie d'execution.
rem 3. Lance setup\Install-IntuneLens.ps1 : module Microsoft Graph (avec accord) et raccourci "Intune Lens".
cd /d "%~dp0"
set "IAL_ROOT=%~dp0"
set "PWSH="
for %%P in (pwsh.exe) do set "PWSH=%%~$PATH:P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined PWSH goto :run

echo.
echo  PowerShell 7 est necessaire et n'est pas installe sur ce poste.
echo  Il s'installe avec winget (outil Microsoft fourni avec Windows) :
echo      winget install --id Microsoft.PowerShell --exact --source winget
echo  Windows peut demander une confirmation administrateur. Sur un poste d'entreprise,
echo  passez plutot par le Portail d'entreprise ou votre service informatique.
echo.
choice /c ON /m " L'installer maintenant"
if errorlevel 2 goto :end
winget install --id Microsoft.PowerShell --exact --source winget --accept-source-agreements --accept-package-agreements
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if defined PWSH goto :run
echo.
echo  PowerShell 7 reste introuvable : fermez cette fenetre, puis relancez Installer.cmd.
goto :end

:run
"%PWSH%" -NoLogo -NoProfile -Command "$r = $env:IAL_ROOT; $p = Get-ExecutionPolicy; if ($p -in 'Restricted', 'AllSigned') { Write-Host ('  Strategie d''execution ' + $p + ' : les scripts non signes sont bloques sur ce poste. Voyez avec votre service informatique.') -ForegroundColor Red; exit 2 }; Get-ChildItem -LiteralPath $r -Recurse -File | Unblock-File; & (Join-Path $r 'setup\Install-IntuneLens.ps1')"

:end
echo.
pause
