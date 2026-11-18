#Requires -Version 7.0
<#
.SYNOPSIS
    Tests automatisés d'IntuneAssignLens (mode Mock, aucun réseau sortant).

.DESCRIPTION
    Script autonome avec assertions simples (Pester installé = 3.4, trop ancien ; rien n'est installé).
    Le seul trafic est local : 127.0.0.1 vers le serveur de test.

.PARAMETER Section
    Limite l'exécution à certaines sections (Guard, Collect, Index, Search, Mock, Server, Static).

.EXAMPLE
    pwsh -File .\tests\Run-Tests.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Guard', 'Collect', 'Inventory', 'Index', 'Search', 'Sync', 'Cache', 'Mock', 'Server', 'Static')]
    [string[]]$Section = @('Guard', 'Collect', 'Inventory', 'Index', 'Search', 'Sync', 'Cache', 'Mock', 'Server', 'Static')
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($f in 'Config', 'Log', 'GraphClient', 'Collectors', 'Index', 'Cache', 'Sync', 'Server') { . (Join-Path $root "src\$f.ps1") }
Initialize-IalLog -Quiet
# Dossier de cache de test, isolé (jamais le vrai cache de l'utilisateur), supprimé en fin de tests.
$script:TestCacheDir = Join-Path ([System.IO.Path]::GetTempPath()) ("IalTests-" + [guid]::NewGuid().ToString('N'))
Initialize-IalCache -Directory $script:TestCacheDir -Disabled

function New-IalTestFullState {
    <# État dont le jeton simulé contient DeviceManagementScripts.Read.All et où les remédiations sont activées. #>
    $s = New-IalAppState -Mode Mock
    $s.TokenScopes = @($script:IalConfig.Scopes) + 'DeviceManagementScripts.Read.All'
    $s.EnabledOptionalTypes = @('deviceHealthScripts')
    return $s
}

function Get-IalTestSignature {
    <# Empreinte canonique des données : id -> nom|date|assignations triées. #>
    param($Index)
    $sig = @{}
    foreach ($o in $Index.ObjectById.Values) {
        $as = @($o.assignments | Where-Object { $_ } | ForEach-Object { '{0}/{1}/{2}/{3}/{4}/{5}' -f $_.target, $_.groupId, $_.mode, $_.intent, $_.filterId, $_.filterMode } | Sort-Object)
        $sig[$o.id] = '{0}|{1}|{2}' -f $o.name, $o.lastModified, ($as -join ';')
    }
    return $sig
}
function Compare-IalTestSignature($A, $B) {
    $diff = [System.Collections.Generic.List[string]]::new()
    foreach ($k in $A.Keys) { if (-not $B.ContainsKey($k) -or $A[$k] -ne $B[$k]) { $diff.Add($k) } }
    foreach ($k in $B.Keys) { if (-not $A.ContainsKey($k)) { $diff.Add($k) } }
    return , $diff
}

$script:Pass = 0
$script:Fail = [System.Collections.Generic.List[string]]::new()
function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) { $script:Pass++; Write-Host "  [OK]   $Name" -ForegroundColor Green }
    else { $script:Fail.Add($Name); Write-Host "  [ÉCHEC] $Name" -ForegroundColor Red }
}
function Assert-Throws([scriptblock]$Block, [string]$Name, [string]$Kind) {
    try { & $Block; Assert-True $false "$Name (aucune exception)" }
    catch {
        $k = $_.Exception.Data['IalKind']
        if ($Kind) { Assert-True ($k -eq $Kind) "$Name (attendu $Kind, obtenu '$k' : $($_.Exception.Message))" }
        else { Assert-True $true $Name }
    }
}
function Start-Section([string]$Title) { Write-Host "`n== $Title ==" -ForegroundColor Cyan }

$fixtures = Join-Path $root 'mock\fixtures'
if (-not (Test-Path (Join-Path $fixtures 'base.json'))) { & (Join-Path $root 'mock\New-MockData.ps1') | Out-Null }
$expected = Get-Content (Join-Path $fixtures 'expected.json') -Raw | ConvertFrom-Json -AsHashtable
Initialize-IalGraphMock -FixturesDir $fixtures
$script:Slept = [System.Collections.Generic.List[double]]::new()
$script:IalGraph.Sleep = { param($s) $script:Slept.Add($s) }   # aucune attente réelle pendant les tests
$V1 = $script:IalConfig.GraphBaseV1
$BETA = $script:IalConfig.GraphBaseBeta

# =====================================================================================
if ('Guard' -in $Section) {
    Start-Section 'Garde-fou lecture seule'
    # Transport espion : prouve qu'aucune requête refusée n'atteint le transport.
    $realMock = $script:IalTransportMock
    $script:SpyCalls = 0
    $script:IalTransportMock = { param($m, $u, $b) $script:SpyCalls++; @{ StatusCode = 200; Headers = @{}; Content = @{ value = @() } } }

    foreach ($m in 'POST', 'PATCH', 'PUT', 'DELETE', 'MERGE', 'OPTIONS', 'HEAD') {
        Assert-Throws { Invoke-GraphRead -Method $m -Uri "$V1/deviceManagement/deviceConfigurations" } "$m hors `$batch refusé" 'Guard'
    }
    Assert-Throws { Invoke-GraphRead -Method 'post' -Uri "$V1/groups/x/members/`$ref" -Body @{} } 'POST minuscule refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri 'https://evil.example.com/v1.0/groups' } 'Hôte étranger refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri 'https://graph.microsoft.com.evil.com/v1.0/groups' } 'Hôte suffixé refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri 'http://graph.microsoft.com/v1.0/groups' } 'HTTP non chiffré refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri 'https://user@graph.microsoft.com/v1.0/groups' } 'Userinfo refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri 'https://graph.microsoft.com:8443/v1.0/groups' } 'Port non standard refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri '/v1.0/groups' } 'URL relative refusée' 'Guard'
    Assert-Throws { Invoke-GraphRead -Uri "$V1/groups" -Body @{ a = 1 } } 'GET avec corps refusé' 'Guard'

    $bad = @(
        @{ n = 'Sous-requête PATCH'; b = @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups' }, @{ id = '2'; method = 'PATCH'; url = '/groups/x' }) } }
        @{ n = 'Sous-requête DELETE'; b = @{ requests = @(@{ id = '1'; method = 'DELETE'; url = '/groups/x' }) } }
        @{ n = 'Sous-requête POST'; b = @{ requests = @(@{ id = '1'; method = 'POST'; url = '/groups' }) } }
        @{ n = 'Sous-requête sans méthode'; b = @{ requests = @(@{ id = '1'; url = '/groups' }) } }
        @{ n = 'Sous-requête GET avec corps'; b = @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups'; body = @{} }) } }
        @{ n = 'Sous-requête URL absolue'; b = @{ requests = @(@{ id = '1'; method = 'GET'; url = 'https://evil.example.com/x' }) } }
        @{ n = 'Sous-requête //hôte'; b = @{ requests = @(@{ id = '1'; method = 'GET'; url = '//evil.example.com/x' }) } }
        @{ n = 'Sous-requête $batch imbriqué'; b = @{ requests = @(@{ id = '1'; method = 'GET'; url = '/$batch' }) } }
        @{ n = 'Lot vide'; b = @{ requests = @() } }
        @{ n = 'Lot de 21'; b = @{ requests = @(1..21 | ForEach-Object { @{ id = "$_"; method = 'GET'; url = '/groups' } }) } }
        @{ n = 'Corps sans requests'; b = @{ foo = 1 } }
        @{ n = 'Corps JSON texte avec PATCH'; b = '{"requests":[{"id":"1","method":"PATCH","url":"/groups/x"}]}' }
    )
    foreach ($c in $bad) { Assert-Throws { Invoke-GraphRead -Method POST -Uri "$BETA/`$batch" -Body $c.b } "`$batch refusé : $($c.n)" 'Guard' }
    Assert-Throws { Invoke-GraphRead -Method POST -Uri "$BETA/`$batch?x=1" -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups' }) } } '$batch avec paramètre refusé' 'Guard'
    Assert-Throws { Invoke-GraphRead -Method POST -Uri "$BETA/groups/`$batch" -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups' }) } } 'POST vers un faux $batch refusé' 'Guard'
    Assert-True ($script:SpyCalls -eq 0) 'Aucune requête refusée n''a atteint le transport'

    $null = Invoke-GraphRead -Method POST -Uri "$BETA/`$batch" -Body @{ requests = @(@{ id = '1'; method = 'GET'; url = '/groups' }, @{ id = '2'; method = 'get'; url = '/deviceManagement/deviceConfigurations' }) }
    $null = Invoke-GraphRead -Uri "$V1/groups?`$select=id"
    Assert-True ($script:SpyCalls -eq 2) '$batch 100 % GET et GET simple acceptés'

    # 429 permanent : nombre maximal de tentatives puis erreur claire
    $script:SpyCalls = 0
    $script:IalTransportMock = { param($m, $u, $b) $script:SpyCalls++; @{ StatusCode = 429; Headers = @{ 'Retry-After' = '3' }; Content = $null } }
    $script:Slept.Clear()
    Assert-Throws { Invoke-GraphRead -Uri "$V1/groups" } '429 permanent : erreur après le maximum de tentatives' 'Throttled'
    Assert-True ($script:SpyCalls -eq $script:IalConfig.MaxRetries) "429 : exactement $($script:IalConfig.MaxRetries) tentatives"
    Assert-True (@($script:Slept | Where-Object { $_ -ne 3 }).Count -eq 0) '429 : Retry-After respecté (3 s)'
    # 503 sans Retry-After : repli exponentiel plafonné
    $script:IalTransportMock = { param($m, $u, $b) @{ StatusCode = 503; Headers = @{}; Content = $null } }
    $script:Slept.Clear()
    Assert-Throws { Invoke-GraphRead -Uri "$V1/groups" } '503 permanent : erreur' 'Graph'
    $expo = @(2, 4, 8, 16, 32)
    Assert-True ((@($script:Slept) -join ',') -eq ($expo -join ',')) "503 : repli exponentiel ($(@($script:Slept) -join ','))"
    $script:IalTransportMock = { param($m, $u, $b) @{ StatusCode = 403; Headers = @{}; Content = $null } }
    Assert-Throws { Invoke-GraphRead -Uri "$V1/groups" } '403 : erreur Forbidden sans nouvelle tentative' 'Forbidden'
    $script:IalTransportMock = $realMock
}

# =====================================================================================
if ('Collect' -in $Section) {
    Start-Section 'Collecte (pagination, 429, 5xx, non couvert)'
    Reset-IalMockFaults
    $script:IalMock.Faults.Throttle429Once = @('groups')
    $script:Slept.Clear()
    $g = Get-IalGroups
    Assert-True ($g.Count -eq $expected.groupCount) "Groupes paginés : $($g.Count) / $($expected.groupCount)"
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -like 'GET groups*' }).Count -ge 14) 'Groupes : au moins 14 pages de 999 (+1 reprise 429)'
    Assert-True ($script:Slept.Contains(1)) '429 avec Retry-After: 1 respecté'

    Reset-IalMockFaults
    $script:IalMock.Faults.Error500Once = @('deviceManagement/deviceConfigurations')
    $t = $script:IalObjectTypes | Where-Object Key -EQ 'deviceConfigurations'
    $l = Get-IalObjectList -Type $t
    Assert-True ($l.Count -eq 450) "500 transitoire puis succès ($($l.Count) objets)"
    Assert-True ($null -eq $l[0].assignments -and $l[0].Contains('lastModified')) 'Liste légère : sans assignations, avec lastModified'

    Reset-IalMockFaults
    $script:IalMock.Faults.LoopNextLink = @('devicemanagement/devicecompliancepolicies')
    $tc = $script:IalObjectTypes | Where-Object Key -EQ 'deviceCompliancePolicies'
    $script:IalMock.ListPageSize = 10
    Assert-Throws { Get-IalObjectList -Type $tc } 'Boucle de nextLink détectée' 'Graph'
    $script:IalMock.ListPageSize = 100

    Reset-IalMockFaults
    $script:IalMock.Faults.BatchSub429Once = $true
    $ids = [string[]]@($l[1..45] | ForEach-Object id)
    $a = Get-IalAssignments -Type $t -ObjectIds $ids
    Assert-True ($a.Count -eq 45 -and @($a.Values | Where-Object { $null -eq $_ }).Count -eq 0) '$batch : 45 objets, sous-requêtes 429 reprises'
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -eq 'POST $batch' }).Count -ge 6) '$batch : lots de 20 maximum (3 lots + reprises)'

    Reset-IalMockFaults
    $script:IalMock.Faults.Forbidden = @('intents')
    $state = New-IalAppState -Mode Mock
    Invoke-IalSyncFull -State $state
    $unc = @($state.Index.Uncovered | ForEach-Object { $_.key })
    Assert-True ('intents' -in $unc) 'Type en 403 marqué « non couvert » sans planter'
    Assert-True ('windowsAutopilotDeploymentProfiles' -in $unc -and 'deviceEnrollmentConfigurations' -in $unc) 'Autopilot / ESP : non couverts (scope hors des 4)'
    Assert-True (-not ($script:IalMock.CallLog | Where-Object { $_ -match 'autopilot|enrollment' })) 'Aucun appel vers un type non couvert'
    Reset-IalMockFaults
}

