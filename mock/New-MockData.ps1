#Requires -Version 7.0
<#
.SYNOPSIS
    Génère les jeux de données factices (mode Mock) d'IntuneAssignLens.

.DESCRIPTION
    Générateur DÉTERMINISTE (graine fixe) : deux exécutions produisent les mêmes fichiers.
    Tous les noms sont inventés. Aucun appel réseau.

    Fichiers produits dans mock/fixtures/ :
      base.json      : jeu de départ (~13 000 groupes, ~2 100 objets, ~560 appareils, ~420 utilisateurs)
      modified.json  : même jeu après quelques changements (test du rafraîchissement incrémental)
      expected.json  : identifiants remarquables et résultats attendus pour les tests

.PARAMETER Seed
    Graine du générateur pseudo-aléatoire (défaut : 20261112).

.PARAMETER GroupCount
    Nombre de groupes (défaut : 13 000).
#>
[CmdletBinding()]
param(
    [int]$Seed = 20261112,
    [int]$GroupCount = 13000
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$fixturesDir = Join-Path $PSScriptRoot 'fixtures'
if (-not (Test-Path -LiteralPath $fixturesDir)) { $null = New-Item -ItemType Directory -Path $fixturesDir }

$rng = [System.Random]::new($Seed)
function New-Id { $b = [byte[]]::new(16); $rng.NextBytes($b); $b[7] = ($b[7] -band 0x0F) -bor 0x40; $b[8] = ($b[8] -band 0x3F) -bor 0x80; ([guid]::new($b)).ToString() }
function Pick([object[]]$a) { $a[$rng.Next($a.Count)] }
$epoch = [datetime]::new(2024, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
function New-Date { $epoch.AddSeconds($rng.Next(0, 86400 * 1000)).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }

#region Groupes ---------------------------------------------------------------

$prefixes = 'GRP', 'SG', 'AAD', 'DYN', 'INT', 'WIN', 'MAC', 'IOS', 'AND', 'LIC', 'APP', 'POL', 'USR', 'DEV', 'EXT'
$depts = 'Comptabilité', 'Ressources Humaines', 'Direction Générale', 'Informatique', 'Logistique', 'Marketing', 'Ventes',
'Juridique', 'Achats', 'Recherche & Développement', 'Qualité', 'Sécurité', 'Support N1', 'Support N2', 'Formation',
'Communication', 'Médical', 'Pédiatrie', 'Urgences', 'Pharmacie', 'Accueil', 'Facturation', 'Bâtiment A', 'Bâtiment B',
'Siège', 'Agence Nord', 'Agence Sud', 'Agence Est', 'Agence Ouest', 'Île-de-France', 'Provence-Alpes-Côte d''Azur',
'Auvergne-Rhône-Alpes', 'Hauts-de-France', 'Grand Est', 'Bretagne', 'Normandie', 'Occitanie', 'Façades', 'Œnologie'
$suffixes = 'Utilisateurs', 'Appareils', 'Pilote', 'Prod', 'Test', 'Ring0', 'Ring1', 'Ring2', 'Exclusion', 'Kiosque',
'Partagés', 'VIP', 'Stagiaires', 'Prestataires', 'Laptops', 'Postes fixes', 'Tablettes', 'Smartphones'

$groups = [System.Collections.Generic.List[object]]::new()
$special = [ordered]@{
    reference = 'GRP-Référence-Démo-26'
    empty     = 'GRP-Sans-Assignation-Démo'
    xss       = '<b>Groupe</b> & "guillemets" <script>alert(1)</script>'
}
$specialIds = @{}
foreach ($k in $special.Keys) {
    $id = New-Id
    $specialIds[$k] = $id
    $groups.Add([ordered]@{ id = $id; displayName = $special[$k] })
}
$i = 0
while ($groups.Count -lt $GroupCount) {
    $i++
    $name = '{0}-{1}-{2}' -f (Pick $prefixes), (Pick $depts), (Pick $suffixes)
    $r = $rng.Next(100)
    if ($r -lt 55) { $name += '-{0:000}' -f $rng.Next(1, 999) }
    elseif ($r -lt 57) { $name = $name + ' — ' + ((1..12 | ForEach-Object { Pick $depts }) -join ' / ') }  # noms très longs
    elseif ($r -lt 58) { $name += ' (test) #' + $rng.Next(1, 99) + ' [archive]' }
    # les noms sans suffixe numérique produisent des doublons volontaires
    $groups.Add([ordered]@{ id = (New-Id); displayName = $name })
}
# Doublons de nom explicites
$groups.Add([ordered]@{ id = (New-Id); displayName = 'GRP-Doublon-Démo' })
$groups.Add([ordered]@{ id = (New-Id); displayName = 'GRP-Doublon-Démo' })

$reservedIds = @($specialIds.Values)
# Pool d'assignation : distribution très inégale (peu de groupes très utilisés, beaucoup jamais).
$pool = @($groups | Where-Object { $_.id -notin $reservedIds } | ForEach-Object { $_.id })
$hot = $pool[0..399]
$warm = $pool[400..2999]
function Pick-GroupId { $r = $rng.Next(100); if ($r -lt 60) { Pick $hot } elseif ($r -lt 95) { Pick $warm } else { Pick $pool } }
$deletedGroupId = New-Id   # référencé mais absent de la liste des groupes

#endregion

#region Filtres ---------------------------------------------------------------

$filters = [System.Collections.Generic.List[object]]::new()
$filterPlatforms = 'windows10AndLater', 'iOS', 'androidForWork', 'macOS'
for ($f = 1; $f -le 25; $f++) {
    $plat = Pick $filterPlatforms
    $filters.Add([ordered]@{ id = (New-Id); displayName = ('Filtre-{0}-{1:00}' -f $plat, $f); platform = $plat })
}

#endregion

#region Objets ----------------------------------------------------------------

$typeSpecs = [ordered]@{
    deviceConfigurations               = @{ Count = 450; Odata = 'windows10GeneralConfiguration', 'windows10EndpointProtectionConfiguration', 'windows10CustomConfiguration', 'iosDeviceFeaturesConfiguration', 'androidWorkProfileGeneralDeviceConfiguration', 'macOSCustomConfiguration'; Name = 'displayName'; Filters = $true; Words = 'Restrictions', 'Wi-Fi', 'VPN', 'BitLocker', 'Certificats', 'OMA-URI', 'Kiosque', 'Délai écran', 'Proxy', 'Edge' }
    configurationPolicies              = @{ Count = 500; Odata = @('deviceManagementConfigurationPolicy'); Name = 'name'; Filters = $true; Words = 'Catalogue', 'OneDrive', 'Defender', 'Office', 'Windows Hello', 'LAPS', 'Pare-feu', 'Teams', 'Navigateur', 'Énergie' }
    groupPolicyConfigurations          = @{ Count = 120; Odata = @('groupPolicyConfiguration'); Name = 'displayName'; Filters = $true; Words = 'ADMX', 'Chrome', 'Office ADMX', 'Imprimantes', 'Lecteurs réseau' }
    deviceCompliancePolicies           = @{ Count = 80; Odata = 'windows10CompliancePolicy', 'iosCompliancePolicy', 'androidWorkProfileCompliancePolicy', 'macOSCompliancePolicy'; Name = 'displayName'; Filters = $true; Words = 'Conformité', 'Chiffrement', 'Version OS', 'Antivirus' }
    mobileApps                         = @{ Count = 600; Odata = 'win32LobApp', 'winGetApp', 'officeSuiteApp', 'iosVppApp', 'androidManagedStoreApp', 'webApp', 'macOSLobApp'; Name = 'displayName'; Filters = $true; Words = '7-Zip', 'Notepad++', 'Visionneuse PDF', 'Client VPN', 'Agent ERP', 'Navigateur', 'Suite bureautique', 'Outil métier', 'Pilote imprimante', 'Logiciel comptable' }
    deviceManagementScripts            = @{ Count = 120; Odata = @('deviceManagementScript'); Name = 'displayName'; Filters = $false; Words = 'Script', 'Nettoyage', 'Inventaire', 'Mappage', 'Registre' }
    deviceHealthScripts                = @{ Count = 80; Odata = @('deviceHealthScript'); Name = 'displayName'; Filters = $false; Words = 'Remédiation', 'Détection', 'Réparation', 'Cache' }
    intents                            = @{ Count = 60; Odata = @('deviceManagementIntent'); Name = 'displayName'; Filters = $false; Words = 'Antivirus', 'ASR', 'EDR', 'Base de sécurité', 'Pare-feu' }
    windowsFeatureUpdateProfiles       = @{ Count = 15; Odata = @('windowsFeatureUpdateProfile'); Name = 'displayName'; Filters = $false; Words = 'Version 25H2', 'Version 24H2' }
    windowsQualityUpdateProfiles       = @{ Count = 10; Odata = @('windowsQualityUpdateProfile'); Name = 'displayName'; Filters = $false; Words = 'Expédition', 'Correctif' }
    windowsDriverUpdateProfiles        = @{ Count = 10; Odata = @('windowsDriverUpdateProfile'); Name = 'displayName'; Filters = $false; Words = 'Pilotes' }
    iosManagedAppProtections           = @{ Count = 20; Odata = @('iosManagedAppProtection'); Name = 'displayName'; Filters = $false; Words = 'MAM iOS' }
    androidManagedAppProtections       = @{ Count = 20; Odata = @('androidManagedAppProtection'); Name = 'displayName'; Filters = $false; Words = 'MAM Android' }
    targetedManagedAppConfigurations   = @{ Count = 30; Odata = @('targetedManagedAppConfiguration'); Name = 'displayName'; Filters = $false; Words = 'Config app' }
    windowsAutopilotDeploymentProfiles = @{ Count = 10; Odata = @('azureADWindowsAutopilotDeploymentProfile'); Name = 'displayName'; Filters = $false; Words = 'Autopilot' }
    deviceEnrollmentConfigurations     = @{ Count = 10; Odata = @('windows10EnrollmentCompletionPageConfiguration'); Name = 'displayName'; Filters = $false; Words = 'ESP' }
}
$platformsForPolicies = 'windows10', 'macOS', 'iOS', 'android'
$intents = 'required', 'required', 'available', 'available', 'uninstall'

function New-Target([string]$Kind, [string]$GroupId, [bool]$AllowFilter) {
    $t = [ordered]@{ '@odata.type' = "#microsoft.graph.$Kind" }
    if ($GroupId) { $t['groupId'] = $GroupId }
    if ($Kind -ne 'exclusionGroupAssignmentTarget') {
        if ($AllowFilter -and $rng.Next(100) -lt 25) {
            $t['deviceAndAppManagementAssignmentFilterId'] = (Pick $filters).id
            $t['deviceAndAppManagementAssignmentFilterType'] = if ($rng.Next(100) -lt 70) { 'include' } else { 'exclude' }
        }
        else {
            $t['deviceAndAppManagementAssignmentFilterId'] = $null
            $t['deviceAndAppManagementAssignmentFilterType'] = 'none'
        }
    }
    return $t
}

function New-Assignment([string]$TypeKey, $Target) {
    $a = [ordered]@{ id = (New-Id); target = $Target }
    if ($TypeKey -eq 'mobileApps') {
        $a['intent'] = if ($Target['@odata.type'] -eq '#microsoft.graph.exclusionGroupAssignmentTarget') { 'required' } else { Pick $intents }
    }
    return $a
}

$objects = [ordered]@{}
foreach ($key in $typeSpecs.Keys) {
    $spec = $typeSpecs[$key]
    $list = [System.Collections.Generic.List[object]]::new()
    for ($n = 1; $n -le $spec.Count; $n++) {
        $o = [ordered]@{ id = (New-Id) }
        $o[$spec.Name] = '{0} - {1} - {2:000}' -f (Pick $spec.Words), (Pick $depts), $n
        $o['lastModifiedDateTime'] = New-Date
        $o['@odata.type'] = '#microsoft.graph.' + (Pick $spec.Odata)
        if ($key -eq 'configurationPolicies') { $o['platforms'] = Pick $platformsForPolicies }

        $as = [System.Collections.Generic.List[object]]::new()
        $r = $rng.Next(100)
        if ($r -ge 5) {
            $nb = $rng.Next(1, 6)
            $used = [System.Collections.Generic.HashSet[string]]::new()
            for ($k = 0; $k -lt $nb; $k++) {
                $gid = Pick-GroupId
                if (-not $used.Add($gid)) { continue }
                $kind = if ($rng.Next(100) -lt 80) { 'groupAssignmentTarget' } else { 'exclusionGroupAssignmentTarget' }
                $as.Add((New-Assignment $key (New-Target $kind $gid $spec.Filters)))
            }
            if ($rng.Next(100) -lt 8) { $as.Add((New-Assignment $key (New-Target 'allDevicesAssignmentTarget' $null $spec.Filters))) }
            if ($rng.Next(100) -lt 8) { $as.Add((New-Assignment $key (New-Target 'allLicensedUsersAssignmentTarget' $null $spec.Filters))) }
        }
        $o['assignments'] = $as
        $list.Add($o)
    }
    $objects[$key] = $list
}

# Objet sans assignation, nommé
$unassigned = $objects['deviceConfigurations'][0]
$unassigned['displayName'] = 'Configuration sans assignation (démo)'
$unassigned['assignments'] = [System.Collections.Generic.List[object]]::new()

# Groupe supprimé encore référencé (3 objets)
foreach ($idx in 10, 20, 30) {
    $objects['configurationPolicies'][$idx]['assignments'].Add((New-Assignment 'configurationPolicies' (New-Target 'groupAssignmentTarget' $deletedGroupId $false)))
}

# Variantes de cibles vues dans la documentation Microsoft Learn (M4) :
#  - type OData sans « # » ;
#  - scopeTagGroupAssignmentTarget (entraObjectId) ;
#  - cible non prise en charge (collection Configuration Manager).
$noHashObj = $objects['mobileApps'][40]
$noHashGroup = Pick $hot
$noHashObj['assignments'].Add([ordered]@{ id = (New-Id); intent = 'available'; target = [ordered]@{ '@odata.type' = 'microsoft.graph.groupAssignmentTarget'; groupId = $noHashGroup; deviceAndAppManagementAssignmentFilterId = $null; deviceAndAppManagementAssignmentFilterType = 'none' } })
$scopeTagObj = $objects['deviceConfigurations'][41]
$scopeTagGroup = Pick $hot
$scopeTagObj['assignments'].Add([ordered]@{ id = (New-Id); target = [ordered]@{ '@odata.type' = '#microsoft.graph.scopeTagGroupAssignmentTarget'; targetType = 'device'; entraObjectId = $scopeTagGroup } })
$otherObj = $objects['deviceManagementScripts'][42]
$otherObj['assignments'].Add([ordered]@{ id = (New-Id); target = [ordered]@{ '@odata.type' = '#microsoft.graph.configurationManagerCollectionAssignmentTarget'; collectionId = 'SMS00001' } })

# Groupe XSS assigné à un objet (test d'échappement dans l'UI)
$objects['mobileApps'][5]['assignments'].Add((New-Assignment 'mobileApps' (New-Target 'groupAssignmentTarget' $specialIds.xss $false)))

# Groupe de référence : exactement 26 éléments, répartis sur les familles, dont 6 exclusions.
$refPlan = @(
    @('deviceConfigurations', 3), @('configurationPolicies', 5), @('groupPolicyConfigurations', 2), @('deviceCompliancePolicies', 2),
    # Pas de remédiations ici : elles exigent DeviceManagementScripts.Read.All (hors des 4 scopes, M4).
    @('mobileApps', 6), @('deviceManagementScripts', 4), @('intents', 1),
    @('windowsFeatureUpdateProfiles', 1), @('windowsQualityUpdateProfiles', 1), @('iosManagedAppProtections', 1)
)
$refObjectIds = [System.Collections.Generic.List[string]]::new()
$refIndex = 0
foreach ($p in $refPlan) {
    $key = $p[0]; $count = $p[1]
    for ($c = 0; $c -lt $count; $c++) {
        $o = $objects[$key][100 % $objects[$key].Count + $c * 3 + 1]
        if ($key -in 'windowsFeatureUpdateProfiles', 'windowsQualityUpdateProfiles', 'iosManagedAppProtections') { $o = $objects[$key][$c + 2] }
        $kind = if ($refIndex % 5 -eq 4) { 'exclusionGroupAssignmentTarget' } else { 'groupAssignmentTarget' }
        $o['assignments'].Add((New-Assignment $key (New-Target $kind $specialIds.reference $typeSpecs[$key].Filters)))
        $refObjectIds.Add($o['id'])
        $refIndex++
    }
}
if ($refObjectIds.Count -ne 26 -or ($refObjectIds | Select-Object -Unique).Count -ne 26) { throw "Le groupe de référence doit avoir 26 éléments distincts (obtenu : $($refObjectIds.Count))." }
# Un des éléments exclus porte aussi « Tous les appareils » (exclusion sur règle globale)
$exclRef = $null
foreach ($key in $objects.Keys) {
    foreach ($o in $objects[$key]) {
        if ($o['id'] -notin $refObjectIds) { continue }
        foreach ($a in $o['assignments']) {
            if ($a.target.groupId -eq $specialIds.reference -and $a.target['@odata.type'] -like '*exclusion*') { $exclRef = $o; break }
        }
        if ($exclRef) { break }
    }
    if ($exclRef) { break }
}
if (-not ($exclRef['assignments'] | Where-Object { $_.target['@odata.type'] -like '*allDevices*' })) {
    $exclRef['assignments'].Add((New-Assignment 'x' (New-Target 'allDevicesAssignmentTarget' $null $false)))
}

#endregion

#region Utilisateurs, appareils et appartenances (fiches Utilisateur / Machine) --
# Générateur SÉPARÉ (graine dérivée) : les données existantes restent identiques octet pour octet.
# La date de dernière synchro est stockée en « jours avant aujourd'hui » (lastSyncDaysAgo) : le Mock la
# convertit en date au moment de la lecture, pour que le jeu reste réaliste dans le temps.

$rng2 = [System.Random]::new($Seed + 7)
function New-Id2 { $b = [byte[]]::new(16); $rng2.NextBytes($b); $b[7] = ($b[7] -band 0x0F) -bor 0x40; $b[8] = ($b[8] -band 0x3F) -bor 0x80; ([guid]::new($b)).ToString() }
function Pick2([object[]]$a) { $a[$rng2.Next($a.Count)] }
function ConvertTo-Ascii([string]$s) { ($s.Normalize([System.Text.NormalizationForm]::FormD) -replace '\p{Mn}', '' -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }

$firstNames = 'Camille', 'Alex', 'Léa', 'Hugo', 'Chloé', 'Lucas', 'Manon', 'Nathan', 'Inès', 'Théo', 'Jade', 'Louis', 'Zoé', 'Jules', 'Emma',
'Gabriel', 'Louise', 'Arthur', 'Alice', 'Raphaël', 'Lina', 'Noah', 'Rose', 'Adam', 'Anna', 'Paul', 'Mila', 'Victor', 'Sarah', 'Éloïse'
$lastNames = 'Martin', 'Bernard', 'Dubois', 'Thomas', 'Robert', 'Richard', 'Petit', 'Durand', 'Leroy', 'Moreau', 'Simon', 'Laurent',
'Lefèvre', 'Michel', 'Garcia', 'David', 'Bertrand', 'Roux', 'Vincent', 'Fournier', 'Morel', 'Girard', 'André', 'Mercier', 'Dupont',
'Lambert', 'Bonnet', 'François', 'Martinez', 'Légaré'
$winModels = @(@('Dell Inc.', 'Latitude 7450'), @('Dell Inc.', 'OptiPlex 7020'), @('HP', 'EliteBook 840 G11'), @('Lenovo', 'ThinkPad T14 Gen 5'), @('Microsoft Corporation', 'Surface Laptop 7'))
$winVersions = '10.0.26100.2314', '10.0.22631.4460', '10.0.19045.5131'

$devices = [System.Collections.Generic.List[object]]::new()
$userMemberOf = [ordered]@{}
$deviceMemberOf = [ordered]@{}
$usedUpn = [System.Collections.Generic.HashSet[string]]::new()
$serialN = 0

function New-MockDevice([string]$Os, $User, [int]$DaysAgo, [string]$Name) {
    $script:serialN++
    $aad = if ($rng2.Next(100) -lt 3) { '00000000-0000-0000-0000-000000000000' } else { New-Id2 }
    switch ($Os) {
        'Windows' { $mk = Pick2 $winModels; $maker = $mk[0]; $model = $mk[1]; $ver = Pick2 $winVersions; if (-not $Name) { $Name = 'PC-{0:00000}' -f $rng2.Next(10000, 99999) } }
        'macOS' { $maker = 'Apple'; $model = 'MacBook Pro'; $ver = '15.1'; if (-not $Name) { $Name = 'MAC-{0:0000}' -f $rng2.Next(1000, 9999) } }
        'iOS' { $maker = 'Apple'; $model = 'iPhone 15'; $ver = '18.1'; if (-not $Name) { $Name = 'IPH-{0:0000}' -f $rng2.Next(1000, 9999) } }
        default { $maker = 'Samsung'; $model = 'Galaxy S24'; $ver = '14'; if (-not $Name) { $Name = 'AND-{0:0000}' -f $rng2.Next(1000, 9999) } }
    }
    $r = $rng2.Next(100)
    $d = [ordered]@{
        id                     = (New-Id2)
        deviceName             = $Name
        userId                 = $(if ($User) { $User.id } else { $null })
        userPrincipalName      = $(if ($User) { $User.upn } else { $null })
        userDisplayName        = $(if ($User) { $User.name } else { $null })
        azureADDeviceId        = $aad
        operatingSystem        = $Os
        osVersion              = $ver
        model                  = $model
        manufacturer           = $maker
        serialNumber           = ('DEMO{0:000000}' -f $script:serialN)
        lastSyncDaysAgo        = $DaysAgo
        complianceState        = $(if ($r -lt 85) { 'compliant' } elseif ($r -lt 95) { 'noncompliant' } else { 'unknown' })
        managedDeviceOwnerType = 'company'
    }
    $devices.Add($d)
    if ($aad -notmatch '^0{8}') {
        $n = $rng2.Next(1, 6)
        $set = [System.Collections.Generic.HashSet[string]]::new()
        for ($k = 0; $k -lt $n; $k++) { $null = $set.Add($(if ($rng2.Next(100) -lt 70) { Pick2 $hot } else { Pick2 $warm })) }
        $deviceMemberOf[$aad] = @($set)
    }
    return $d
}

function New-MockMemberships([int]$Count, [string[]]$Must = @()) {
    $set = [System.Collections.Generic.HashSet[string]]::new([string[]]$Must)
    $guard = 0
    while ($set.Count -lt $Count -and $guard++ -lt $Count * 5) {
        $r = $rng2.Next(100)
        $null = $set.Add($(if ($r -lt 45) { Pick2 $hot } elseif ($r -lt 75) { Pick2 $warm } else { Pick2 $pool }))
    }
    return @($set)
}

$mockUsers = [System.Collections.Generic.List[object]]::new()
function New-MockUser([string]$First, [string]$Last) {
    $base = '{0}.{1}' -f (ConvertTo-Ascii $First), (ConvertTo-Ascii $Last)
    $upn = "$base@demo.example"; $k = 1
    while (-not $usedUpn.Add($upn)) { $k++; $upn = "$base$k@demo.example" }
    $u = [ordered]@{ id = (New-Id2); name = "$First $Last"; upn = $upn }
    $mockUsers.Add($u)
    return $u
}

# Utilisateurs de démonstration (identifiants dans expected.json)
$demoUser = New-MockUser 'Camille' 'Démo'
$demoPc = New-MockDevice 'Windows' $demoUser 0 'PC-DEMO-01'
$demoOld = New-MockDevice 'Windows' $demoUser 120 'PC-DEMO-ANCIEN'
$userMemberOf[$demoUser.id] = New-MockMemberships 124 @($specialIds.reference)
$demoUser2 = New-MockUser 'Alex' 'Démo'
$demoPc2 = New-MockDevice 'Windows' $demoUser2 1 'PC-DEMO-02'
$demoPhone2 = New-MockDevice 'iOS' $demoUser2 2 'IPH-DEMO-02'
$userMemberOf[$demoUser2.id] = New-MockMemberships 18 @($specialIds.reference)
foreach ($d in $demoPc, $demoOld, $demoPc2) { if ($d.azureADDeviceId -match '^0{8}') { $d.azureADDeviceId = New-Id2; $deviceMemberOf[$d.azureADDeviceId] = New-MockMemberships 3 } }

for ($n = 0; $n -lt 420; $n++) {
    $u = New-MockUser (Pick2 $firstNames) (Pick2 $lastNames)
    $r = $rng2.Next(100)
    $os = if ($r -lt 82) { 'Windows' } elseif ($r -lt 90) { 'macOS' } elseif ($r -lt 96) { 'iOS' } else { 'Android' }
    $null = New-MockDevice $os $u $rng2.Next(0, 7) $null
    if ($rng2.Next(100) -lt 30) {
        $stale = $rng2.Next(100) -lt 60
        $null = New-MockDevice $(if ($rng2.Next(100) -lt 75) { 'Windows' } else { 'iOS' }) $u $(if ($stale) { $rng2.Next(45, 300) } else { $rng2.Next(0, 10) }) $null
    }
    $g = $rng2.Next(100)
    $count = if ($g -lt 85) { $rng2.Next(4, 26) } elseif ($g -lt 97) { $rng2.Next(26, 61) } else { $rng2.Next(80, 141) }
    $userMemberOf[$u.id] = New-MockMemberships $count
}
# Appareils sans utilisateur (bornes, postes partagés)
for ($n = 1; $n -le 25; $n++) { $null = New-MockDevice 'Windows' $null $rng2.Next(0, 5) ('KIOSK-{0:000}' -f $n) }

#endregion

#region Écriture --------------------------------------------------------------

function Save-Json($Obj, [string]$Name) {
    $path = Join-Path $fixturesDir $Name
    $json = $Obj | ConvertTo-Json -Depth 12 -Compress
    [System.IO.File]::WriteAllText($path, $json, [System.Text.UTF8Encoding]::new($false))
    '{0,-15} {1,8:N0} Ko' -f $Name, ((Get-Item -LiteralPath $path).Length / 1KB)
}

$base = [ordered]@{
    schema = 1; seed = $Seed; dataset = 'base'
    groups = $groups; filters = $filters; objects = $objects
    managedDevices = $devices; userMemberOf = $userMemberOf; deviceMemberOf = $deviceMemberOf
}
Save-Json $base 'base.json'

# Jeu « modifié » : copie profonde puis changements contrôlés.
$mod = [System.IO.File]::ReadAllText((Join-Path $fixturesDir 'base.json')) | ConvertFrom-Json -AsHashtable
$mod['dataset'] = 'modified'
$changedDate = '2026-11-10T09:00:00Z'
$protected = [System.Collections.Generic.HashSet[string]]::new([string[]](@($refObjectIds) + @($unassigned['id'])))
function Get-Candidates([string]$Key) { @($mod['objects'][$Key] | Where-Object { -not $protected.Contains($_['id']) -and @($_['assignments']).Count -gt 0 }) }

$changed = [System.Collections.Generic.List[string]]::new()
foreach ($key in 'deviceConfigurations', 'configurationPolicies', 'mobileApps', 'deviceManagementScripts', 'deviceHealthScripts', 'deviceCompliancePolicies') {
    $o = (Get-Candidates $key)[7]
    $o['assignments'] = @($o['assignments']) + @(New-Assignment $key (New-Target 'groupAssignmentTarget' (Pick $hot) $false))
    $o['lastModifiedDateTime'] = $changedDate
    $changed.Add($o['id']); $null = $protected.Add($o['id'])
}
# Changement d'assignation SANS changement de lastModifiedDateTime (risque n°4 de la spec)
$silent = (Get-Candidates 'deviceCompliancePolicies')[3]
$silent['assignments'] = @($silent['assignments']) + @(New-Assignment 'deviceCompliancePolicies' (New-Target 'exclusionGroupAssignmentTarget' (Pick $hot) $false))
$null = $protected.Add($silent['id'])

$deleted = [System.Collections.Generic.List[string]]::new()
foreach ($key in 'deviceConfigurations', 'configurationPolicies', 'mobileApps', 'deviceHealthScripts', 'intents') {
    $victim = (Get-Candidates $key)[11]
    $mod['objects'][$key] = @($mod['objects'][$key] | Where-Object { $_['id'] -ne $victim['id'] })
    $deleted.Add($victim['id'])
}
$added = [System.Collections.Generic.List[string]]::new()
foreach ($key in 'deviceConfigurations', 'configurationPolicies', 'mobileApps', 'deviceManagementScripts', 'deviceHealthScripts') {
    $spec = $typeSpecs[$key]
    $o = [ordered]@{ id = (New-Id) }
    $o[$spec.Name] = 'Nouvel élément (démo) - ' + $key
    $o['lastModifiedDateTime'] = $changedDate
    $o['@odata.type'] = '#microsoft.graph.' + $spec.Odata[0]
    if ($key -eq 'configurationPolicies') { $o['platforms'] = 'windows10' }
    $o['assignments'] = @((New-Assignment $key (New-Target 'groupAssignmentTarget' (Pick $hot) $false)))
    $mod['objects'][$key] = @($mod['objects'][$key]) + @($o)
    $added.Add($o['id'])
}
# Groupes : 3 ajoutés
$addedGroups = foreach ($g in 1..3) { $ng = [ordered]@{ id = (New-Id); displayName = "GRP-Nouveau-Démo-$g" }; $mod['groups'] = @($mod['groups']) + @($ng); $ng.id }
Save-Json $mod 'modified.json'

$expected = [ordered]@{
    seed             = $Seed
    referenceGroup   = [ordered]@{ id = $specialIds.reference; name = $special.reference; count = 26; objectIds = $refObjectIds }
    emptyGroup       = [ordered]@{ id = $specialIds.empty; name = $special.empty }
    xssGroup         = [ordered]@{ id = $specialIds.xss; name = $special.xss }
    deletedGroupId   = $deletedGroupId
    unassignedObject = [ordered]@{ id = $unassigned['id']; type = 'deviceConfigurations' }
    globalExclusionObjectId = $exclRef['id']
    targetVariants   = [ordered]@{
        noHash   = [ordered]@{ objectId = $noHashObj['id']; groupId = $noHashGroup }
        scopeTag = [ordered]@{ objectId = $scopeTagObj['id']; groupId = $scopeTagGroup }
        other    = [ordered]@{ objectId = $otherObj['id']; rawType = 'configurationManagerCollectionAssignmentTarget' }
    }
    duplicateName    = 'GRP-Doublon-Démo'
    demoUser         = [ordered]@{ id = $demoUser.id; name = $demoUser.name; groupCount = @($userMemberOf[$demoUser.id]).Count; deviceIds = @($demoPc.id, $demoOld.id); staleDeviceId = $demoOld.id }
    demoUser2        = [ordered]@{ id = $demoUser2.id; name = $demoUser2.name; deviceIds = @($demoPc2.id, $demoPhone2.id) }
    deviceCount      = $devices.Count
    userCount        = $mockUsers.Count
    groupCount       = $groups.Count
    modified         = [ordered]@{ changed = $changed; silentChanged = @($silent['id']); deleted = $deleted; added = $added; addedGroups = @($addedGroups) }
}
Save-Json $expected 'expected.json'

#endregion
