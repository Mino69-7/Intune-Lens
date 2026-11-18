<#
.SYNOPSIS
    Installs Intune Lens for the current user: once, without administrator rights.

.DESCRIPTION
    Started by Installer.cmd (double-click), which has already found PowerShell 7 and unblocked the folder's files.
      1. Checks PowerShell 7, the language mode and where the folder is.
      2. Offers to install the official Microsoft.Graph.Authentication module (PowerShell Gallery),
         for your account only (-Scope CurrentUser), with your consent.
      3. Creates the "Intune Lens" shortcut (with the logo) on the Desktop and in the Start menu.
    Nothing else: no registry, no scheduled task, no service, no elevation.
    Run it again if you move the folder. The tool itself (Start-IntuneAssignLens.ps1) never installs anything.
    Messages are in French when Windows is in French, in English otherwise.

.PARAMETER Uninstall
    Removes both shortcuts and offers to delete the cache, log and settings (%LOCALAPPDATA%\IntuneAssignLens).

.PARAMETER NoLaunch
    Does not offer to start the tool at the end.
#>
[CmdletBinding()]
param([switch]$Uninstall, [switch]$NoLaunch)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'Intune Lens requires PowerShell 7. Double-click Installer.cmd instead of running this script.' -ForegroundColor Red
    exit 1
}
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$fr = (Get-UICulture).TwoLetterISOLanguageName -eq 'fr'
function M([string]$Fr, [string]$En) { if ($fr) { $Fr } else { $En } }
function Write-Ok([string]$Message) { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "  [!]  $Message" -ForegroundColor Yellow }
function Write-Bad([string]$Message) { Write-Host "  [X]  $Message" -ForegroundColor Red }
function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { M '[O/n]' '[Y/n]' } else { M '[o/N]' '[y/N]' }
    $a = Read-Host "  $Question $hint"
    if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
    return ($a.Trim() -match '^(o|oui|y|yes)$')
}

$root = Split-Path -Parent $PSScriptRoot
$start = Join-Path $root 'Start-IntuneAssignLens.ps1'
$icon = Join-Path $root 'assets\intune-lens.ico'
$appName = 'Intune Lens'
$links = @(
    [Environment]::GetFolderPath('Desktop'),
    [Environment]::GetFolderPath('Programs')
) | Where-Object { $_ } | ForEach-Object { Join-Path $_ "$appName.lnk" }

Write-Host ''
Write-Host "  $appName : $(if ($Uninstall) { M 'désinstallation' 'uninstall' } else { M 'installation' 'setup' })" -ForegroundColor Cyan
Write-Host "  $(M 'Dossier' 'Folder') : $root"
Write-Host ''

# ------------------------------------------------------------------ Uninstall
if ($Uninstall) {
    foreach ($l in $links) {
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l; Write-Ok "$(M 'Raccourci retiré' 'Shortcut removed') : $l" }
    }
    $data = Join-Path $env:LOCALAPPDATA 'IntuneAssignLens'
    if ((Test-Path -LiteralPath $data) -and (Read-YesNo (M "Effacer aussi le cache, le journal et les réglages ($data) ?" "Also delete the cache, log and settings ($data)?") $false)) {
        Remove-Item -LiteralPath $data -Recurse
        Write-Ok (M 'Cache, journal et réglages effacés.' 'Cache, log and settings deleted.')
    }
    Write-Host ''
    Write-Host "  $(M 'Il reste à supprimer ce dossier, si vous le souhaitez. Le module Microsoft Graph reste installé.' 'You can now delete this folder if you wish. The Microsoft Graph module stays installed.')"
    exit 0
}