# =====================================================================================
if ('Inventory' -in $Section) {
    Start-Section 'Inventaire Graph vérifié (M4) : scopes, endpoints, cibles'
    $base = @($script:IalConfig.Scopes)
    $wantScopes = (@('DeviceManagementApps.Read.All', 'DeviceManagementConfiguration.Read.All', 'DeviceManagementManagedDevices.Read.All', 'Group.Read.All') -join ',')
    $haveScopes = ((@($base) | Sort-Object) -join ',')
    Assert-True ($base.Count -eq 4 -and ($haveScopes -ceq $wantScopes)) "Exactement les 4 scopes de lecture autorisés ($haveScopes)"
    Assert-True (@($base | Where-Object { $_ -notlike '*.Read.All' }).Count -eq 0) 'Scopes de base : lecture uniquement'
    foreach ($t in $script:IalObjectTypes) {
        $ok = $t.Path -match '^(deviceManagement|deviceAppManagement)/[A-Za-z]+$' -and $t.Version -in 'v1.0', 'beta' -and @($t.Scopes).Count -gt 0 -and
        @($t.Scopes | Where-Object { $_ -notlike '*.Read.All' }).Count -eq 0 -and
        ($t.Select -split ',') -contains 'id' -and ($t.Select -split ',') -contains $t.NameProp -and ($t.Select -split ',') -contains 'lastModifiedDateTime' -and
        $t.Select -notmatch 'Content|scriptContent|detectionScript|remediationScript'
        Assert-True $ok "Type $($t.Key) : endpoint, version, scopes en lecture, `$select minimal sans contenu de script"
    }
    $optional = Get-IalOptionalTypeKeys
    Assert-True ((($optional | Sort-Object) -join ',') -eq 'deviceEnrollmentConfigurations,deviceHealthScripts,windowsAutopilotDeploymentProfiles') "Types hors des 4 scopes : $($optional -join ', ')"

    $hs = $script:IalObjectTypes | Where-Object Key -EQ 'deviceHealthScripts'
    $c1 = Get-IalTypeCoverage -Type $hs -TokenScopes $base
    Assert-True (-not $c1.Covered -and $c1.Reason -like 'Permission non consentie*') 'Remédiations : non couvertes par défaut (permission non consentie)'
    $c2 = Get-IalTypeCoverage -Type $hs -TokenScopes ($base + 'DeviceManagementScripts.Read.All')
    Assert-True (-not $c2.Covered -and $c2.Reason -like '*activable avec -EnableOptionalTypes deviceHealthScripts*') 'Permission dans le jeton mais non activée : non lue, suggestion affichée'
    $c3 = Get-IalTypeCoverage -Type $hs -TokenScopes ($base + 'DeviceManagementScripts.Read.All') -EnabledOptionalTypes 'deviceHealthScripts'
    Assert-True $c3.Covered 'Activée ET présente dans le jeton : lue'
    $c4 = Get-IalTypeCoverage -Type $hs -TokenScopes $base -EnabledOptionalTypes 'deviceHealthScripts'
    Assert-True (-not $c4.Covered -and $c4.Reason -like 'Activé, mais*') 'Activée sans la permission dans le jeton : non lue (jamais demandée)'
    $dms = $script:IalObjectTypes | Where-Object Key -EQ 'deviceManagementScripts'
    Assert-True (Get-IalTypeCoverage -Type $dms -TokenScopes $base).Covered 'Scripts PowerShell : couverts par DeviceManagementConfiguration.Read.All (doc)'

    # Connexion : 4 scopes de base + Device.Read.All (accord de l'utilisateur, 2026-11-18), tous en lecture ;
    # repli sur les 4 de base si le consentement est refusé (contrôle statique du code).
    $cs = @(Get-IalConnectScopes)
    Assert-True ($cs.Count -eq 5 -and $cs[-1] -ceq 'Device.Read.All' -and @($cs | Where-Object { $_ -notlike '*.Read.All' }).Count -eq 0) "Scopes demandés à la connexion : 4 de base + Device.Read.All, lecture seule ($($cs -join ', '))"
    $gc = Get-Content (Join-Path $root 'src\GraphClient.ps1') -Raw
    Assert-True ($gc -match 'Scopes = \(Get-IalConnectScopes\)' -and $gc -match '\$p\.Scopes = \$script:IalConfig\.Scopes' -and ([regex]::Matches($gc, 'Connect-MgGraph\s+@p')).Count -eq 2) 'Connect-MgGraph : scopes de Get-IalConnectScopes, repli sur les 4 de base'

    # Normalisation des cibles (variantes documentées)
    $n1 = ConvertTo-IalAssignment -Raw @{ target = @{ '@odata.type' = 'microsoft.graph.groupAssignmentTarget'; groupId = 'g1' } }
    Assert-True ($n1.target -eq 'group' -and $n1.groupId -eq 'g1') 'Type OData sans « # » reconnu'
    $n2 = ConvertTo-IalAssignment -Raw @{ target = @{ '@odata.type' = '#microsoft.graph.scopeTagGroupAssignmentTarget'; targetType = 'device'; entraObjectId = 'g2' } }
    Assert-True ($n2.target -eq 'group' -and $n2.groupId -eq 'g2' -and $n2.source -eq 'scopeTag') 'scopeTagGroupAssignmentTarget : groupe via balise d''étendue'
    $n3 = ConvertTo-IalAssignment -Raw @{ target = @{ '@odata.type' = '#microsoft.graph.configurationManagerCollectionAssignmentTarget'; collectionId = 'X' } }
    Assert-True ($n3.target -eq 'other' -and $n3.rawType -eq 'configurationManagerCollectionAssignmentTarget') 'Cible inconnue conservée (« autre »), pas ignorée'
    $n4 = ConvertTo-IalAssignment -Raw @{ target = @{ '@odata.type' = '#microsoft.graph.exclusionGroupAssignmentTarget'; groupId = 'g3' } }
    Assert-True ($n4.mode -eq 'exclude') 'Exclusion reconnue'

    # Synchro par défaut : aucun appel vers un type hors des 4 scopes
    Reset-IalMockFaults
    Set-IalMockDataset -Name 'base'
    $si = New-IalAppState -Mode Mock
    Invoke-IalSync -State $si -Mode full
    Assert-True (-not ($script:IalMock.CallLog | Where-Object { $_ -match 'devicehealthscripts|autopilot|enrollment' })) 'Par défaut : aucun appel vers Remédiations, Autopilot, ESP'
    $unc = @($si.Index.Uncovered | ForEach-Object { $_.key })
    Assert-True ('deviceHealthScripts' -in $unc) 'Remédiations listées comme « non couvert » dans /api/status'
    $tv = $expected.targetVariants
    $gv = Get-IalGroupView -Index $si.Index -GroupId $tv.noHash.groupId
    Assert-True (@($gv.items | Where-Object objectId -EQ $tv.noHash.objectId).Count -ge 1) 'Index : assignation à type sans « # » visible côté groupe'
    $gv2 = Get-IalGroupView -Index $si.Index -GroupId $tv.scopeTag.groupId
    Assert-True (@($gv2.items | Where-Object { $_.objectId -eq $tv.scopeTag.objectId -and $_.via -like '*balise*' }).Count -ge 1) 'Index : cible par balise d''étendue visible côté groupe'
    $ov = Get-IalObjectView -Index $si.Index -ObjectId $tv.other.objectId
    Assert-True (@($ov.assignments | Where-Object { $_.target -eq 'other' -and $_.via -like '*configurationManagerCollection*' }).Count -eq 1) 'Index : cible non prise en charge affichée sur l''élément'
    Assert-True (@($si.Index.Global | Where-Object { $_.Assignment.target -eq 'other' }).Count -eq 0) 'Cible « autre » jamais classée en règle globale'

    # ---- Fiches Utilisateur / Machine (appareils + appartenances lues à la demande)
    Assert-True ($si.Index.Counts.devices -eq $expected.deviceCount -and $si.Index.Counts.users -eq $expected.userCount) "Appareils et utilisateurs indexés ($($si.Index.Counts.devices) / $($si.Index.Counts.users))"
    $su = Search-IalIndex -Index $si.Index -Query 'camille demo' -Kind user
    Assert-True ($su.total -eq 1 -and $su.results[0].id -eq $expected.demoUser.id -and $su.results[0].count -eq 2) 'Recherche utilisateur : nom, sans accent, 2 appareils'
    Assert-True ((Search-IalIndex -Index $si.Index -Query 'demo.example' -Kind user).total -eq 0) 'Recherche utilisateur : le domaine de l''UPN (commun à tous) est ignoré'
    $sd = Search-IalIndex -Index $si.Index -Query 'pc-demo-ancien' -Kind device
    Assert-True ($sd.total -eq 1 -and $sd.results[0].stale) 'Recherche machine : appareil inactif signalé'
    $script:IalMock.CallLog.Clear()
    $demoDevs = @($expected.demoUser.deviceIds | ForEach-Object { $si.Index.DeviceById[$_] })
    $mem = Get-IalMemberships -UserId $expected.demoUser.id -DeviceIds @($demoDevs | ForEach-Object { $_['aadId'] })
    Assert-True ($mem.user.ok -and @($mem.user.groups).Count -eq $expected.demoUser.groupCount) "Groupes de l'utilisateur : $(@($mem.user.groups).Count) (pagination suivie, rôles d'annuaire ignorés)"
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -eq 'POST $batch' }).Count -eq 1) 'Appartenances : un seul $batch pour l''utilisateur et ses appareils'
    Assert-True (@($mem.devices.Values | Where-Object { $_.ok }).Count -eq 2) 'Groupes des deux appareils lus'
    $uv = Get-IalUserView -Index $si.Index -UserId $expected.demoUser.id -Memberships $mem
    Assert-True (@($uv.devices).Count -eq 2 -and $uv.devices[0].stale -eq $false -and $uv.devices[1].id -eq $expected.demoUser.staleDeviceId -and $uv.devices[1].stale) 'Fiche utilisateur : appareil actif d''abord, ancien appareil inactif'
    Assert-True (@($uv.groups).Count -eq $expected.demoUser.groupCount -and $uv.groups[0].used -gt 0) 'Fiche utilisateur : groupes, ceux utilisés dans Intune en premier'
    $refObj = @($uv.configs | Where-Object { $_.objectId -in @($expected.referenceGroup.objectIds) })
    Assert-True ($refObj.Count -gt 0 -and @($refObj | Where-Object { @($_.targets).Count -eq 2 }).Count -gt 0) "Fiche utilisateur : éléments du groupe de référence, par appareil ($($refObj.Count))"
    $dv = Get-IalDeviceView -Index $si.Index -DeviceId $expected.demoUser.deviceIds[0] -Memberships $mem
    Assert-True ($dv.user.id -eq $expected.demoUser.id -and $dv.userGroupCount -eq $expected.demoUser.groupCount -and @($dv.configs).Count -gt 0) 'Fiche machine : utilisateur principal et éléments via l''utilisateur'
    $script:IalMock.Faults.Forbidden = @('deviceMemberOf')
    $mem403 = Get-IalMemberships -UserId $expected.demoUser.id -DeviceIds @($demoDevs | ForEach-Object { $_['aadId'] })
    $uv403 = Get-IalUserView -Index $si.Index -UserId $expected.demoUser.id -Memberships $mem403
    Assert-True ($mem403.user.ok -and @($uv403.warnings | Where-Object { $_ -like '*Device.Read.All*' }).Count -ge 1 -and @($uv403.configs).Count -gt 0) 'Groupes des machines refusés (403) : avertissement, ciblage par l''utilisateur conservé'
    Reset-IalMockFaults
    $saveMode = $script:IalGraph.Mode
    $script:IalGraph.Mode = 'Real'
    try {
        $noScope = Get-IalMemberships -UserId '' -DeviceIds @('x') -TokenScopes @($script:IalConfig.Scopes)
        Assert-True (-not $noScope.devices['x'].ok -and $noScope.devices['x'].reason -like '*Device.Read.All*') 'Réel sans Device.Read.All dans le jeton : aucun appel, motif affiché'
    }
    finally { $script:IalGraph.Mode = $saveMode }

    # ---- Règles de ciblage (index synthétique, résultat exact attendu)
    # Assignations au format interne complet (celui de ConvertTo-IalAssignment).
    function New-TA([string]$Target, [string]$GroupId, [string]$Mode = 'include') { [ordered]@{ target = $Target; groupId = $(if ($GroupId) { $GroupId } else { $null }); mode = $Mode; intent = $null; filterId = $null; filterMode = $null; source = $null; rawType = $null } }
    $ti = New-IalIndex -Data @{
        Groups  = @(@{ id = 'gU'; displayName = 'Users' }, @{ id = 'gD'; displayName = 'Devices' }, @{ id = 'gX'; displayName = 'Excl' })
        Objects = @(
            @{ id = 'o1'; name = 'User-wide'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'group' 'gU' 'include')) }
            @{ id = 'o2'; name = 'Device-only'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'group' 'gD' 'include')) }
            @{ id = 'o3'; name = 'Excluded on PC'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'group' 'gU' 'include'), (New-TA 'group' 'gD' 'exclude')) }
            @{ id = 'o4'; name = 'iOS only'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = 'iOS'; assignments = @((New-TA 'allUsers' '' 'include')) }
            @{ id = 'o5'; name = 'All devices'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'allDevices' '' 'include'), (New-TA 'group' 'gX' 'exclude')) }
            @{ id = 'o6'; name = 'Other group'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'group' 'gX' 'include')) }
            @{ id = 'o7'; name = 'Device excl device'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'allDevices' '' 'include'), (New-TA 'group' 'gD' 'exclude')) }
            @{ id = 'o8'; name = 'User excl user'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'allUsers' '' 'include'), (New-TA 'group' 'gU' 'exclude')) }
            @{ id = 'o9'; name = 'Device excl user'; family = 'F'; typeKey = 't'; odataType = ''; lastModified = ''; platform = ''; assignments = @((New-TA 'group' 'gD' 'include'), (New-TA 'group' 'gU' 'exclude')) }
        )
        Devices = @(
            @{ id = 'd1'; name = 'PC'; userId = 'u1'; platform = 'Windows'; aadId = 'a1' }
            @{ id = 'd2'; name = 'Phone'; userId = 'u1'; platform = 'iOS'; aadId = 'a2' }
        )
    }
    $tg = @(Get-IalTargeting -Index $ti -Devices @($ti.DeviceById['d1'], $ti.DeviceById['d2']) -UserGroupIds @('gU') -DeviceGroupIds @{ d1 = @('gD') } -HasUser $true)
    $by = @{}; foreach ($c in $tg) { $by[$c.objectId] = $c }
    $st = { param($o, $d) (@($by[$o].targets | Where-Object deviceId -EQ $d) | ForEach-Object mode) -join '' }
    Assert-True ((& $st 'o1' 'd1') -eq 'include' -and (& $st 'o1' 'd2') -eq 'include' -and $by['o1'].scope -eq 'user') 'Ciblage : groupe de l''utilisateur = tous ses appareils'
    Assert-True ((& $st 'o2' 'd1') -eq 'include' -and (& $st 'o2' 'd2') -eq '' -and $by['o2'].scope -eq 'device') 'Ciblage : groupe d''appareil = cet appareil seulement'
    $o3d1 = @($by['o3'].targets | Where-Object deviceId -EQ 'd1')[0]
    Assert-True ((& $st 'o3' 'd1') -eq 'include' -and $o3d1.mixedExcl -and (& $st 'o3' 'd2') -eq 'include' -and -not @($by['o3'].targets | Where-Object deviceId -EQ 'd2')[0].mixedExcl) 'Ciblage : inclusion utilisateur + exclusion appareil = mélange non pris en charge par Intune, inclusion gardée et signalée'
    Assert-True ((& $st 'o7' 'd1') -eq 'exclude' -and -not @($by['o7'].targets)[0].mixedExcl) 'Ciblage : exclusion du même type (appareil / appareil) : l''exclusion l''emporte'
    Assert-True ((& $st 'o8' 'd1') -eq 'exclude' -and (& $st 'o8' 'd2') -eq 'exclude') 'Ciblage : exclusion du même type (utilisateur / utilisateur) : exclu sur tous ses appareils'
    Assert-True ((& $st 'o9' 'd1') -eq 'include' -and @($by['o9'].targets | Where-Object deviceId -EQ 'd1')[0].mixedExcl) 'Ciblage : inclusion appareil + exclusion utilisateur : les appareils ne sont pas exclus (Learn)'
    Assert-True ((& $st 'o4' 'd1') -eq '' -and (& $st 'o4' 'd2') -eq 'include') 'Ciblage : élément iOS ignoré sur le PC Windows'
    Assert-True ((& $st 'o5' 'd1') -eq 'include' -and (& $st 'o5' 'd2') -eq 'include') 'Ciblage : « Tous les appareils » sur chaque appareil (exclusion d''un autre groupe sans effet)'
    Assert-True (-not $by.ContainsKey('o6')) 'Ciblage : groupe sans rapport ignoré'
    $tg0 = @(Get-IalTargeting -Index $ti -Devices @() -UserGroupIds @('gU') -HasUser $true)
    Assert-True (((@($tg0 | ForEach-Object objectId) | Sort-Object) -join ',') -eq 'o1,o3,o4,o8') 'Utilisateur sans appareil : seuls les ciblages par l''utilisateur'

    # Avec activation explicite + jeton : remédiations lues
    $sf = New-IalTestFullState
    $script:IalMock.CallLog.Clear()
    Invoke-IalSync -State $sf -Mode full
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -match 'devicehealthscripts' }).Count -gt 0 -and @($sf.Index.ObjectById.Values | Where-Object typeKey -EQ 'deviceHealthScripts').Count -gt 0) 'Activation explicite + jeton : remédiations lues'

    # $select refusé : repli sur le minimum, jamais sans $select
    Reset-IalMockFaults
    $script:IalMock.Faults.RejectSelect = @('deviceManagement/configurationPolicies')
    $cp = $script:IalObjectTypes | Where-Object Key -EQ 'configurationPolicies'
    $lst = Get-IalObjectList -Type $cp
    Assert-True ($lst.Count -gt 0) "`$select refusé (400) : repli réussi ($($lst.Count) objets)"
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -match 'configurationpolicies' }).Count -ge 2) '$select refusé : nouvelle tentative avec $select minimal'
    Reset-IalMockFaults
}

