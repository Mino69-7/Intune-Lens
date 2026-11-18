# Collectors.ps1 : lecture des objets Intune, des groupes et des filtres via GraphClient.
# Deux temps par type : (1) liste légère, (2) assignations en lots $batch de 20.
# Aucun appel direct au réseau ici : tout passe par Invoke-GraphRead / Invoke-GraphList / Invoke-GraphBatch.

Set-StrictMode -Version 3.0

function Get-IalGraphBase {
    param([ValidateSet('v1.0', 'beta')][string]$Version)
    if ($Version -eq 'v1.0') { $script:IalConfig.GraphBaseV1 } else { $script:IalConfig.GraphBaseBeta }
}

function Get-IalPlatformLabel {
    param([string]$OdataType, [string]$Platforms)
    if ($Platforms) {
        switch -Regex ($Platforms) {
            'windows' { return 'Windows' }
            'macos' { return 'macOS' }
            'ios' { return 'iOS' }
            'android' { return 'Android' }
            'linux' { return 'Linux' }
        }
    }
    $t = ($OdataType -replace '^#microsoft\.graph\.', '')
    switch -Regex ($t) {
        '^(windows|win32|winGet|officeSuite|microsoftStore|windowsUniversal|windowsHealth)' { return 'Windows' }
        '^ios' { return 'iOS' }
        '^android' { return 'Android' }
        '^macOS' { return 'macOS' }
        '^webApp' { return 'Web' }
    }
    return ''
}

function ConvertTo-IalIsoDate {
    <#
        Normalise une date en ISO 8601 UTC (« 2024-02-18T07:17:25Z »).
        ConvertFrom-Json (et possiblement le module Graph) convertit les chaînes ISO en [datetime],
        dont la conversion en texte dépend de la culture et perd le fuseau.
    #>
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return '' }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture) }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture) }
    $d = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) {
        return $d.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [cultureinfo]::InvariantCulture)
    }
    return [string]$Value
}

function ConvertTo-IalAssignment {
    <# Normalise une assignation Graph vers le modèle interne (spec 5.5). Retourne $null si cible inconnue. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Raw)
    $t = $Raw['target']
    if (-not ($t -is [System.Collections.IDictionary])) { return $null }
    # La doc montre le type avec ou sans « # » : on normalise (« groupAssignmentTarget »).
    $kind = ([string]$t['@odata.type']) -replace '^#?microsoft\.graph\.', ''
    $a = [ordered]@{ target = $null; groupId = $null; mode = 'include'; intent = $null; filterId = $null; filterMode = $null; source = $null; rawType = $null }
    switch ($kind) {
        'groupAssignmentTarget' { $a.target = 'group'; $a.groupId = [string]$t['groupId'] }
        'exclusionGroupAssignmentTarget' { $a.target = 'group'; $a.groupId = [string]$t['groupId']; $a.mode = 'exclude' }
        'allLicensedUsersAssignmentTarget' { $a.target = 'allLicensedUsers' }
        'allDevicesAssignmentTarget' { $a.target = 'allDevices' }
        'allUsersAssignmentTarget' { $a.target = 'allUsers' }   # non documenté (V9) : accepté par prudence
        'scopeTagGroupAssignmentTarget' {
            # Cible récente de la doc v1.0 : objet Entra (entraObjectId) visé via une balise d'étendue.
            # Traité comme un groupe en inclusion ; à confirmer sur le tenant (V18).
            $a.target = 'group'; $a.groupId = [string]$t['entraObjectId']; $a.source = 'scopeTag'
        }
        default {
            # Cible non prise en charge (ex. collection Configuration Manager) : CONSERVÉE pour rester
            # visible sur l'écran Élément → groupes, au lieu d'être ignorée silencieusement.
            $a.target = 'other'; $a.rawType = $(if ($kind) { $kind } else { 'inconnu' })
        }
    }
    if ($a.target -eq 'group' -and -not $a.groupId) { $a.target = 'other'; $a.rawType = $kind }
    if ($t.Contains('deviceAndAppManagementAssignmentFilterId') -and $t['deviceAndAppManagementAssignmentFilterId']) {
        $fm = [string]$t['deviceAndAppManagementAssignmentFilterType']
        if ($fm -and $fm -ne 'none') {
            $a.filterId = [string]$t['deviceAndAppManagementAssignmentFilterId']
            $a.filterMode = $fm
        }
    }
    if ($Raw.Contains('intent') -and $Raw['intent']) { $a.intent = [string]$Raw['intent'] }
    return $a
}

