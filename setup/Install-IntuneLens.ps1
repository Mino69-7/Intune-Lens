<#
.SYNOPSIS
    Installe Intune Lens pour l'utilisateur courant : une seule fois, sans droits administrateur.

.DESCRIPTION
    Lancé par Installer.cmd (double-clic), qui a déjà vérifié PowerShell 7 et débloqué les fichiers du dossier.
      1. Vérifie PowerShell 7, le mode de langage et l'emplacement du dossier.
      2. Propose d'installer le module officiel Microsoft.Graph.Authentication (PowerShell Gallery),
         pour votre compte seulement (-Scope CurrentUser), avec votre accord.
      3. Crée le raccourci « Intune Lens » (avec le logo) sur le Bureau et dans le menu Démarrer.
    Rien d'autre : pas de registre, pas de tâche planifiée, pas de service, pas d'élévation.
    Relancez-le si vous déplacez le dossier. L'outil lui-même (Start-IntuneAssignLens.ps1) n'installe jamais rien.

.PARAMETER Uninstall
    Retire les deux raccourcis et propose d'effacer le cache et le journal (%LOCALAPPDATA%\IntuneAssignLens).

.PARAMETER NoLaunch
    Ne propose pas de lancer l'outil à la fin.
#>
[CmdletBinding()]
param([switch]$Uninstall, [switch]$NoLaunch)

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host 'Intune Lens nécessite PowerShell 7. Lancez Installer.cmd (double-clic) plutôt que ce script.' -ForegroundColor Red
    exit 1
}
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

function Write-Ok([string]$Message) { Write-Host "  [OK] $Message" -ForegroundColor Green }
function Write-Note([string]$Message) { Write-Host "  [!]  $Message" -ForegroundColor Yellow }
function Write-Bad([string]$Message) { Write-Host "  [X]  $Message" -ForegroundColor Red }
function Read-YesNo([string]$Question, [bool]$Default = $true) {
    $hint = if ($Default) { '[O/n]' } else { '[o/N]' }
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
Write-Host "  $appName : $(if ($Uninstall) { 'désinstallation' } else { 'installation' })" -ForegroundColor Cyan
Write-Host "  Dossier : $root"
Write-Host ''

# ------------------------------------------------------------------ Désinstallation
if ($Uninstall) {
    foreach ($l in $links) {
        if (Test-Path -LiteralPath $l) { Remove-Item -LiteralPath $l; Write-Ok "Raccourci retiré : $l" }
    }
    $data = Join-Path $env:LOCALAPPDATA 'IntuneAssignLens'
    if ((Test-Path -LiteralPath $data) -and (Read-YesNo "Effacer aussi le cache et le journal ($data) ?" $false)) {
        Remove-Item -LiteralPath $data -Recurse
        Write-Ok 'Cache et journal effacés.'
    }
    Write-Host ''
    Write-Host '  Il reste à supprimer ce dossier, si vous le souhaitez. Le module Microsoft Graph reste installé.'
    exit 0
}

# ------------------------------------------------------------------ 1. Vérifications
if (-not (Test-Path -LiteralPath $start) -or -not (Test-Path -LiteralPath $icon)) {
    Write-Bad "Fichiers de l'outil introuvables dans $root. Le dossier est-il complet ?"
    exit 1
}
if ($root -match '\\AppData\\Local\\Temp\\') {
    Write-Bad "Le dossier est dans un emplacement temporaire : l'archive ZIP n'a sans doute pas été extraite."
    Write-Host '       Clic droit sur le ZIP → « Extraire tout… », vers un dossier durable (par exemple Documents), puis relancez Installer.cmd.'
    exit 1
}
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Bad "PowerShell est en mode '$($ExecutionContext.SessionState.LanguageMode)' (WDAC / AppLocker) : l'outil ne peut pas fonctionner sur ce poste."
    exit 1
}
Write-Ok "PowerShell $($PSVersionTable.PSVersion)"
if ($root -match '\\Downloads\\|\\Téléchargements\\') {
    Write-Note 'Le dossier est dans Téléchargements : si vous videz ce dossier, le raccourci ne marchera plus. Vous pourrez le déplacer puis relancer Installer.cmd.'
}

# ------------------------------------------------------------------ 2. Module Microsoft Graph
$module = 'Microsoft.Graph.Authentication'
$found = Get-Module -ListAvailable -Name $module | Sort-Object Version -Descending | Select-Object -First 1
if ($found) {
    Write-Ok "Module $module $($found.Version)"
}
else {
    Write-Note "Le module $module (Microsoft) est nécessaire pour se connecter à votre tenant."
    if (Read-YesNo "L'installer depuis la PowerShell Gallery, pour votre compte seulement (sans droits administrateur) ?") {
        try {
            Install-Module -Name Microsoft.Graph.Authentication -Scope CurrentUser -Repository PSGallery -Force -ErrorAction Stop
            Write-Ok "Module $module installé."
        }
        catch {
            Write-Bad "Installation impossible : $($_.Exception.Message)"
            Write-Host "       Installez-le vous-même (ou via votre service informatique) : Install-Module $module -Scope CurrentUser"
            Write-Host '       Le raccourci est créé quand même : relancez Intune Lens une fois le module installé.'
        }
    }
    else {
        Write-Note "Sans ce module, seul le mode démo fonctionne (pwsh -File .\Start-IntuneAssignLens.ps1 -Mock)."
    }
}

# ------------------------------------------------------------------ 3. Raccourcis
# pwsh stable : installation classique, puis alias de la version Microsoft Store, puis celui qui exécute ce script.
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
    $s.Description = 'Intune Lens : assignations Intune, en lecture seule'
    $s.Save()
    Write-Ok "Raccourci : $l"
}

Write-Host ''
Write-Host '  Installation terminée. Double-cliquez « Intune Lens » sur le Bureau, puis connectez-vous avec votre compte.' -ForegroundColor Cyan
Write-Host '  Épingler : Démarrer → Toutes les applications → clic droit sur « Intune Lens » → « Épingler à l''écran de démarrage ».'
Write-Host ''
if (-not $NoLaunch -and (Read-YesNo 'Lancer Intune Lens maintenant ?')) {
    Invoke-Item -LiteralPath ($links | Select-Object -Last 1)
}