# =====================================================================================
$script:State = $null
if ($Section | Where-Object { $_ -in 'Index', 'Search', 'Server' }) {
    Reset-IalMockFaults
    $script:State = New-IalAppState -Mode Mock
    Invoke-IalSyncFull -State $script:State
}

if ('Index' -in $Section) {
    Start-Section 'Index'
    $idx = $script:State.Index
    $ref = Get-IalGroupView -Index $idx -GroupId $expected.referenceGroup.id
    Assert-True ($ref.total -eq 26) "Groupe de référence : $($ref.total) éléments (attendu 26)"
    $refIds = @($ref.items | ForEach-Object objectId | Sort-Object)
    Assert-True (($refIds -join ',') -eq ((@($expected.referenceGroup.objectIds) | Sort-Object) -join ',')) 'Groupe de référence : mêmes 26 identifiants'
    Assert-True (@($ref.items | Where-Object mode -EQ 'exclude').Count -ge 1) 'Groupe de référence : exclusions présentes'
    Assert-True (@($ref.items | Where-Object { $_.filter -and $_.filter.name -notlike 'Filtre inconnu*' }).Count -ge 1) 'Filtres résolus en noms'
    Assert-True (@($ref.items | Where-Object { $_.typeKey -eq 'mobileApps' -and $_.intent }).Count -eq 6) 'Intents des applications présents'
    $ge = @($ref.global | Where-Object { $_.objectId -eq $expected.globalExclusionObjectId -and $_.excludedForGroup })
    Assert-True ($ge.Count -ge 1) 'Exclusion du groupe sur une règle « Tous les appareils » signalée'
    Assert-True (@($ref.global | Where-Object { $_.target -eq 'allLicensedUsers' }).Count -gt 0 -and @($ref.global | Where-Object { $_.target -eq 'allDevices' }).Count -gt 0) 'Règles globales All users / All devices présentes'

    $del = Get-IalGroupView -Index $idx -GroupId $expected.deletedGroupId
    Assert-True ($del -and -not $del.group.exists -and $del.group.name -like 'Groupe supprimé*' -and $del.total -eq 3) 'Groupe supprimé encore référencé : affiché sans planter'
    $empty = Get-IalGroupView -Index $idx -GroupId $expected.emptyGroup.id
    Assert-True ($empty -and $empty.group.exists -and $empty.total -eq 0) 'Groupe sans assignation : 0 élément'
    Assert-True ($null -eq (Get-IalGroupView -Index $idx -GroupId ([guid]::NewGuid().ToString()))) 'Groupe inconnu : $null'
    $un = Get-IalObjectView -Index $idx -ObjectId $expected.unassignedObject.id
    Assert-True ($un.unassigned -and $un.assignments.Count -eq 0) 'Objet sans assignation signalé'
    $delObj = Get-IalObjectView -Index $idx -ObjectId $del.items[0].objectId
    Assert-True (@($delObj.assignments | Where-Object { $_.groupExists -eq $false }).Count -ge 1) 'Élément → groupes : groupe supprimé signalé'
    $go = Get-IalObjectView -Index $idx -ObjectId $expected.globalExclusionObjectId
    Assert-True ($go.assignments[0].target -ne 'group') 'Élément → groupes : cibles globales en tête'

    $badDates = @($idx.ObjectById.Values | Where-Object { $_.lastModified -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$' })
    Assert-True ($badDates.Count -eq 0) "Dates lastModified en ISO 8601 UTC ($($badDates.Count) non conformes)"

    # Cohérence index inversé <-> assignations
    $sumByGroup = 0; foreach ($k in $idx.ByGroup.Keys) { $sumByGroup += $idx.ByGroup[$k].Count }
    Assert-True (($sumByGroup + $idx.Global.Count + $idx.Counts.otherTargets) -eq $idx.Counts.assignments) "Index inversé + globales + autres cibles = total des assignations"
    $okAll = $true
    foreach ($o in $idx.ObjectById.Values) {
        foreach ($a in @($o.assignments | Where-Object { $_ -and $_.target -eq 'group' })) {
            if (-not (@($idx.ByGroup[$a.groupId] | Where-Object { $_.ObjectId -eq $o.id }).Count)) { $okAll = $false; break }
        }
        if (-not $okAll) { break }
    }
    Assert-True $okAll 'Chaque assignation de groupe est présente dans l''index inversé'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $hot = ($idx.ByGroup.GetEnumerator() | Sort-Object { $_.Value.Count } -Descending | Select-Object -First 1).Key
    $sw.Restart(); $hv = Get-IalGroupView -Index $idx -GroupId $hot; $null = ConvertTo-Json $hv -Depth 10 -Compress
    Assert-True ($sw.ElapsedMilliseconds -lt 300) "Ouverture du groupe le plus chargé ($($hv.total) éléments) : $($sw.ElapsedMilliseconds) ms < 300 ms"
}

if ('Search' -in $Section) {
    Start-Section 'Recherche'
    $idx = $script:State.Index
    $find = { param($q, $k = 'group') Search-IalIndex -Index $idx -Query $q -Kind $k -Limit 50 }
    $refName = $expected.referenceGroup.name
    Assert-True (@((& $find 'reference demo').results | Where-Object name -EQ $refName).Count -eq 1) 'Sans accents : « reference demo » trouve « Référence-Démo »'
    Assert-True (@((& $find 'GRP-RÉFÉRENCE').results | Where-Object name -EQ $refName).Count -eq 1) 'Casse : « GRP-RÉFÉRENCE »'
    Assert-True (@((& $find 'démo-26').results | Where-Object name -EQ $refName).Count -eq 1) 'Sous-chaîne : « démo-26 »'
    Assert-True ((& $find 'oenologie').total -gt 0) 'Ligature : « oenologie » trouve « Œnologie »'
    Assert-True (@((& $find 'GRP-Doublon-Démo').results).Count -eq 2) 'Doublons de nom : les deux groupes renvoyés'
    Assert-True ((& $find '   ').total -eq 0) 'Requête vide : aucun résultat'
    Assert-True ((& $find '<script>').total -eq 1) 'Caractères spéciaux recherchables'
    $r = & $find 'grp'
    Assert-True ($r.results[0].name.ToLowerInvariant().StartsWith('grp')) 'Classement : préfixe en premier'
    Assert-True (@((& $find 'sans assignation' 'object').results | Where-Object id -EQ $expected.unassignedObject.id).Count -eq 1) 'Recherche d''éléments'
    $times = foreach ($q in 'comptabilite', 'e', 'grp', 'pediatrie vip', 'a b c', 'zzzz', 'ile-de-france', 'ring1 test') {
        $null = & $find $q
        $sw = [System.Diagnostics.Stopwatch]::StartNew(); $null = & $find $q; $sw.Elapsed.TotalMilliseconds
    }
    $max = ($times | Measure-Object -Maximum).Maximum
    Assert-True ($max -lt 100) ("Recherche sur {0:N0} groupes : pire cas {1:N1} ms < 100 ms" -f $idx.Counts.groups, $max)
}

# =====================================================================================
if ('Sync' -in $Section) {
    Start-Section 'Synchronisation incrémentale (jeu « modifié »)'
    $mexp = $expected.modified
    Reset-IalMockFaults
    Set-IalMockDataset -Name 'base'
    $s1 = New-IalTestFullState
    Invoke-IalSync -State $s1 -Mode full
    $baseCount = $s1.Index.Counts.objects
    Assert-True ($s1.LastSyncStats.mode -eq 'full') 'Première synchro : complète'

    # Sans changement : aucune assignation relue, aucun $batch
    $script:IalMock.CallLog.Clear()
    Invoke-IalSync -State $s1 -Mode incremental
    Assert-True ($s1.LastSyncStats.mode -eq 'incremental' -and $s1.LastSyncStats.assignmentsRead -eq 0) "Incrémentale sans changement : 0 assignation relue ($($s1.LastSyncStats.assignmentsRead))"
    Assert-True (@($script:IalMock.CallLog | Where-Object { $_ -eq 'POST $batch' }).Count -eq 0) 'Incrémentale sans changement : aucun $batch'
    Assert-True ($s1.LastSyncStats.requests -lt 60) "Incrémentale sans changement : $($s1.LastSyncStats.requests) requêtes (listes légères uniquement)"

    # Jeu modifié
    Set-IalMockDataset -Name 'modified'
    $script:IalMock.CallLog.Clear()
    Invoke-IalSync -State $s1 -Mode incremental
    $st = $s1.LastSyncStats
    Assert-True ($st.added -eq $mexp.added.Count -and $st.changed -eq $mexp.changed.Count -and $st.deleted -eq $mexp.deleted.Count) "Détection : $($st.added) nouveaux, $($st.changed) modifiés, $($st.deleted) supprimés (attendu $($mexp.added.Count) / $($mexp.changed.Count) / $($mexp.deleted.Count))"
    $readIds = @($script:IalMock.CallLog | Where-Object { $_ -match '/([^/]+)/assignments$' } | ForEach-Object { ([regex]::Match($_, '/([^/]+)/assignments$')).Groups[1].Value } | Sort-Object -Unique)
    $want = @(@($mexp.added) + @($mexp.changed) | Sort-Object -Unique)
    Assert-True (($readIds -join ',') -eq (($want | ForEach-Object { $_.ToLowerInvariant() }) -join ',') -or ($readIds -join ',') -eq ($want -join ',')) "Seuls les nouveaux et modifiés sont relus ($($readIds.Count) / $($want.Count))"
    Assert-True (@($mexp.deleted | Where-Object { $s1.Index.ObjectById.ContainsKey($_) }).Count -eq 0) 'Les supprimés disparaissent de l''index'
    Assert-True (@($mexp.added | Where-Object { -not $s1.Index.ObjectById.ContainsKey($_) }).Count -eq 0) 'Les nouveaux apparaissent dans l''index'
    Assert-True (@($mexp.addedGroups | Where-Object { -not $s1.Index.GroupById.ContainsKey($_) }).Count -eq 0) 'Les nouveaux groupes sont résolus'

    # Comparaison avec une synchro complète du jeu modifié
    $s2 = New-IalTestFullState
    Invoke-IalSync -State $s2 -Mode full
    $diff = Compare-IalTestSignature (Get-IalTestSignature $s1.Index) (Get-IalTestSignature $s2.Index)
    Assert-True ($diff.Count -eq 1 -and $diff[0] -eq $mexp.silentChanged[0]) "Incrémentale = complète, sauf la modification « silencieuse » attendue ($($diff.Count) écart)"
    $grpOk = ($s1.Index.Counts.groups -eq $s2.Index.Counts.groups) -and ($s1.Index.Counts.assignments -eq $s2.Index.Counts.assignments - 1)
    Assert-True $grpOk 'Mêmes groupes ; une seule assignation d''écart (modification silencieuse)'

    # Parade 9.3 : relecture systématique d'un type => résultat identique à la complète
    Set-IalMockDataset -Name 'base'
    $s3 = New-IalTestFullState
    Invoke-IalSync -State $s3 -Mode full
    Set-IalMockDataset -Name 'modified'
    $saved = $script:IalConfig.AssignmentRereadTypes
    $script:IalConfig.AssignmentRereadTypes = @('deviceCompliancePolicies')
    Invoke-IalSync -State $s3 -Mode incremental
    $script:IalConfig.AssignmentRereadTypes = $saved
    $diff3 = Compare-IalTestSignature (Get-IalTestSignature $s3.Index) (Get-IalTestSignature $s2.Index)
    Assert-True ($diff3.Count -eq 0) "Avec relecture systématique de la conformité : identique à la complète ($($diff3.Count) écart)"

    # Synchro complète automatique si la dernière date de plus d'un jour
    $s3.Data.LastFullSyncAt = (Get-Date).AddDays(-3).ToString('o')
    Invoke-IalSync -State $s3 -Mode incremental
    Assert-True ($s3.LastSyncStats.mode -eq 'full') 'Dernière synchro complète > 1 jour : passage automatique en complète'

    # Annulation : l'index précédent reste en place
    $before = $s3.Index
    $s3.CancelSync = $true
    Invoke-IalSync -State $s3 -Mode full
    $s3.CancelSync = $false
    Assert-True ([object]::ReferenceEquals($before, $s3.Index) -and $s3.Phase -eq 'done') 'Annulation : données précédentes conservées'

    # Arrière-plan (ThreadJob) : un seul écrivain
    Set-IalMockDataset -Name 'base'
    $s4 = New-IalTestFullState
    $s4.Root = $root
    $job = Start-IalSyncJob -State $s4 -Root $root -Mode 'full'
    $job2 = Start-IalSyncJob -State $s4 -Root $root -Mode 'full'
    Assert-True ($null -ne $job -and $null -eq $job2) 'Une seule synchronisation à la fois'
    $sawProgress = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($s4.SyncRunning -and $sw.Elapsed.TotalSeconds -lt 120) {
        if ($s4.Phase -eq 'assignments' -and $s4.Done -gt 0) { $sawProgress = $true }
        Start-Sleep -Milliseconds 100
    }
    Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
    Remove-Job $job -Force
    Assert-True (-not $s4.SyncRunning -and $s4.Index -and $s4.Index.Counts.objects -eq $baseCount) "Synchro en arrière-plan terminée ($($s4.Index.Counts.objects) objets)"
    Assert-True $sawProgress 'Progression visible pendant la synchro (fait / total)'

    # Repli V16 : le runspace d'arrière-plan ne voit pas la session Graph -> bascule au premier plan
    $s5 = New-IalTestFullState
    $s5.Root = $root
    $s5.SimulateJobInitFailure = $true
    Register-IalSyncJob (Start-IalSyncJob -State $s5 -Root $root -Mode 'full')
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not ($s5.ForegroundSync -and -not $s5.SyncRunning -and $s5.Index) -and $sw.Elapsed.TotalSeconds -lt 120) {
        Update-IalSyncJobs -State $s5
        Start-Sleep -Milliseconds 100
    }
    Assert-True ($s5.ForegroundSync -and $s5.Index -and $s5.Index.Counts.objects -eq $baseCount -and $s5.Phase -eq 'done') "Repli V16 : synchro au premier plan réussie ($(if ($s5.Index) { $s5.Index.Counts.objects } else { 0 }) objets)"
    $s5.SimulateJobInitFailure = $false
    Set-IalMockDataset -Name 'base'
}

# =====================================================================================
if ('Cache' -in $Section) {
    Start-Section 'Cache disque (DPAPI, atomique, résistance aux pannes)'
    Initialize-IalCache -Directory $script:TestCacheDir
    Set-IalMockDataset -Name 'base'
    $sc = New-IalAppState -Mode Mock
    Invoke-IalSync -State $sc -Mode full     # écrit le cache
    $path = Get-IalCachePath -Mode Mock
    Assert-True (Test-Path $path) 'Cache écrit après une synchro réussie'
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $asText = [System.Text.Encoding]::UTF8.GetString($bytes)
    Assert-True ($asText -notmatch 'GRP-|displayName|Référence') 'Contenu illisible en clair (DPAPI)'
    $acl = Get-Acl -LiteralPath $script:TestCacheDir
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $others = @($acl.Access | Where-Object { $_.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]) -ne $me })
    Assert-True ($acl.AreAccessRulesProtected -and $others.Count -eq 0) 'Dossier de cache : héritage coupé, accès réservé à l''utilisateur courant'

    $c = Read-IalCache -Mode Mock
    $sr = New-IalAppState -Mode Mock
    $null = Set-IalStateData -State $sr -Data $c -Source 'cache'
    $d = Compare-IalTestSignature (Get-IalTestSignature $sc.Index) (Get-IalTestSignature $sr.Index)
    Assert-True ($d.Count -eq 0 -and $sr.Index.Counts.groups -eq $sc.Index.Counts.groups) 'Relecture du cache : données identiques'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Read-IalCache -Mode Mock
    $readMs = $sw.ElapsedMilliseconds
    Assert-True ($readMs -lt 5000) "Lecture du cache : $readMs ms"
    Assert-True ($null -eq (Read-IalCache -Mode Real)) 'Cache Mock jamais relu en mode réel'

    # Incrémentale à partir du cache (redémarrage)
    $script:IalMock.CallLog.Clear()
    Invoke-IalSync -State $sr -Mode incremental
    Assert-True ($sr.LastSyncStats.mode -eq 'incremental' -and $sr.LastSyncStats.assignmentsRead -eq 0) 'Redémarrage depuis le cache : incrémentale sans relecture des assignations'

    # Extinction brutale pendant l'écriture : l'ancien cache reste intact
    $hashBefore = (Get-FileHash $path).Hash
    $script:IalCache.BeforeCommit = { param($tmp) Copy-Item -LiteralPath $tmp -Destination "$tmp.crash.tmp"; throw 'Coupure simulée' }
    Set-IalMockDataset -Name 'modified'
    Invoke-IalSync -State $sr -Mode incremental
    $script:IalCache.BeforeCommit = $null
    Assert-True ((Get-FileHash $path).Hash -eq $hashBefore) 'Coupure pendant l''écriture : ancien cache intact'
    Assert-True ($null -ne (Read-IalCache -Mode Mock)) 'Coupure pendant l''écriture : cache toujours lisible'
    Assert-True (@(Get-ChildItem $script:TestCacheDir -Filter *.tmp).Count -eq 0) 'Fichiers temporaires orphelins nettoyés'
    Set-IalMockDataset -Name 'base'

    # Fichier tronqué, corrompu, autre schéma : ignoré sans plantage
    [System.IO.File]::WriteAllBytes($path, $bytes[0..([int]($bytes.Length / 2))])
    Assert-True ($null -eq (Read-IalCache -Mode Mock)) 'Cache tronqué : ignoré'
    $rnd = [byte[]]::new(4096); [System.Random]::new(1).NextBytes($rnd)
    [System.IO.File]::WriteAllBytes($path, $rnd)
    Assert-True ($null -eq (Read-IalCache -Mode Mock)) 'Cache corrompu : ignoré'
    $script:IalConfig.SchemaVersion = 99
    $null = Save-IalCache -Mode Mock -Data $sc.Data
    $script:IalConfig.SchemaVersion = 1
    Assert-True ($null -eq (Read-IalCache -Mode Mock)) 'Autre version de schéma : ignoré'
    $s5 = New-IalAppState -Mode Mock
    $s5.TenantId = 'tenant-a'
    $null = Save-IalCache -Mode Mock -Data $sc.Data -TenantId 'tenant-a'
    Assert-True ($null -eq (Read-IalCache -Mode Mock -TenantId 'tenant-b')) 'Autre tenant : ignoré'
    Assert-True ($null -ne (Read-IalCache -Mode Mock -TenantId 'tenant-a')) 'Même tenant : relu'

    Assert-True ((Clear-IalCache) -ge 1 -and $null -eq (Read-IalCache -Mode Mock)) 'Effacement du cache'
    Initialize-IalCache -Directory $script:TestCacheDir -Disabled
}