function Get-IalGroups {
    [CmdletBinding()]
    param()
    $uri = '{0}/{1}?$select=id,displayName&$top={2}' -f $script:IalConfig.GraphBaseV1, $script:IalGroupsPath, $script:IalConfig.GroupPageSize
    $raw = Invoke-GraphList -Uri $uri
    $out = [System.Collections.Generic.List[object]]::new($raw.Count)
    foreach ($g in $raw) { $out.Add([ordered]@{ id = [string]$g['id']; displayName = [string]$g['displayName'] }) }
    return , $out
}

function Get-IalFilters {
    [CmdletBinding()]
    param()
    $ft = $script:IalFiltersType
    $uri = '{0}/{1}?$select={2}' -f (Get-IalGraphBase $ft.Version), $ft.Path, $ft.Select
    $res = @{}
    foreach ($f in (Invoke-GraphList -Uri $uri)) {
        $res[[string]$f['id']] = [ordered]@{ id = [string]$f['id']; name = [string]$f['displayName']; platform = [string]$f['platform'] }
    }
    return $res
}

function Get-IalObjectList {
    <# Liste légère d'un type : id, nom, lastModified, type OData, plateforme. Sans assignations. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Type)
    $base = Get-IalGraphBase $Type.Version
    $uri = '{0}/{1}?$select={2}' -f $base, $Type.Path, $Type.Select
    try { $raw = Invoke-GraphList -Uri $uri }
    catch {
        # Si Graph refuse le $select (HTTP 400), repli sur le strict minimum : jamais de liste sans $select
        # (certaines ressources renvoient sinon le contenu des scripts).
        if ([int]$_.Exception.Data['IalStatus'] -ne 400) { throw }
        $minimal = 'id,{0},lastModifiedDateTime' -f $Type.NameProp
        if ($minimal -eq $Type.Select) { throw }
        Write-IalLog -Level WARN -Message "Type $($Type.Key) : `$select refusé (400), repli sur « $minimal »."
        $raw = Invoke-GraphList -Uri ('{0}/{1}?$select={2}' -f $base, $Type.Path, $minimal)
    }
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($r in $raw) {
        $odata = [string]$r['@odata.type']
        $plats = if ($r.Contains('platforms')) { [string]$r['platforms'] } else { '' }
        $family = $Type.Family
        # Catalogue de paramètres : les stratégies de sécurité et les bases de référence y vivent aussi.
        if ($r.Contains('templateReference') -and $r['templateReference'] -is [System.Collections.IDictionary]) {
            $tf = [string]$r['templateReference']['templateFamily']
            if ($tf -like 'endpointSecurity*') { $family = 'Sécurité des points de terminaison' }
            elseif ($tf -eq 'baseline') { $family = 'Bases de référence de sécurité' }
        }
        $out.Add([ordered]@{
                id           = [string]$r['id']
                typeKey      = $Type.Key
                family       = $family
                name         = [string]$r[$Type.NameProp]
                odataType    = $odata
                platform     = (Get-IalPlatformLabel -OdataType $odata -Platforms $plats)
                lastModified = (ConvertTo-IalIsoDate $r['lastModifiedDateTime'])
                assignments  = $null
            })
    }
    return , $out
}

