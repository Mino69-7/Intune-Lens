# Config.ps1 : constantes, scopes et inventaire des types d'objets.

Set-StrictMode -Version 3.0

$script:IalConfig = [ordered]@{
    AppName              = 'IntuneAssignLens'
    SchemaVersion        = 1

    # Seul hôte autorisé pour les appels sortants (garde-fou GraphClient).
    GraphHost            = 'graph.microsoft.com'
    GraphBaseV1          = 'https://graph.microsoft.com/v1.0'
    GraphBaseBeta        = 'https://graph.microsoft.com/beta'

    # Les 4 scopes de lecture déjà consentis. NE PAS en ajouter sans accord explicite de l'utilisateur.
    Scopes               = @(
        'DeviceManagementConfiguration.Read.All'
        'DeviceManagementApps.Read.All'
        'DeviceManagementManagedDevices.Read.All'
        'Group.Read.All'
    )
    # Permission AJOUTÉE avec l'accord explicite de l'utilisateur (2026-11-18, fiches Utilisateur / Machine) :
    # lecture des groupes d'un appareil Entra (GET /devices(deviceId='…')/transitiveMemberOf). Vérifié sur
    # Learn : Device.Read.All est la permission minimale. Les groupes d'un UTILISATEUR, eux, se lisent avec
    # Group.Read.All (déjà présent). Sans cette permission, l'outil fonctionne : seuls les groupes des
    # machines manquent (signalé dans l'interface).
    DeviceScope          = 'Device.Read.All'
    # Ciblage par utilisateur / machine
    StaleDeviceDays      = 30      # machine « inactive » si pas de synchro Intune depuis plus de N jours
    MembershipCacheMin   = 10      # durée de vie en mémoire des appartenances lues à la demande

    # Graph
    BatchSize            = 20      # maximum imposé par Graph pour $batch
    MaxRetries           = 6
    RetryBaseDelaySec    = 2
    RetryMaxDelaySec     = 60
    MaxPagesPerList      = 2000    # protection contre une boucle infinie de nextLink
    GroupPageSize        = 999

    # Recherche
    SearchDefaultLimit   = 50
    SearchMaxLimit       = 200

    # Serveur local
    ListenAddress        = '127.0.0.1'
    MaxRequestBodyBytes  = 65536

    # Synchronisation
    FullResyncAfterDays  = 1
    # Types dont les assignations sont relues à CHAQUE synchro incrémentale, parce que modifier une
    # assignation ne change pas leur lastModifiedDateTime. Liste à remplir après le protocole 9.3
    # (tenant réel), par exemple : @('deviceCompliancePolicies').
    AssignmentRereadTypes = @()
}