# =====================================================================================
if ('Mock' -in $Section) {
    Start-Section 'Générateur Mock déterministe'
    $before = (Get-FileHash (Join-Path $fixtures 'base.json')).Hash, (Get-FileHash (Join-Path $fixtures 'modified.json')).Hash
    & (Join-Path $root 'mock\New-MockData.ps1') | Out-Null
    $after = (Get-FileHash (Join-Path $fixtures 'base.json')).Hash, (Get-FileHash (Join-Path $fixtures 'modified.json')).Hash
    Assert-True (($before -join '') -eq ($after -join '')) 'Deux générations successives : fichiers identiques'
    Assert-True ($expected.groupCount -ge 13000) "Volume : $($expected.groupCount) groupes"
    $m = $expected.modified
    Assert-True ($m.changed.Count -gt 0 -and $m.added.Count -gt 0 -and $m.deleted.Count -gt 0 -and $m.silentChanged.Count -gt 0) 'Jeu « modifié » : ajouts, modifications, suppressions, modification silencieuse'
}

# =====================================================================================
function Invoke-RawHttp {
    <# Client HTTP brut (TcpClient) vers 127.0.0.1 : permet d'envoyer des en-têtes/chemins hostiles. #>
    param([int]$Port, [string]$Method = 'GET', [string]$Path = '/', [hashtable]$Headers = @{}, [string]$Body)
    $c = [System.Net.Sockets.TcpClient]::new('127.0.0.1', $Port)
    try {
        $c.ReceiveTimeout = 10000
        $s = $c.GetStream()
        $h = [ordered]@{ Host = "127.0.0.1:$Port"; Connection = 'close' }
        foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
        [byte[]]$bodyBytes = [byte[]]::new(0)
        if ($Body) { $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body) }
        if ($Method -in 'POST', 'PUT', 'PATCH', 'DELETE' -and -not $h.Contains('Content-Length')) { $h['Content-Length'] = $bodyBytes.Length }
        $txt = "$Method $Path HTTP/1.1`r`n" + (($h.Keys | ForEach-Object { if ($null -ne $h[$_]) { "${_}: $($h[$_])" } }) -join "`r`n") + "`r`n`r`n"
        $b = [System.Text.Encoding]::ASCII.GetBytes($txt)
        $s.Write($b, 0, $b.Length)
        if ($bodyBytes.Length) { $s.Write($bodyBytes, 0, $bodyBytes.Length) }
        $ms = [System.IO.MemoryStream]::new()
        $s.CopyTo($ms)
        $resp = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    finally { $c.Dispose() }
    $headEnd = $resp.IndexOf("`r`n`r`n")
    $head = if ($headEnd -ge 0) { $resp.Substring(0, $headEnd) } else { $resp }
    $lines = $head -split "`r`n"
    $hd = @{}
    foreach ($ln in $lines[1..($lines.Count - 1)]) { $i = $ln.IndexOf(':'); if ($i -gt 0) { $hd[$ln.Substring(0, $i).Trim()] = $ln.Substring($i + 1).Trim() } }
    [pscustomobject]@{
        Status  = [int]($lines[0] -split ' ')[1]
        Headers = $hd
        Body    = $(if ($headEnd -ge 0) { $resp.Substring($headEnd + 4) } else { '' })
    }
}