function Get-IalAssignments {
    <#
        Lit les assignations d'une liste d'objets d'un même type, par lots de 20.
        Retourne hashtable objectId -> liste d'assignations normalisées ($null si échec de lecture).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Type,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ObjectIds,
        [scriptblock]$OnProgress
    )
    $result = @{}
    if ($ObjectIds.Count -eq 0) { return $result }
    $size = $script:IalConfig.BatchSize
    for ($i = 0; $i -lt $ObjectIds.Count; $i += $size) {
        $chunk = $ObjectIds[$i..([math]::Min($i + $size, $ObjectIds.Count) - 1)]
        $reqs = foreach ($id in $chunk) { @{ id = $id; url = "/$($Type.Path)/$([System.Uri]::EscapeDataString($id))/assignments" } }
        $resp = Invoke-GraphBatch -Requests @($reqs) -Version $Type.Version
        foreach ($id in $chunk) {
            $r = $resp[$id]
            if (-not $r -or $r.status -lt 200 -or $r.status -ge 300) {
                $st = if ($r) { $r.status } else { 0 }
                Write-IalLog -Level WARN -Message "Assignations illisibles pour un objet de type $($Type.Key) (HTTP $st)."
                $result[$id] = $null
                continue
            }
            $raw = [System.Collections.Generic.List[object]]::new()
            if ($r.body -and $r.body.Contains('value')) { foreach ($v in @($r.body['value'])) { if ($null -ne $v) { $raw.Add($v) } } }
            if ($r.body -and $r.body.Contains('@odata.nextLink') -and $r.body['@odata.nextLink']) {
                foreach ($v in (Invoke-GraphList -Uri ([string]$r.body['@odata.nextLink']))) { $raw.Add($v) }
            }
            $norm = [System.Collections.Generic.List[object]]::new()
            foreach ($a in $raw) {
                $n = ConvertTo-IalAssignment -Raw $a
                if ($n) { $norm.Add($n) }
            }
            $result[$id] = $norm
        }
        if ($OnProgress) { & $OnProgress $chunk.Count }
    }
    return $result
}

#region Appareils et appartenances (fiches Utilisateur / Machine) ---------------

function Get-IalDevicePlatform {
    <# Plateforme d'un appareil géré, alignée sur Get-IalPlatformLabel (Windows, macOS, iOS, Android, Linux). #>
    param([string]$OperatingSystem)
    switch -Regex ($OperatingSystem) {
        '^windows' { return 'Windows' }
        '^(macos|mac os|osx)' { return 'macOS' }
        '^(ios|ipados)' { return 'iOS' }
        '^android' { return 'Android' }
        '^linux' { return 'Linux' }
    }
    return ''
}

function ConvertTo-IalDevice {
    <# Normalise un managedDevice Graph vers le modèle interne. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Raw)
    $get = { param($k) if ($Raw.Contains($k) -and $null -ne $Raw[$k]) { [string]$Raw[$k] } else { '' } }
    $aad = & $get 'azureADDeviceId'
    if ($aad -match '^0{8}-0{4}-0{4}-0{4}-0{12}$') { $aad = '' }   # appareil non joint à Entra
    $os = & $get 'operatingSystem'
    [ordered]@{
        id         = & $get 'id'
        name       = & $get 'deviceName'
        userId     = & $get 'userId'
        upn        = & $get 'userPrincipalName'
        userName   = & $get 'userDisplayName'
        aadId      = $aad
        os         = $os
        platform   = (Get-IalDevicePlatform $os)
        osVersion  = & $get 'osVersion'
        model      = & $get 'model'
        maker      = & $get 'manufacturer'
        serial     = & $get 'serialNumber'
        lastSync   = (ConvertTo-IalIsoDate $Raw['lastSyncDateTime'])
        compliance = & $get 'complianceState'
        owner      = & $get 'managedDeviceOwnerType'
    }
}

function Get-IalManagedDevices {
    <# Liste légère des appareils gérés (avec repli sans $select si Graph le refuse). #>
    [CmdletBinding()]
    param()
    $t = $script:IalDevicesType
    $base = Get-IalGraphBase $t.Version
    try { $raw = Invoke-GraphList -Uri ('{0}/{1}?$select={2}' -f $base, $t.Path, $t.Select) }
    catch {
        if ([int]$_.Exception.Data['IalStatus'] -ne 400) { throw }
        Write-IalLog -Level WARN -Message 'Appareils : $select refusé (400), lecture sans $select.'
        $raw = Invoke-GraphList -Uri ('{0}/{1}' -f $base, $t.Path)
    }
    $out = [System.Collections.Generic.List[object]]::new($raw.Count)
    foreach ($r in $raw) { $d = ConvertTo-IalDevice -Raw $r; if ($d.id) { $out.Add($d) } }
    return , $out
}