# ------------------------------------------------------------------ 1. Checks
if (-not (Test-Path -LiteralPath $start) -or -not (Test-Path -LiteralPath $icon)) {
    Write-Bad (M "Fichiers de l'outil introuvables dans $root. Le dossier est-il complet ?" "Tool files not found in $root. Is the folder complete?")
    exit 1
}
if ($root -match '\\AppData\\Local\\Temp\\') {
    Write-Bad (M "Le dossier est dans un emplacement temporaire : l'archive ZIP n'a sans doute pas été extraite." 'The folder is in a temporary location: the ZIP file was probably not extracted.')
    Write-Host "       $(M 'Clic droit sur le ZIP → « Extraire tout… », vers un dossier durable (par exemple Documents), puis relancez Installer.cmd.' 'Right-click the ZIP → "Extract All…", to a lasting folder (for example Documents), then run Installer.cmd again.')"
    exit 1
}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Bad (M "PowerShell est en mode '$($ExecutionContext.SessionState.LanguageMode)' (WDAC / AppLocker) : l'outil ne peut pas fonctionner sur ce poste." "PowerShell is in '$($ExecutionContext.SessionState.LanguageMode)' mode (WDAC / AppLocker): the tool cannot run on this computer.")
    exit 1
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
if ($root -match '\\Downloads\\|\\Téléchargements\\') {
    Write-Note (M 'Le dossier est dans Téléchargements : si vous videz ce dossier, le raccourci ne marchera plus. Vous pourrez le déplacer puis relancer Installer.cmd.' 'The folder is in Downloads: if you empty that folder, the shortcut will stop working. You can move it, then run Installer.cmd again.')
}

# ------------------------------------------------------------------ 2. Microsoft Graph module
$module = 'Microsoft.Graph.Authentication'
$found = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
if ($found) {
    Write-Ok "$(M 'Module' 'Module') $module $($found.Version)"
}
else {
    Write-Note (M "Le module $module (Microsoft) est nécessaire pour se connecter à votre tenant." "The $module module (Microsoft) is needed to connect to your tenant.")
    if (Read-YesNo (M "L'installer depuis la PowerShell Gallery, pour votre compte seulement (sans droits administrateur) ?" 'Install it from the PowerShell Gallery, for your account only (no administrator rights)?')) {
        try {
            Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
            Write-Ok (M "Module $module installé." "Module $module installed.")
        }
        catch {
            Write-Bad "$(M 'Installation impossible' 'Installation failed') : $($_.Exception.Message)"
            Write-Host "       $(M 'Installez-le vous-même (ou via votre service informatique) :' 'Install it yourself (or through your IT department):') Install-Module $module -Scope CurrentUser"
            Write-Host "       $(M 'Le raccourci est créé quand même : relancez Intune Lens une fois le module installé.' 'The shortcut is created anyway: start Intune Lens again once the module is installed.')"
        }
    }
    else {
        Write-Note (M 'Sans ce module, seul le mode démo fonctionne (pwsh -File .\Start-IntuneAssignLens.ps1 -Mock).' 'Without this module, only demo mode works (pwsh -File .\Start-IntuneAssignLens.ps1 -Mock).')
    }
}

# ------------------------------------------------------------------ 3. Shortcuts
# Stable pwsh: classic install, then the Microsoft Store alias, then the one running this script.
$pwsh = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\pwsh.exe'),
    (Join-Path $PSHOME 'pwsh.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

$shell = New-Object -ComObject WScript.Shell
foreach ($l in $links) {
    $s = $shell.CreateShortcut($l)
    $s.TargetPath = $pwsh
    $s.Arguments = "-NoProfile -File `"$start`" -PauseOnError"
    $s.WorkingDirectory = $root
    $s.IconLocation = "$icon,0"
    $s.Description = 'Intune Lens: Intune assignments, read-only'
    $s.Save()
    Write-Ok "$(M 'Raccourci' 'Shortcut') : $l"
}

Write-Host ''
Write-Host "  $(M 'Installation terminée. Double-cliquez « Intune Lens » sur le Bureau, puis connectez-vous avec votre compte.' 'Setup complete. Double-click "Intune Lens" on the Desktop, then sign in with your account.')" -ForegroundColor Cyan
Write-Host "  $(M 'Épingler : Démarrer → Toutes les applications → clic droit sur « Intune Lens » → « Épingler à l''écran de démarrage ».' 'To pin it: Start → All apps → right-click "Intune Lens" → "Pin to Start".')"
Write-Host ''
if (-not $NoLaunch -and (Read-YesNo (M 'Lancer Intune Lens maintenant ?' 'Start Intune Lens now?'))) {
    Invoke-Item -LiteralPath ($links | Select-Object -Last 1)
}