if ('Server' -in $Section) {
    Start-Section 'Serveur local'
    $srv = Start-IalServer -WebRoot (Join-Path $root 'web')
    $P = $srv.Port
    Assert-True ($srv.Listener.Prefixes -contains "http://127.0.0.1:$P/") "Écoute sur 127.0.0.1:$P uniquement"
    $script:State.Root = $root
    $script:State.SrvCallLog = $null
    $job = Start-ThreadJob -ArgumentList $root, $srv, $script:State, $fixtures, $script:TestCacheDir -ScriptBlock {
        param($root, $srv, $state, $fixtures, $cacheDir)
        foreach ($f in 'Config', 'Log', 'GraphClient', 'Collectors', 'Index', 'Cache', 'Sync', 'Server') { . (Join-Path $root "src\$f.ps1") }
        Initialize-IalLog -Quiet
        Initialize-IalCache -Directory $cacheDir
        Initialize-IalGraphMock -FixturesDir $fixtures
        $state.SrvCallLog = $script:IalMock.CallLog     # journal des appels Graph (Mock) du runspace serveur
        try { Invoke-IalServerLoop -Server $srv -State $state }
        finally { Stop-IalSyncJobs -State $state }
    }
    try {
        $tok = @{ 'X-Session' = $srv.Token }
        $sw0 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($null -eq $script:State.SrvCallLog -and $sw0.Elapsed.TotalSeconds -lt 30) { Start-Sleep -Milliseconds 100 }
        $callsBefore = $script:State.SrvCallLog.Count

        $r = Invoke-RawHttp -Port $P -Path '/'
        Assert-True ($r.Status -eq 200 -and $r.Body -match 'Intune Lens') 'GET / : 200'
        Assert-True ($r.Headers['Content-Security-Policy'] -like "default-src 'none'*") 'En-tête CSP présent'
        Assert-True ($r.Headers['X-Content-Type-Options'] -eq 'nosniff' -and $r.Headers['Referrer-Policy'] -eq 'no-referrer' -and $r.Headers['Cross-Origin-Resource-Policy'] -eq 'same-origin') 'En-têtes nosniff / no-referrer / CORP'
        Assert-True (-not $r.Headers.ContainsKey('Access-Control-Allow-Origin')) 'Aucun en-tête CORS'

        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/status').Status -eq 401) '/api/status sans jeton : 401'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ 'X-Session' = 'faux' }).Status -eq 401) '/api/status jeton faux : 401'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ 'X-Session' = $srv.Token.Substring(1) + 'A' }).Status -eq 401) '/api/status jeton presque juste : 401'
        $r = Invoke-RawHttp -Port $P -Path '/api/status' -Headers $tok
        $st = $r.Body | ConvertFrom-Json
        Assert-True ($r.Status -eq 200 -and $st.mode -eq 'Mock' -and $st.ready) '/api/status avec jeton : 200, mode Mock'
        Assert-True ($r.Headers['Cache-Control'] -eq 'no-store') '/api/* : Cache-Control no-store'

        $r = Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ Host = "evil.example.com:$P"; 'X-Session' = $srv.Token }
        Assert-True ($r.Status -in 400, 403) "Host étranger refusé ($($r.Status))"
        $r = Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ Host = "localhost:$P"; 'X-Session' = $srv.Token }
        Assert-True ($r.Status -in 400, 403) "Host localhost refusé ($($r.Status))"
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ Origin = 'http://evil.example.com'; 'X-Session' = $srv.Token }).Status -eq 403) 'Origin étrangère : 403'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/status' -Headers @{ Origin = "http://127.0.0.1:$P"; 'X-Session' = $srv.Token }).Status -eq 200) 'Origin correcte : 200'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/' -Headers @{ 'Sec-Fetch-Site' = 'cross-site' }).Status -eq 403) 'Sec-Fetch-Site cross-site : 403'

        foreach ($badPath in '/static/../src/Config.ps1', '/static/..%2f..%2fsrc/Config.ps1', '/static/%2e%2e/src/Config.ps1', '/static/js/../../Start-IntuneAssignLens.ps1',
            '/src/Config.ps1', '/static/..\src\Config.ps1', '/static//js/m1.js', '/static/js/app.js%00.txt', '/static/C:/Windows/win.ini', '/../../Windows/win.ini') {
            $r = Invoke-RawHttp -Port $P -Path $badPath
            Assert-True ($r.Status -ge 400 -and $r.Status -lt 500 -and $r.Body -notmatch 'IalConfig|\[fonts\]') "Traversée refusée : $badPath ($($r.Status))"
        }
        Assert-True ((Invoke-RawHttp -Port $P -Path '/static/js/app.js').Status -eq 200) 'Fichier de la liste blanche servi'
        $vendorLeaks = @($srv.Whitelist.Keys | Where-Object { $_ -like '/static/vendor/*' })
        Assert-True ($vendorLeaks.Count -eq 0) "vendor/ : jamais servi (rendu 100 % CSS) ($($vendorLeaks.Count) fichier(s))"
        Assert-True ((Invoke-RawHttp -Port $P -Path '/static/vendor/liquidglass-main/site/index.html').Status -eq 404) 'Démo / sources de la librairie jamais servies'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/static/js/APP.JS').Status -eq 404) 'Liste blanche sensible à la casse'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'PUT' -Path '/static/js/app.js').Status -eq 405) 'PUT sur fichier statique : 405'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'DELETE' -Path '/api/status' -Headers $tok).Status -eq 405) 'DELETE /api/status : 405'

        $r = Invoke-RawHttp -Port $P -Path "/api/search?kind=group&q=$([uri]::EscapeDataString('référence'))" -Headers $tok
        $sr = $r.Body | ConvertFrom-Json
        Assert-True ($r.Status -eq 200 -and @($sr.results | Where-Object id -EQ $expected.referenceGroup.id).Count -eq 1) '/api/search : groupe de référence trouvé'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/search?kind=bad&q=x' -Headers $tok).Status -eq 400) '/api/search kind invalide : 400'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/search?limit=-1&q=x' -Headers $tok).Status -eq 400) '/api/search limit invalide : 400'
        $r = Invoke-RawHttp -Port $P -Path "/api/group/$($expected.referenceGroup.id)" -Headers $tok
        Assert-True ($r.Status -eq 200 -and ($r.Body | ConvertFrom-Json).total -eq 26) '/api/group/{référence} : 26 éléments'
        $r = Invoke-RawHttp -Port $P -Path "/api/group/$($expected.xssGroup.id)" -Headers $tok
        Assert-True ($r.Status -eq 200 -and $r.Body -notmatch '<script>') 'Nom de groupe hostile échappé dans le JSON'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/group/abc%20def' -Headers $tok).Status -in 400, 404) '/api/group id invalide refusé'
        Assert-True ((Invoke-RawHttp -Port $P -Path "/api/object/$($expected.unassignedObject.id)" -Headers $tok).Status -eq 200) '/api/object/{id} : 200'

        Assert-True ($script:State.SrvCallLog.Count -eq $callsBefore -and $callsBefore -eq 0) 'Routes de lecture : aucun appel à Graph (réponses depuis l''index en mémoire)'
        $r = Invoke-RawHttp -Port $P -Path "/api/search?kind=user&q=$([uri]::EscapeDataString('camille démo'))" -Headers $tok
        Assert-True ($r.Status -eq 200 -and @(($r.Body | ConvertFrom-Json).results | Where-Object id -EQ $expected.demoUser.id).Count -eq 1) '/api/search kind=user : utilisateur de démonstration trouvé'
        $r = Invoke-RawHttp -Port $P -Path "/api/user/$($expected.demoUser.id)" -Headers $tok
        $uj = $r.Body | ConvertFrom-Json
        Assert-True ($r.Status -eq 200 -and @($uj.devices).Count -eq 2 -and @($uj.groups).Count -eq $expected.demoUser.groupCount) '/api/user/{id} : appareils et groupes'
        $r = Invoke-RawHttp -Port $P -Path "/api/device/$($expected.demoUser.deviceIds[0])" -Headers $tok
        Assert-True ($r.Status -eq 200 -and ($r.Body | ConvertFrom-Json).user.id -eq $expected.demoUser.id) '/api/device/{id} : utilisateur principal'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/api/user/inconnu' -Headers $tok).Status -eq 404) '/api/user inconnu : 404'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/refresh' -Body '{}').Status -eq 401) 'POST local sans jeton : 401'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/refresh' -Headers @{ 'X-Session' = $srv.Token; 'Content-Length' = '999999' }).Status -in 400, 413) 'Corps trop volumineux refusé'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/refresh' -Headers $tok -Body '{"mode":"drop"}').Status -eq 400) '/api/refresh mode invalide : 400'

        $r = Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/refresh' -Headers $tok -Body '{"mode":"incremental"}'
        Assert-True ($r.Status -eq 202) "/api/refresh : 202 synchronisation lancée ($($r.Status))"
        $r2 = Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/refresh' -Headers $tok -Body '{"mode":"full"}'
        Assert-True ($r2.Status -eq 409) "/api/refresh pendant une synchro : 409 ($($r2.Status))"
        $sawRunning = $false
        $sw1 = [System.Diagnostics.Stopwatch]::StartNew()
        do {
            $st = (Invoke-RawHttp -Port $P -Path '/api/status' -Headers $tok).Body | ConvertFrom-Json
            if ($st.syncRunning) { $sawRunning = $true }
            # Les lectures restent servies pendant la synchro
            if ($st.syncRunning) { $null = Invoke-RawHttp -Port $P -Path "/api/group/$($expected.referenceGroup.id)" -Headers $tok }
            Start-Sleep -Milliseconds 200
        } while ($st.syncRunning -and $sw1.Elapsed.TotalSeconds -lt 120)
        Assert-True ($sawRunning -and -not $st.syncRunning -and $st.phase -eq 'done') "Synchro lancée par l'API : terminée (phase $($st.phase))"
        Assert-True ($null -ne $st.lastSyncStats) 'Statistiques de synchro exposées dans /api/status'
        $r = Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/cache/clear' -Headers $tok -Body '{}'
        Assert-True ($r.Status -eq 200) '/api/cache/clear : 200'

        # Rapport CSP (M5) : accepté sans jeton, journalisé, compté, rien en retour
        $rep = '{"csp-report":{"document-uri":"http://127.0.0.1/","effective-directive":"img-src","blocked-uri":"data"}}'
        $r = Invoke-RawHttp -Port $P -Method 'POST' -Path '/csp-report' -Headers @{ 'Content-Type' = 'application/csp-report' } -Body $rep
        Assert-True ($r.Status -eq 204 -and -not $r.Body) '/csp-report : 204 sans contenu'
        Assert-True ((Invoke-RawHttp -Port $P -Path '/csp-report').Status -eq 405) '/csp-report en GET : 405'
        Assert-True ((Invoke-RawHttp -Port $P -Method 'POST' -Path '/csp-report' -Headers @{ Origin = 'http://evil.example.com' } -Body $rep).Status -eq 403) '/csp-report depuis une autre origine : 403'
        $st = (Invoke-RawHttp -Port $P -Path '/api/status' -Headers $tok).Body | ConvertFrom-Json
        Assert-True ($st.cspViolations -eq 1) "Violations CSP comptées dans /api/status ($($st.cspViolations))"
        $r = Invoke-RawHttp -Port $P -Path '/'
        Assert-True ($r.Headers['Permissions-Policy'] -match 'camera=\(\)' -and $r.Headers['Content-Security-Policy'] -match 'report-uri /csp-report') 'En-têtes Permissions-Policy et report-uri présents'

        $r = Invoke-RawHttp -Port $P -Method 'POST' -Path '/api/shutdown' -Headers $tok -Body '{}'
        Assert-True ($r.Status -eq 200) '/api/shutdown : 200'
        $null = Wait-Job $job -Timeout 10
        Assert-True ($job.State -eq 'Completed') 'Arrêt propre de la boucle serveur'
    }
    finally {
        $script:State.StopRequested = $true
        $null = Wait-Job $job -Timeout 5
        Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $job -Force
        Stop-IalServer -Server $srv
        $script:State.StopRequested = $false
    }
}

