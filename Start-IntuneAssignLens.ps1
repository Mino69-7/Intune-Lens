<#
.SYNOPSIS
    IntuneAssignLens : qui reçoit quoi dans Intune, groupe par groupe. Lecture seule.

.DESCRIPTION
    Démarre un serveur local (127.0.0.1, port aléatoire) et ouvre Microsoft Edge sur l'interface.
    Mode réel : connexion Graph interactive avec 4 scopes de LECTURE, jeton limité au processus.
    Mode Mock : données fictives, aucun appel réseau.

.PARAMETER Mock
    Utilise les données fictives de mock/fixtures (aucune connexion, aucun réseau).

.PARAMETER NoBrowser
    N'ouvre pas Edge ; l'URL à ouvrir est affichée dans la console.

.PARAMETER Port
    Port local fixe (défaut : port libre aléatoire).

.PARAMETER TenantId
    Force le tenant pour la connexion (mode réel).

.PARAMETER NoDiskCache
    N'écrit rien sur disque (ni cache, ni journal fichier).

.PARAMETER MockDataset
    Jeu Mock à charger : base (défaut) ou modified.

.PARAMETER EnableOptionalTypes
    Types hors des 4 scopes de base à lire QUAND MÊME, uniquement si le jeton contient déjà la permission
    requise (aucune permission n'est jamais demandée). Exemple : -EnableOptionalTypes deviceHealthScripts
    Valeurs possibles : deviceHealthScripts, windowsAutopilotDeploymentProfiles, deviceEnrollmentConfigurations.

.PARAMETER PauseOnError
    En cas d'erreur, attend Entrée avant de fermer la fenêtre (utilisé par le raccourci « Intune Lens »).

.PARAMETER DemoState
    Mode Mock uniquement : simule un état dans /api/status pour vérifier l'interface
    (syncing, throttled, error, stale).

.EXAMPLE
    pwsh -File .\Start-IntuneAssignLens.ps1 -Mock
#>
[CmdletBinding()]
param(
    [switch]$Mock,
    [switch]$NoBrowser,
    [ValidateRange(0, 65535)][int]$Port = 0,
    [string]$TenantId,
    [switch]$NoDiskCache,
    [ValidateSet('base', 'modified')][string]$MockDataset = 'base',
    [ValidateSet('syncing', 'throttled', 'error', 'stale')][string]$DemoState,
    [string[]]$EnableOptionalTypes = @(),
    [switch]$PauseOnError
)

# En cas d'arrêt sur erreur, garde la fenêtre ouverte (lancement par raccourci) pour que le message reste lisible.
function Exit-IalStartup([int]$Code) {
    if ($PauseOnError -and $Code -ne 0) {
        Write-Host ''
        $msg = if ((Get-Command Tx -ErrorAction SilentlyContinue)) { Tx 'Intune Lens s''est arrêté sur une erreur (voir ci-dessus). Appuyez sur Entrée pour fermer cette fenêtre.' 'Intune Lens stopped on an error (see above). Press Enter to close this window.' } else { 'Intune Lens stopped on an error (see above). Press Enter to close this window.' }
        Write-Host $msg -ForegroundColor Yellow
        [void][Console]::ReadLine()
    }
    exit $Code
}

# --- 1. Version de PowerShell (syntaxe compatible 5.1 jusqu'à ce contrôle) ---
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "Intune Lens requires PowerShell 7 or later (current version: $($PSVersionTable.PSVersion))." -ForegroundColor Red
    Write-Host "Start it with: pwsh -File .\Start-IntuneAssignLens.ps1 (or the Intune Lens shortcut)" -ForegroundColor Red
    Exit-IalStartup 1
}

# --- 2. Mode de langage ---
if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "PowerShell is in '$($ExecutionContext.SessionState.LanguageMode)' mode (WDAC / AppLocker)." -ForegroundColor Red
    Write-Host "The tool needs FullLanguage mode. It does not try to bypass it: check with your security team." -ForegroundColor Red
    Exit-IalStartup 1
}

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
foreach ($f in 'Config', 'Log', 'GraphClient', 'Collectors', 'Index', 'Cache', 'Sync', 'Server') {
    . (Join-Path $root "src\$f.ps1")
}

# --- 3. Réglages enregistrés (langue, thème), puis journal dans cette langue ---
$dataDir = Join-Path $env:LOCALAPPDATA $script:IalConfig.AppName
$prefs = Initialize-IalPrefs -Directory $(if ($NoDiskCache) { $null } else { $dataDir })
if ($NoDiskCache) { Initialize-IalLog -Lang $prefs.lang } else { Initialize-IalLog -Directory (Join-Path $dataDir 'logs') -Lang $prefs.lang }
Initialize-IalCache -Directory (Join-Path $dataDir 'cache') -Disabled:$NoDiskCache

$mode = if ($Mock) { 'Mock' } else { 'Real' }
Write-IalLog -Level INFO -Message (Tx "Démarrage d'Intune Lens (mode $mode, PowerShell $($PSVersionTable.PSVersion))." "Starting Intune Lens ($mode mode, PowerShell $($PSVersionTable.PSVersion)).")

# --- 4. Module Graph (réel uniquement, aucune installation) ---
if (-not $Mock -and -not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
    Write-IalLog -Level ERROR -Message (Tx "Module Microsoft.Graph.Authentication introuvable. Relancez Installer.cmd, ou installez-le vous-même (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser), puis relancez." "Microsoft.Graph.Authentication module not found. Run Installer.cmd again, or install it yourself (Install-Module Microsoft.Graph.Authentication -Scope CurrentUser), then restart.")
    Exit-IalStartup 1
}