function Get-IalMemberships {
    <#
        Lit À LA DEMANDE les groupes (transitifs) d'un utilisateur et de ses appareils Entra, en UN $batch de GET.
          utilisateur : GET /users/{id}/transitiveMemberOf          (Group.Read.All, déjà consenti)
          appareil    : GET /devices(deviceId='{id}')/transitiveMemberOf   (Device.Read.All)
        Seuls les objets « group » sont gardés (pas les rôles ni les unités administratives).
        .PARAMETER UserId     identifiant Entra de l'utilisateur (ou vide)
        .PARAMETER DeviceIds  azureADDeviceId des appareils (19 au plus : un $batch = 20 sous-requêtes)
        .OUTPUTS @{ user = @{ ok; groups = @(@{id;name}); reason }; devices = @{ aadId -> @{ ok; groups; reason } } }
    #>
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$UserId,
        [AllowEmptyCollection()][string[]]$DeviceIds = @(),
        [AllowEmptyCollection()][string[]]$TokenScopes = @()
    )
    $sel = '?$select=id,displayName&$top=999'
    $reqs = [System.Collections.Generic.List[object]]::new()
    if ($UserId) { $reqs.Add(@{ id = 'u'; url = "/users/$([System.Uri]::EscapeDataString($UserId))/transitiveMemberOf$sel" }) }
    $canDevices = $script:IalGraph.Mode -eq 'Mock' -or $script:IalConfig.DeviceScope -in $TokenScopes
    $devIds = @($DeviceIds | Where-Object { $_ } | Select-Object -Unique -First 19)
    $out = @{ user = $null; devices = @{} }
    $i = 0
    foreach ($d in $devIds) {
        if (-not $canDevices) {
            $out.devices[$d] = @{ ok = $false; groups = @(); reason = "Permission $($script:IalConfig.DeviceScope) non accordée : groupes de la machine indisponibles." }
            continue
        }
        $reqs.Add(@{ id = "d$i"; url = "/devices(deviceId='$($d -replace "'", "''")')/transitiveMemberOf$sel"; aad = $d })
        $i++
    }
    $resp = if ($reqs.Count) { Invoke-GraphBatch -Requests @($reqs) -Version 'v1.0' } else { @{} }

    $read = {
        param($r, [string]$what, [string]$url)
        $vals = [System.Collections.Generic.List[object]]::new()
        if ($r -and $r.status -eq 400 -and $url) {
            # $select / $top refusés (requête avancée exigée) : relecture simple, sans paramètre.
            try {
                foreach ($v in (Invoke-GraphList -Uri ($script:IalConfig.GraphBaseV1 + $url.Replace($sel, '')))) { $vals.Add($v) }
                $r = @{ status = 200; body = $null }
            }
            catch { $r = @{ status = [int]$_.Exception.Data['IalStatus']; body = $null } }
        }
        if (-not $r -or $r.status -lt 200 -or $r.status -ge 300) {
            $st = if ($r) { [int]$r.status } else { 0 }
            $reason = switch ($st) {
                403 { if ($what -eq 'device') { "Accès refusé (403) : la permission $($script:IalConfig.DeviceScope) est nécessaire pour les groupes des machines." } else { 'Accès refusé (403) aux groupes de cet utilisateur.' } }
                404 { if ($what -eq 'device') { 'Appareil introuvable dans Entra (404).' } else { 'Utilisateur introuvable dans Entra (404).' } }
                default { "Lecture impossible (HTTP $st)." }
            }
            return @{ ok = $false; groups = @(); reason = $reason }
        }
        if ($r.body -and $r.body.Contains('value')) { foreach ($v in @($r.body['value'])) { if ($null -ne $v) { $vals.Add($v) } } }
        if ($r.body -and $r.body.Contains('@odata.nextLink') -and $r.body['@odata.nextLink']) {
            foreach ($v in (Invoke-GraphList -Uri ([string]$r.body['@odata.nextLink']))) { $vals.Add($v) }
        }
        $groups = [System.Collections.Generic.List[object]]::new()
        foreach ($v in $vals) {
            $t = [string]$v['@odata.type']
            if ($t -and $t -notmatch 'group$') { continue }   # rôles d'annuaire, unités administratives
            $groups.Add(@{ id = [string]$v['id']; name = [string]$v['displayName'] })
        }
        return @{ ok = $true; groups = $groups.ToArray(); reason = '' }
    }
    foreach ($r in $reqs) {
        if ($r.id -eq 'u') { $out.user = & $read $resp['u'] 'user' $r.url }
        else { $out.devices[$r.aad] = & $read $resp[$r.id] 'device' $r.url }
    }
    return $out
}

#endregion