# =====================================================================================
if ('Static' -in $Section) {
    Start-Section 'Contrôles statiques (9.2)'
    $ps1 = Get-ChildItem -Path $root -Recurse -Include *.ps1 -File | Where-Object FullName -NotLike '*\web\vendor\*'
    foreach ($f in $ps1) {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
        Assert-True ($errs.Count -eq 0) "Syntaxe : $($f.FullName.Substring($root.Length + 1))"
    }
    # Le fichier de test contient ces motifs en tant que données : il est exclu de la recherche.
    $prod = $ps1 | Where-Object FullName -NotLike '*\tests\*'
    $patterns = 'Invoke-Expression', '\biex\b', '-EncodedCommand', 'FromBase64String', 'Add-Type', 'Invoke-WebRequest', 'Invoke-RestMethod',
    'Set-ExecutionPolicy', 'Start-Process', 'New-ScheduledTask', 'Register-ScheduledTask', '\breg(\.exe)?\s+add\b', '\bnetsh\b', 'ExecutionPolicy\s+Bypass', 'WindowStyle\s+Hidden',
    # Renforcement M5 : téléchargements, chargement dynamique, persistance, contournements, binaires détournables
    'DownloadString', 'DownloadFile', 'Net\.WebClient', 'Start-BitsTransfer', '\bbitsadmin\b', '\bcertutil\b', 'Reflection\.Assembly\]::Load',
    'Add-MpPreference', 'Set-MpPreference', 'New-Service', '\bschtasks\b', '\bmshta\b', '\brundll32\b', '\bregsvr32\b', 'New-ItemProperty', 'Set-ItemProperty\s+.*HK',
    'HKLM:|HKCU:|Registry::', 'ConvertTo-SecureString', 'Install-Module', 'Install-Package', '\bwinget(\.exe)?\s+(install|upgrade|source)','npm\s+install', 'Invoke-Command', 'Enter-PSSession', 'New-PSSession',
    'Get-Process', 'Stop-Process', 'Test-NetConnection', 'Resolve-DnsName', '-Verb\s+RunAs', 'AmsiUtils', 'amsiInitFailed'
    foreach ($pat in $patterns) {
        $hits = @($prod | Select-String -Pattern $pat | Where-Object { $_.Line -notmatch '^\s*#' })
        if ($pat -eq 'Install-Module') {
            # Seule exception : l'installeur (lancé une fois par l'utilisateur, avec son accord) installe le module
            # officiel Microsoft Graph pour son compte. L'outil lui-même n'installe jamais rien.
            $okInst = @($hits | Where-Object { $_.Path -like '*\setup\Install-IntuneLens.ps1' -and $_.Line -match 'Install-Module -Name Microsoft\.Graph\.Authentication -Scope CurrentUser -Repository PSGallery' })
            $calls = @($hits | Where-Object { $_.Line -notmatch '^\s*Write-Host ' })   # les messages affichés ne sont pas des appels
            Assert-True ($calls.Count -eq 1 -and $okInst.Count -eq 1) "Install-Module : uniquement dans l'installeur, Microsoft.Graph.Authentication pour l'utilisateur courant ($($hits.Count))"
        }
        elseif ($pat -eq 'Start-Process') {
            $ok = ($hits.Count -eq 1 -and $hits[0].Path -like '*Start-IntuneAssignLens.ps1' -and $hits[0].Line -match '\$edge')
            Assert-True $ok "Start-Process : une seule occurrence (ouverture d'Edge)"
        }
        else { Assert-True ($hits.Count -eq 0) "Motif interdit absent : $pat" }
    }
    $cmdSrc = Get-Content (Join-Path $root 'Installer.cmd') -Raw
    Assert-True ($cmdSrc -notmatch '(?i)bypass|-EncodedCommand|WindowStyle|\breg(\.exe)?\s|schtasks|powershell\.exe|curl|bitsadmin|certutil' -and $cmdSrc -match 'Unblock-File' -and $cmdSrc -match "\r\n") 'Installer.cmd : aucun contournement ni téléchargement direct, fins de ligne Windows'
    $instSrc = Get-Content (Join-Path $root 'setup\Install-IntuneLens.ps1') -Raw
    Assert-True ($instSrc -notmatch 'HKLM|HKCU|Registry::|ScheduledTask|New-Service|RunAs' -and $instSrc -match "Scope CurrentUser") 'Installeur : pas de registre, de tâche, de service ni d''élévation'
    $mg = @($prod | Select-String -Pattern 'Invoke-MgGraphRequest|Connect-MgGraph' | Where-Object { $_.Line -notmatch '^\s*#' })
    Assert-True (@($mg | Where-Object { $_.Path -notlike '*\src\GraphClient.ps1' }).Count -eq 0) 'Graph appelé uniquement depuis GraphClient.ps1'
    $posts = @($prod | Select-String -Pattern '-Method\s+POST' | Where-Object { $_.Line -notmatch '^\s*#' })
    Assert-True ($posts.Count -eq 1 -and $posts[0].Line -match 'batchUri') 'Un seul POST vers Graph : le $batch'

    # Aucun jeton dans le journal : aucune ligne de journal ne référence le jeton de session ou l'URL qui le contient
    $logLeaks = @($prod | Select-String -Pattern 'Write-IalLog' | Where-Object { $_.Line -match 'Token|\$url\b|#s=|AccessToken|Bearer' })
    Assert-True ($logLeaks.Count -eq 0) "Journal : aucune référence au jeton ($($logLeaks.Count))"
    $urlPrints = @($prod | Select-String -Pattern '#s=' | Where-Object { $_.Line -notmatch '^\s*#' })
    Assert-True (@($urlPrints | Where-Object { $_.Line -notmatch '\$url = ' }).Count -eq 0) 'L''URL avec jeton n''est construite qu''à un endroit (affichée à la console seulement avec -NoBrowser)'

    # Écritures disque : seuls Log.ps1 et Cache.ps1 écrivent (dans %LOCALAPPDATA%\IntuneAssignLens)
    $srcFiles = Get-ChildItem (Join-Path $root 'src') -Filter *.ps1
    $writers = @($srcFiles | Select-String -Pattern 'Set-Content|Out-File|Add-Content|WriteAllText|WriteAllBytes|FileStream\]::new|New-Item|Remove-Item|Set-Acl|SetAccessControl|File\]::Move|Copy-Item|Move-Item' |
        Where-Object { $_.Line -notmatch '^\s*#' })
    $badWriters = @($writers | Where-Object { $_.Filename -notin 'Log.ps1', 'Cache.ps1' })
    Assert-True ($badWriters.Count -eq 0) "Écritures disque limitées à Log.ps1 et Cache.ps1 ($(($badWriters | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', '))"
    # Code seulement (commentaires exclus)
    $codeOnly = { param($p) (Get-Content $p | Where-Object { $_ -notmatch '^\s*#' }) -join "`n" }
    $cacheSrc = & $codeOnly (Join-Path $root 'src\Cache.ps1')
    Assert-True ($cacheSrc -match 'LOCALAPPDATA' -and $cacheSrc -notmatch 'MyDocuments|Desktop|OneDrive|USERPROFILE') 'Cache : %LOCALAPPDATA% uniquement (jamais Documents, Bureau, OneDrive)'
    $startSrc = & $codeOnly (Join-Path $root 'Start-IntuneAssignLens.ps1')
    Assert-True ($startSrc -match "Join-Path \`$env:LOCALAPPDATA" -and $startSrc -notmatch 'MyDocuments|Desktop|OneDrive') 'Point d''entrée : données sous %LOCALAPPDATA% uniquement'

    # Point d'entrée lisible par PowerShell 5.1 (message de refus accentué) : UTF-8 avec BOM
    $entryBytes = [System.IO.File]::ReadAllBytes((Join-Path $root 'Start-IntuneAssignLens.ps1'))
    Assert-True ($entryBytes[0] -eq 0xEF -and $entryBytes[1] -eq 0xBB -and $entryBytes[2] -eq 0xBF) 'Point d''entrée en UTF-8 avec BOM (message correct sous PowerShell 5.1)'

    # CSP : aucun assouplissement accordé
    $srvSrc = Get-Content (Join-Path $root 'src\Server.ps1') -Raw
    $csp = ([regex]::Match($srvSrc, '\$script:IalCsp = "([^"]+)"')).Groups[1].Value
    Assert-True ($csp -like "default-src 'none'*" -and $csp -notmatch "unsafe-inline|unsafe-eval|data:|blob:|\*|https?:") "CSP sans aucun assouplissement : $csp"
    $vendorJs = Join-Path $root 'web\vendor\liquidglass\index.js'
    if (Test-Path $vendorJs) {
        $sums = Get-Content (Join-Path $root 'web\vendor\liquidglass\SHA256SUMS.txt') -TotalCount 1
        Assert-True ($sums -match (Get-FileHash $vendorJs -Algorithm SHA256).Hash) 'Librairie de verre : empreinte SHA256 conforme à SHA256SUMS.txt'
        $lib = Get-Content $vendorJs -Raw
        $libUrls = @([regex]::Matches($lib, 'https?://[^\s"''`)]+') | ForEach-Object Value | Where-Object { $_ -notmatch '^http://www\.w3\.org/|^https://developer\.mozilla\.org/' })
        Assert-True ($libUrls.Count -eq 0 -and $lib -notmatch '\beval\(|new Function\(|WebSocket|sendBeacon|localStorage|document\.cookie') "Librairie de verre : aucune URL externe ni code dynamique ($($libUrls -join ', '))"
    }
    Assert-True ($srvSrc -match "ListenAddress" -and (Get-Content (Join-Path $root 'src\Config.ps1') -Raw) -match "ListenAddress\s+=\s+'127\.0\.0\.1'") 'Écoute configurée sur 127.0.0.1 uniquement'
    Assert-True ($srvSrc -notmatch "http://\+|http://\*|0\.0\.0\.0") 'Aucun préfixe d''écoute générique (+, *, 0.0.0.0)'

    $webFiles = Get-ChildItem -Path (Join-Path $root 'web') -Recurse -File | Where-Object FullName -NotLike '*\vendor\*'
    # L'espace de noms SVG (http://www.w3.org/2000/svg) est un identifiant, pas une ressource : seule exception.
    $ext = @($webFiles | Select-String -Pattern 'https?://|//cdn|fonts\.googleapis|jsdelivr|unpkg|sendBeacon|WebSocket|XMLHttpRequest|EventSource' |
            Where-Object { ($_.Line -replace 'http://www\.w3\.org/2000/svg', '') -match 'https?://|//cdn|fonts\.googleapis|jsdelivr|unpkg|sendBeacon|WebSocket|XMLHttpRequest|EventSource' })
    Assert-True ($ext.Count -eq 0) "web/ : aucune URL externe ni API réseau tierce ($($ext.Count))"
    $fetches = @($webFiles | Where-Object Extension -EQ '.js' | Select-String -Pattern 'fetch\(' )
    Assert-True (@($fetches | Where-Object { $_.Path -notlike '*\js\api.js' }).Count -eq 0) 'fetch() utilisé uniquement dans api.js (chemins relatifs)'
    $danger = @($webFiles | Where-Object Extension -EQ '.js' | Select-String -Pattern '\binnerHTML\b|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function\(|setTimeout\(\s*[''"]')
    Assert-True ($danger.Count -eq 0) "JS : aucun HTML injecté ni code dynamique ($($danger.Count))"
    $html = Get-Content (Join-Path $root 'web\index.html') -Raw
    Assert-True ($html -notmatch '\sstyle\s*=' -and $html -notmatch '<style' -and $html -notmatch '\son[a-z]+\s*=' -and $html -notmatch '<script(?![^>]*\ssrc=)') 'index.html : aucun script, style ni gestionnaire en ligne (CSP stricte)'
    $refs = [regex]::Matches($html, '(?:href|src)="(/static/[^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $missing = @($refs | Where-Object { -not (Test-Path (Join-Path $root ('web' + ($_ -replace '^/static', '') -replace '/', '\'))) })
    Assert-True ($refs.Count -gt 0 -and $missing.Count -eq 0) "index.html : toutes les ressources référencées existent ($($missing -join ', '))"

    if (Get-Command node -ErrorAction SilentlyContinue) {
        $bad = @(Get-ChildItem (Join-Path $root 'web\js') -Recurse -Filter *.js | Where-Object { node --check $_.FullName 2>$null; $LASTEXITCODE -ne 0 })
        Assert-True ($bad.Count -eq 0) "JS : syntaxe valide (node --check) $(($bad | ForEach-Object Name) -join ', ')"
        $out = node --test (Join-Path $root 'tests\web\model.test.mjs') (Join-Path $root 'tests\web\chrome.test.mjs') (Join-Path $root 'tests\web\compare.test.mjs') (Join-Path $root 'tests\web\profile.test.mjs') (Join-Path $root 'tests\web\link.test.mjs') 2>&1 | Out-String
        Assert-True ($LASTEXITCODE -eq 0) "Logique de l'interface : tests Node ($(([regex]::Match($out, 'pass (\d+)')).Groups[1].Value) réussis)"
    }
    else { Write-Host '  [INFO] Node absent : contrôles JS ignorés.' -ForegroundColor Yellow }
}

# =====================================================================================
Remove-Item -LiteralPath $script:TestCacheDir -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
if ($script:Fail.Count -eq 0) {
    Write-Host "RÉSULTAT : $($script:Pass) tests réussis, 0 échec." -ForegroundColor Green
    exit 0
}
Write-Host "RÉSULTAT : $($script:Pass) réussis, $($script:Fail.Count) échec(s) :" -ForegroundColor Red
$script:Fail | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
exit 1