if ($DemoState -and -not $Mock) {
    Write-IalLog -Level ERROR -Message (Tx '-DemoState n''est disponible qu''en mode -Mock.' '-DemoState is only available with -Mock.')
    Exit-IalStartup 1
}
$optionalKeys = Get-IalOptionalTypeKeys
$badOptional = @($EnableOptionalTypes | Where-Object { $_ -notin $optionalKeys })
if ($badOptional.Count -gt 0) {
    Write-IalLog -Level ERROR -Message ((Tx 'Type(s) optionnel(s) inconnu(s) : {0}. Valeurs possibles : {1}.' 'Unknown optional type(s): {0}. Possible values: {1}.') -f ($badOptional -join ', '), ($optionalKeys -join ', '))
    Exit-IalStartup 1
}
$state = New-IalAppState -Mode $mode
$state.DemoState = $DemoState
$state.EnabledOptionalTypes = @($EnableOptionalTypes)
if ($Mock) {
    # Jeton simulé : les 4 scopes de base + DeviceManagementScripts.Read.All (consentement large préexistant),
    # pour montrer le cas « permission présente, type activable ».
    $state.TokenScopes = @($script:IalConfig.Scopes) + 'DeviceManagementScripts.Read.All'
}
$state.Root = $root
$server = $null
try {
    # --- 5. Connexion (réel) ou données fictives (Mock) ---
    if ($Mock) {
        Initialize-IalGraphMock -FixturesDir (Join-Path $root 'mock\fixtures') -Dataset $MockDataset
    }
    else {
        Connect-IalGraph -TenantId $TenantId
        $ctx = Get-MgContext
        $state.TenantId = [string]$ctx.TenantId
        $state.TokenScopes = @($ctx.Scopes)     # lu, jamais demandé
        foreach ($k in $EnableOptionalTypes) {
            $t = $script:IalObjectTypes | Where-Object { $_.Key -eq $k }
            $cov = Get-IalTypeCoverage -Type $t -TokenScopes $state.TokenScopes -EnabledOptionalTypes $EnableOptionalTypes
            if (-not $cov.Covered) { Write-IalLog -Level WARN -Message (Tx "Type optionnel $k ignoré : $($cov.Reason)." "Optional type $k ignored: $($cov.Reason).") }
        }
    }

    # --- 6. Cache disque : affichage immédiat des données connues ---
    $cached = Read-IalCache -Mode $mode -TenantId $state.TenantId
    if ($cached) {
        $null = Set-IalStateData -State $state -Data $cached -Source 'cache'
        $state.Phase = 'done'
        Write-IalLog -Level INFO -Message ((Tx 'Cache chargé : données du {0} ({1:N0} groupes, {2:N0} objets).' 'Cache loaded: data from {0} ({1:N0} groups, {2:N0} objects).') -f `
                ([datetimeoffset]::Parse($cached.LastSyncAt).LocalDateTime.ToString('dd/MM HH:mm')), $state.Index.Counts.groups, $state.Index.Counts.objects)
    }
    else {
        Write-IalLog -Level INFO -Message (Tx 'Aucun cache utilisable : première synchronisation complète en arrière-plan.' 'No usable cache: first full sync running in the background.')
    }

    # --- 7. Serveur + navigateur, puis synchronisation en arrière-plan ---
    $server = Start-IalServer -WebRoot (Join-Path $root 'web') -Port $Port
    $url = "http://$($server.Host)/#s=$($server.Token)"
    Write-IalLog -Level INFO -Message (Tx "Serveur prêt sur http://$($server.Host)/ (127.0.0.1 uniquement). Ctrl+C pour arrêter. Gardez cette fenêtre ouverte." "Server ready on http://$($server.Host)/ (127.0.0.1 only). Ctrl+C to stop. Keep this window open.")

    if ($NoBrowser) {
        # Affiché à la console uniquement : jamais écrit dans le journal fichier.
        Write-Host (Tx "Ouvrez cette adresse dans Edge : $url" "Open this address in Edge: $url") -ForegroundColor Cyan
    }
    else {
        $edge = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),
            (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')
        ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if ($edge) { Start-Process -FilePath $edge -ArgumentList $url }
        else { Write-Host (Tx "Edge introuvable. Ouvrez cette adresse : $url" "Edge not found. Open this address: $url") -ForegroundColor Yellow }
    }

    # Incrémentale par défaut ; devient complète si pas de cache ou synchro complète trop ancienne.
    Register-IalSyncJob (Start-IalSyncJob -State $state -Root $root -Mode 'incremental')

    Invoke-IalServerLoop -Server $server -State $state
}
catch {
    Write-IalLog -Level ERROR -Message $_.Exception.Message
    Exit-IalStartup 1
}
finally {
    # --- Arrêt propre (Ctrl+C, /api/shutdown ou erreur) ---
    # Le cache est écrit à la fin de chaque synchronisation réussie ; une synchro en cours est annulée
    # (le cache précédent reste intact grâce à l'écriture atomique).
    Stop-IalServer -Server $server
    Stop-IalSyncJobs -State $state
    Disconnect-IalGraph
    Write-IalLog -Level INFO -Message (Tx 'Intune Lens arrêté.' 'Intune Lens stopped.')
}