# Inventaire des familles (section 5.4 de la spec), VÉRIFIÉ sur Microsoft Learn le 2026-11-12 (jalon M4).
# Détail des sources et des réserves : docs/verifications.md (section « Inventaire Graph »).
#   Key       : identifiant interne stable
#   Family    : libellé affiché (français)
#   Path      : chemin relatif à la racine Graph (sans version) ; assignations : {Path}/{id}/assignments
#   Version   : v1.0, ou beta UNIQUEMENT quand la doc ne publie pas de v1.0
#   NameProp  : propriété portant le nom affiché
#   Select    : propriétés demandées pour la liste légère (évite notamment le contenu des scripts)
#   Scopes    : permissions déléguées acceptées par la doc (une seule suffit)
#   HasIntent : les assignations portent un intent (applications)
# La couverture n'est PAS figée ici : elle est calculée par Get-IalTypeCoverage (ci-dessous).
$script:IalObjectTypes = @(
    [ordered]@{ Key = 'deviceConfigurations'; Family = 'Configuration (modèles)'; Path = 'deviceManagement/deviceConfigurations'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'configurationPolicies'; Family = 'Catalogue de paramètres'; Path = 'deviceManagement/configurationPolicies'; Version = 'beta'; NameProp = 'name'; Select = 'id,name,lastModifiedDateTime,platforms,templateReference'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'groupPolicyConfigurations'; Family = 'Modèles d''administration (ADMX)'; Path = 'deviceManagement/groupPolicyConfigurations'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'deviceCompliancePolicies'; Family = 'Conformité'; Path = 'deviceManagement/deviceCompliancePolicies'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    # Applications en BETA : winGetApp (« Microsoft Store app (new) », dont le Portail d'entreprise) et
    # officeSuiteApp (« Microsoft 365 Apps ») n'existent qu'en beta ; la liste v1.0 les omet (vérifié sur Learn, 2026-11-18).
    [ordered]@{ Key = 'mobileApps'; Family = 'Applications'; Path = 'deviceAppManagement/mobileApps'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementApps.Read.All', 'DeviceManagementConfiguration.Read.All'); HasIntent = $true }
    [ordered]@{ Key = 'deviceManagementScripts'; Family = 'Scripts PowerShell'; Path = 'deviceManagement/deviceManagementScripts'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All', 'DeviceManagementScripts.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'deviceHealthScripts'; Family = 'Remédiations'; Path = 'deviceManagement/deviceHealthScripts'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementScripts.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'intents'; Family = 'Sécurité des points de terminaison'; Path = 'deviceManagement/intents'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'windowsFeatureUpdateProfiles'; Family = 'Mises à jour de fonctionnalités'; Path = 'deviceManagement/windowsFeatureUpdateProfiles'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'windowsQualityUpdateProfiles'; Family = 'Mises à jour qualité'; Path = 'deviceManagement/windowsQualityUpdateProfiles'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'windowsDriverUpdateProfiles'; Family = 'Mises à jour de pilotes'; Path = 'deviceManagement/windowsDriverUpdateProfiles'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementConfiguration.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'iosManagedAppProtections'; Family = 'Protection d''application'; Path = 'deviceAppManagement/iosManagedAppProtections'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementApps.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'androidManagedAppProtections'; Family = 'Protection d''application'; Path = 'deviceAppManagement/androidManagedAppProtections'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementApps.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'targetedManagedAppConfigurations'; Family = 'Configuration d''application'; Path = 'deviceAppManagement/targetedManagedAppConfigurations'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementApps.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'windowsAutopilotDeploymentProfiles'; Family = 'Autopilot'; Path = 'deviceManagement/windowsAutopilotDeploymentProfiles'; Version = 'beta'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementServiceConfig.Read.All'); HasIntent = $false }
    [ordered]@{ Key = 'deviceEnrollmentConfigurations'; Family = 'Inscription / ESP'; Path = 'deviceManagement/deviceEnrollmentConfigurations'; Version = 'v1.0'; NameProp = 'displayName'; Select = 'id,displayName,lastModifiedDateTime'; Scopes = @('DeviceManagementServiceConfig.Read.All'); HasIntent = $false }
)

# Ressources annexes (résolution de noms)
$script:IalFiltersType = [ordered]@{ Key = 'assignmentFilters'; Path = 'deviceManagement/assignmentFilters'; Version = 'beta'; Select = 'id,displayName,platform'; Scopes = @('DeviceManagementConfiguration.Read.All') }
$script:IalGroupsPath = 'groups'
# Appareils gérés : liste légère (DeviceManagementManagedDevices.Read.All, scope de base). userId = utilisateur principal.
$script:IalDevicesType = [ordered]@{
    Key = 'managedDevices'; Family = 'Appareils'; Path = 'deviceManagement/managedDevices'; Version = 'v1.0'
    Select = 'id,deviceName,userId,userPrincipalName,userDisplayName,azureADDeviceId,operatingSystem,osVersion,model,manufacturer,serialNumber,lastSyncDateTime,complianceState,managedDeviceOwnerType'
    Scopes = @('DeviceManagementManagedDevices.Read.All')
}

function Get-IalConnectScopes {
    <# Scopes demandés à la connexion (GraphClient) : les 4 de base + Device.Read.All (accord de l'utilisateur, 2026-11-18). #>
    @($script:IalConfig.Scopes) + $script:IalConfig.DeviceScope
}

function Get-IalTypeCoverage {
    <#
        Décide si un type est lu, SANS jamais demander de permission supplémentaire :
          1. couvert si la doc accepte l'un des 4 scopes de base ;
          2. sinon (type « optionnel ») : lu seulement si l'utilisateur l'a activé explicitement
             (-EnableOptionalTypes) ET si le jeton contient DÉJÀ l'un des scopes acceptés ;
          3. sinon : non couvert, avec un motif lisible.
        Retourne @{ Covered = [bool]; Optional = [bool]; Reason = [string] }.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Type,
        [AllowEmptyCollection()][string[]]$TokenScopes = @(),
        [AllowEmptyCollection()][string[]]$EnabledOptionalTypes = @()
    )
    $base = @($script:IalConfig.Scopes)
    if (@($Type.Scopes | Where-Object { $_ -in $base }).Count -gt 0) {
        return @{ Covered = $true; Optional = $false; Reason = '' }
    }
    $needed = ($Type.Scopes -join ' ou ')
    $inToken = @($Type.Scopes | Where-Object { $_ -in $TokenScopes }).Count -gt 0
    if ($Type.Key -in $EnabledOptionalTypes) {
        if ($inToken) { return @{ Covered = $true; Optional = $true; Reason = '' } }
        return @{ Covered = $false; Optional = $true; Reason = "Activé, mais le jeton ne contient pas $needed" }
    }
    if ($inToken) {
        return @{ Covered = $false; Optional = $true; Reason = "Permission $needed déjà présente dans le jeton : activable avec -EnableOptionalTypes $($Type.Key)" }
    }
    return @{ Covered = $false; Optional = $true; Reason = "Permission non consentie ($needed)" }
}

function Get-IalOptionalTypeKeys {
    <# Types hors des 4 scopes de base (activables explicitement). #>
    $base = @($script:IalConfig.Scopes)
    @($script:IalObjectTypes | Where-Object { @($_.Scopes | Where-Object { $_ -in $base }).Count -eq 0 } | ForEach-Object { $_.Key })
}
