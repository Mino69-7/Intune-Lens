# Index.ps1 : modèle de données en mémoire, index inversé et recherche.
# Un index est IMMUABLE une fois construit : la synchronisation en construit un nouveau puis échange la référence.

Set-StrictMode -Version 3.0

$script:IalViaLabels = @{
    group            = 'Groupe direct'
    allUsers         = 'Tous les utilisateurs'
    allLicensedUsers = 'Tous les utilisateurs'
    allDevices       = 'Tous les appareils'
}

function Get-IalViaLabel {
    <# Libellé « Via » d'une assignation normalisée. #>
    param($Assignment)
    switch ($Assignment.target) {
        'group' { if ($Assignment.source -eq 'scopeTag') { return 'Groupe (balise d''étendue)' } return 'Groupe direct' }
        'other' { return "Cible non prise en charge ($($Assignment.rawType))" }
        default { return $script:IalViaLabels[[string]$Assignment.target] }
    }
}

function ConvertTo-IalSearchKey {
    <# Minuscules, sans accents (é -> e, œ -> oe). Sert à la recherche insensible à la casse et aux accents. #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $d = $Text.ToLowerInvariant().Replace('œ', 'oe').Replace('æ', 'ae').Replace('ß', 'ss').Normalize([System.Text.NormalizationForm]::FormD)
    return $script:IalMarkRegex.Replace($d, '')
}

# Marques diacritiques (accents) après décomposition Unicode.
$script:IalMarkRegex = [regex]::new('\p{Mn}+')

function ConvertTo-IalSearchKeys {
    <#
        Version groupée : normalise des milliers de noms en un seul passage natif
        (au lieu d'un appel de fonction par nom). Même règle que ConvertTo-IalSearchKey.
    #>
    param([AllowEmptyCollection()][string[]]$Texts)
    if ($Texts.Count -eq 0) { return , ([string[]]@()) }
    $clean = [string[]]::new($Texts.Count)
    for ($i = 0; $i -lt $Texts.Count; $i++) { $clean[$i] = if ($null -eq $Texts[$i]) { '' } else { $Texts[$i].Replace("`n", ' ').Replace("`r", ' ') } }
    $all = [string]::Join("`n", $clean)
    $d = $all.ToLowerInvariant().Replace('œ', 'oe').Replace('æ', 'ae').Replace('ß', 'ss').Normalize([System.Text.NormalizationForm]::FormD)
    $keys = $script:IalMarkRegex.Replace($d, '').Split("`n")
    if ($keys.Count -ne $Texts.Count) { throw 'Normalisation des clés de recherche incohérente.' }
    return , $keys
}

function New-IalIndex {
    <#
        .PARAMETER Data
        @{ Groups = liste @{id;displayName}; Filters = @{id -> @{name;platform}}; Objects = liste d'objets normalisés;
           Uncovered = liste; SyncedAt = date ISO; Mode = 'Real'|'Mock' }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Data)

    $groupCount = $Data.Groups.Count
    $gIds = [string[]]::new($groupCount)
    $gNames = [string[]]::new($groupCount)
    $gKeys = [string[]]::new($groupCount)
    $gById = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $i = 0
    foreach ($g in $Data.Groups) {
        $gIds[$i] = $g.id; $gNames[$i] = $g.displayName
        $gById[$g.id] = $g.displayName
        $i++
    }
    $gKeys = ConvertTo-IalSearchKeys -Texts $gNames

    $objById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $byGroup = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $global = [System.Collections.Generic.List[object]]::new()
    $oIds = [System.Collections.Generic.List[string]]::new()
    $oNames = [System.Collections.Generic.List[string]]::new()
    $assignmentCount = 0
    $unassigned = 0
    $otherTargets = 0

    foreach ($o in $Data.Objects) {
        $objById[$o.id] = $o
        $oIds.Add($o.id)
        $oNames.Add([string]$o.name)
        $n = 0
        foreach ($a in $o.assignments) {
            if ($null -eq $a) { continue }
            $n++
            $assignmentCount++
            $entry = [pscustomobject]@{ ObjectId = $o.id; Assignment = $a }
            if ($a.target -eq 'group') {
                $list = $null
                if (-not $byGroup.TryGetValue($a.groupId, [ref]$list)) {
                    $list = [System.Collections.Generic.List[object]]::new()
                    $byGroup[$a.groupId] = $list
                }
                $list.Add($entry)
            }
            elseif ($a.target -in 'allUsers', 'allLicensedUsers', 'allDevices') {
                $global.Add($entry)
            }
            else {
                $otherTargets++    # cible non prise en charge : visible seulement sur l'écran de l'élément
            }
        }
        if ($n -eq 0) { $unassigned++ }
    }

    $deletedRefs = 0
    foreach ($gid in $byGroup.Keys) { if (-not $gById.ContainsKey($gid)) { $deletedRefs++ } }
    $oKeysArr = ConvertTo-IalSearchKeys -Texts $oNames.ToArray()

    # Appareils gérés et utilisateurs (déduits des appareils : utilisateur principal de chaque appareil).
    $devById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $userById = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $dIds = [System.Collections.Generic.List[string]]::new()
    $dTexts = [System.Collections.Generic.List[string]]::new()
    $devList = if ($Data.Contains('Devices') -and $Data.Devices) { @($Data.Devices) } else { @() }
    foreach ($d in $devList) {
        if ($null -eq $d -or -not $d['id']) { continue }
        $devById[[string]$d['id']] = $d
        $dIds.Add([string]$d['id'])
        $dTexts.Add(('{0} {1}' -f $d['name'], $d['serial']))
        $uid = [string]$d['userId']
        if ($uid) {
            $u = $null
            if (-not $userById.TryGetValue($uid, [ref]$u)) {
                $nm = if ($d['userName']) { [string]$d['userName'] } elseif ($d['upn']) { [string]$d['upn'] } else { $uid }
                $u = [ordered]@{ id = $uid; name = $nm; upn = [string]$d['upn']; deviceIds = [System.Collections.Generic.List[string]]::new() }
                $userById[$uid] = $u
            }
            $u.deviceIds.Add([string]$d['id'])
        }
    }
    $uIds = [string[]]@($userById.Keys)
    # Recherche sur le nom et la partie locale de l'UPN (le domaine, commun à tous, est ignoré).
    $uTexts = [string[]]@(foreach ($k in $uIds) { '{0} {1}' -f $userById[$k].name, ([string]$userById[$k].upn).Split('@')[0] })
    $dKeysArr = ConvertTo-IalSearchKeys -Texts $dTexts.ToArray()
    $uKeysArr = ConvertTo-IalSearchKeys -Texts $uTexts

    return [pscustomobject]@{
        GroupIds        = $gIds
        GroupNames      = $gNames
        GroupKeys       = $gKeys
        GroupBlob       = (New-IalSearchBlob -Keys $gKeys)
        GroupById       = $gById
        ObjectIds       = $oIds.ToArray()
        ObjectKeys      = $oKeysArr
        ObjectBlob      = (New-IalSearchBlob -Keys $oKeysArr)
        ObjectById      = $objById
        ByGroup         = $byGroup
        Global          = $global
        DeviceIds       = $dIds.ToArray()
        DeviceKeys      = $dKeysArr
        DeviceBlob      = (New-IalSearchBlob -Keys $dKeysArr)
        DeviceById      = $devById
        UserIds         = $uIds
        UserKeys        = $uKeysArr
        UserBlob        = (New-IalSearchBlob -Keys $uKeysArr)
        UserById        = $userById
        Filters         = $(if ($Data.Contains('Filters') -and $Data.Filters) { $Data.Filters } else { @{} })
        Uncovered       = $(if ($Data.Contains('Uncovered') -and $Data.Uncovered) { @($Data.Uncovered) } else { @() })
        SyncedAt        = $(if ($Data.Contains('SyncedAt')) { $Data.SyncedAt } else { $null })
        Counts          = [ordered]@{
            groups             = $groupCount
            objects            = $objById.Count
            assignments        = $assignmentCount
            unassignedObjects  = $unassigned
            groupsWithItems    = $byGroup.Count
            deletedGroupRefs   = $deletedRefs
            otherTargets       = $otherTargets
            devices            = $devById.Count
            users              = $userById.Count
        }
    }
}

function New-IalSearchBlob {
    <#
        Concatène les clés de recherche dans une seule chaîne "\nclé0\nclé1\n...\n".
        La recherche se fait ensuite par String.IndexOf natif (rapide) au lieu d'une boucle PowerShell par clé.
    #>
    param([string[]]$Keys)
    $sb = [System.Text.StringBuilder]::new()
    $offsets = [int[]]::new($Keys.Length)
    $null = $sb.Append("`n")
    for ($i = 0; $i -lt $Keys.Length; $i++) {
        $offsets[$i] = $sb.Length
        $null = $sb.Append($Keys[$i].Replace("`n", ' ')).Append("`n")
    }
    return [pscustomobject]@{ Blob = $sb.ToString(); Offsets = $offsets }
}

function Search-IalIndex {
    <#
        Recherche par sous-chaîne, insensible à la casse et aux accents. Plusieurs mots = tous doivent figurer.
        Les résultats qui COMMENCENT par le premier mot sont classés en premier.
        total est plafonné (TotalCap) : au-delà, totalCapped = $true.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Index,
        [AllowEmptyString()][string]$Query,
        [ValidateSet('group', 'object', 'user', 'device')][string]$Kind = 'group',
        [int]$Limit = 50,
        [int]$TotalCap = 1000
    )
    $empty = [ordered]@{ total = 0; totalCapped = $false; results = @() }
    $q = ConvertTo-IalSearchKey $Query.Trim()
    if (-not $q) { return $empty }
    $tokens = @($q.Split([char[]]@(' ', "`t", "`n", "`r"), [System.StringSplitOptions]::RemoveEmptyEntries))
    if ($tokens.Count -eq 0) { return $empty }
    $first = $tokens[0]
    $anchor = ($tokens | Sort-Object Length -Descending | Select-Object -First 1)
    $ord = [System.StringComparison]::Ordinal
    $sb, $keys = switch ($Kind) {
        'group' { $Index.GroupBlob, $Index.GroupKeys }
        'user' { $Index.UserBlob, $Index.UserKeys }
        'device' { $Index.DeviceBlob, $Index.DeviceKeys }
        default { $Index.ObjectBlob, $Index.ObjectKeys }
    }
    $blob = $sb.Blob; $offsets = $sb.Offsets
    # Budget de candidats examinés par passe : borne le temps pour les requêtes très peu sélectives
    # (ex. « a b c »). Au-delà, le total est marqué comme plafonné.
    $budget = 1500

    $prefix = [System.Collections.Generic.List[int]]::new()
    $contains = [System.Collections.Generic.List[int]]::new()
    $total = 0
    $capped = $false

    # Passe 1 : clés qui COMMENCENT par le premier mot (IndexOf natif sur "\n" + mot).
    $needle = "`n" + $first
    $seen = 0
    $pos = $blob.IndexOf($needle, 0, $ord)
    while ($pos -ge 0 -and $prefix.Count -lt $Limit -and $seen -lt $budget) {
        $seen++
        $r = [Array]::BinarySearch($offsets, $pos + 1)
        $i = if ($r -ge 0) { $r } else { (-bnot $r) - 1 }
        $k = $keys[$i]
        $ok = $true
        foreach ($t in $tokens) { if ($k.IndexOf($t, $ord) -lt 0) { $ok = $false; break } }
        if ($ok) { $prefix.Add($i) }
        $pos = $blob.IndexOf($needle, $pos + 1, $ord)
    }

    # Passe 2 : occurrences de l'ancre (mot le plus long = le plus sélectif) : total et « contient ».
    $seen = 0
    $pos = $blob.IndexOf($anchor, 1, $ord)
    while ($pos -ge 0) {
        if (++$seen -gt $budget) { $capped = $true; break }
        $r = [Array]::BinarySearch($offsets, $pos)
        $i = if ($r -ge 0) { $r } else { (-bnot $r) - 1 }
        $k = $keys[$i]
        $ok = $true
        foreach ($t in $tokens) { if ($k.IndexOf($t, $ord) -lt 0) { $ok = $false; break } }
        if ($ok) {
            $total++
            if ($contains.Count -lt $Limit -and -not $k.StartsWith($first, $ord)) { $contains.Add($i) }
            if ($total -ge $TotalCap) { $capped = $true; break }
        }
        # Saut à la clé suivante (une seule occurrence comptée par clé)
        $next = $offsets[$i] + $k.Length + 1
        if ($next -ge $blob.Length) { break }
        $pos = $blob.IndexOf($anchor, $next, $ord)
    }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($i in @($prefix) + @($contains)) {
        if ($out.Count -ge $Limit) { break }
        if ($Kind -eq 'user') {
            $u = $Index.UserById[$Index.UserIds[$i]]
            $out.Add([ordered]@{ kind = 'user'; id = $u.id; name = $u.name; upn = $u.upn; count = $u.deviceIds.Count })
        }
        elseif ($Kind -eq 'device') {
            $d = $Index.DeviceById[$Index.DeviceIds[$i]]
            $out.Add([ordered]@{ kind = 'device'; id = $d['id']; name = $d['name']; os = $d['os']; userName = $d['userName']; stale = (Test-IalDeviceStale $d) })
        }
        elseif ($Kind -eq 'group') {
            $gid = $Index.GroupIds[$i]
            $list = $null
            $n = if ($Index.ByGroup.TryGetValue($gid, [ref]$list)) { $list.Count } else { 0 }
            $out.Add([ordered]@{ kind = 'group'; id = $gid; name = $Index.GroupNames[$i]; count = $n })
        }
        else {
            $o = $Index.ObjectById[$Index.ObjectIds[$i]]
            $out.Add([ordered]@{ kind = 'object'; id = $o.id; name = $o.name; family = $o.family; platform = $o.platform; count = @($o.assignments).Count })
        }
    }
    return [ordered]@{ total = $total; totalCapped = $capped; results = $out.ToArray() }
}

function Get-IalGroupName {
    param($Index, [string]$GroupId)
    $n = $null
    if ($Index.GroupById.TryGetValue($GroupId, [ref]$n)) { return $n, $true }
    return ("Groupe supprimé ($GroupId)"), $false
}

function Get-IalFilterInfo {
    param($Index, $Assignment)
    if (-not $Assignment.filterId) { return $null }
    $f = $Index.Filters[$Assignment.filterId]
    [ordered]@{
        id   = $Assignment.filterId
        name = $(if ($f) { $f.name } else { "Filtre inconnu ($($Assignment.filterId))" })
        mode = $Assignment.filterMode
    }
}

function Get-IalGroupView {
    <# Groupe -> éléments (lecture de l'index inversé) + règles globales indicatives. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$GroupId)
    $name, $exists = Get-IalGroupName -Index $Index -GroupId $GroupId
    $list = $null
    $hasItems = $Index.ByGroup.TryGetValue($GroupId, [ref]$list)
    if (-not $exists -and -not $hasItems) { return $null }

    $items = [System.Collections.Generic.List[object]]::new()
    $byFamily = [ordered]@{}
    $excludedObjects = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($hasItems) {
        foreach ($e in $list) {
            $o = $Index.ObjectById[$e.ObjectId]
            $a = $e.Assignment
            if ($a.mode -eq 'exclude') { $null = $excludedObjects.Add($o.id) }
            $items.Add([ordered]@{
                    objectId     = $o.id
                    name         = $o.name
                    family       = $o.family
                    typeKey      = $o.typeKey
                    odataType    = $o.odataType
                    platform     = $o.platform
                    lastModified = $o.lastModified
                    mode         = $a.mode
                    via          = (Get-IalViaLabel $a)
                    intent       = $a.intent
                    filter       = (Get-IalFilterInfo -Index $Index -Assignment $a)
                })
            if ($byFamily.Contains($o.family)) { $byFamily[$o.family]++ } else { $byFamily[$o.family] = 1 }
        }
    }

    $global = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $Index.Global) {
        $o = $Index.ObjectById[$e.ObjectId]
        $a = $e.Assignment
        $global.Add([ordered]@{
                objectId         = $o.id
                name             = $o.name
                family           = $o.family
                platform         = $o.platform
                via              = $script:IalViaLabels[$a.target]
                target           = $a.target
                intent           = $a.intent
                filter           = (Get-IalFilterInfo -Index $Index -Assignment $a)
                excludedForGroup = $excludedObjects.Contains($o.id)
            })
    }

    return [ordered]@{
        group    = [ordered]@{ id = $GroupId; name = $name; exists = $exists }
        total    = $items.Count
        byFamily = $byFamily
        items    = $items.ToArray()
        global   = $global.ToArray()
    }
}

function Get-IalObjectView {
    <# Élément -> groupes (lecture directe des assignations). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$ObjectId)
    $o = $null
    if (-not $Index.ObjectById.TryGetValue($ObjectId, [ref]$o)) { return $null }
    $targets = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($o.assignments | Where-Object { $null -ne $_ })) {
        $t = [ordered]@{ target = $a.target; via = (Get-IalViaLabel $a); mode = $a.mode; intent = $a.intent; filter = (Get-IalFilterInfo -Index $Index -Assignment $a); groupId = $null; groupName = $null; groupExists = $null }
        if ($a.target -eq 'group') {
            $gn, $ge = Get-IalGroupName -Index $Index -GroupId $a.groupId
            $t.groupId = $a.groupId; $t.groupName = $gn; $t.groupExists = $ge
        }
        $targets.Add($t)
    }
    # Cibles globales en tête, puis inclusions, puis exclusions
    $sorted = @($targets | Sort-Object @{ e = { if ($_.target -ne 'group') { 0 } elseif ($_.mode -eq 'include') { 1 } else { 2 } } }, @{ e = { $_.groupName } })
    return [ordered]@{
        object      = [ordered]@{ id = $o.id; name = $o.name; family = $o.family; typeKey = $o.typeKey; odataType = $o.odataType; platform = $o.platform; lastModified = $o.lastModified }
        unassigned  = ($targets.Count -eq 0)
        assignments = $sorted
    }
}

#region Fiches Utilisateur / Machine --------------------------------------------

function Test-IalDeviceStale {
    <# Appareil « inactif » : pas de synchronisation Intune depuis plus de StaleDeviceDays jours. #>
    param($Device, [datetimeoffset]$Now = [datetimeoffset]::UtcNow)
    $d = [datetimeoffset]::MinValue
    if (-not $Device -or -not $Device['lastSync']) { return $false }
    if (-not [datetimeoffset]::TryParse([string]$Device['lastSync'], [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { return $false }
    return ($Now - $d).TotalDays -gt $script:IalConfig.StaleDeviceDays
}

function ConvertTo-IalDeviceSummary {
    param($Device)
    [ordered]@{
        id = $Device['id']; name = $Device['name']; os = $Device['os']; platform = $Device['platform']; osVersion = $Device['osVersion']
        model = $Device['model']; maker = $Device['maker']; serial = $Device['serial']; lastSync = $Device['lastSync']
        compliance = $Device['compliance']; owner = $Device['owner']; aadId = $Device['aadId']
        userId = $Device['userId']; userName = $Device['userName']; upn = $Device['upn']
        stale = (Test-IalDeviceStale $Device)
    }
}

function ConvertTo-IalGroupList {
    <# Groupes d'une fiche : ceux qui servent dans Intune d'abord (nombre d'éléments assignés), puis par nom. #>
    param($Index, [AllowEmptyCollection()][object[]]$Groups = @())
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $list = foreach ($g in $Groups) {
        if (-not $g.id -or -not $seen.Add($g.id)) { continue }
        $n = 0; $l = $null
        if ($Index.ByGroup.TryGetValue($g.id, [ref]$l)) { $n = $l.Count }
        $nm = $null
        $name = if ($Index.GroupById.TryGetValue($g.id, [ref]$nm)) { $nm } elseif ($g.name) { $g.name } else { $g.id }
        [ordered]@{ id = $g.id; name = $name; used = $n }
    }
    return @($list | Sort-Object @{ e = { if ($_.used -gt 0) { 0 } else { 1 } } }, @{ e = { $_.name } })
}

function Get-IalTargeting {
    <#
        Calcule les éléments Intune qui CIBLENT un utilisateur et/ou ses appareils (calcul local, à partir des assignations).
          - assignation à un groupe de l'utilisateur, ou « Tous les utilisateurs » : vaut pour TOUS ses appareils ;
          - assignation à un groupe de l'appareil, ou « Tous les appareils » : vaut pour CET appareil ;
          - une exclusion (groupe de l'utilisateur ou de l'appareil) l'emporte sur l'inclusion ;
          - un élément d'une autre plateforme que l'appareil est ignoré pour cet appareil.
        Les filtres d'assignation ne sont PAS évalués (signalés). L'état réel de déploiement n'est pas lu.
        .PARAMETER Devices          appareils concernés (modèle interne) ; vide = utilisateur sans appareil
        .PARAMETER UserGroupIds     groupes (transitifs) de l'utilisateur
        .PARAMETER DeviceGroupIds   appareil (id) -> groupes (transitifs) de son objet Entra
        .PARAMETER HasUser          un utilisateur est associé (cibles « Tous les utilisateurs »)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Index,
        [AllowEmptyCollection()][object[]]$Devices = @(),
        [AllowEmptyCollection()][string[]]$UserGroupIds = @(),
        [hashtable]$DeviceGroupIds = @{},
        [bool]$HasUser = $true
    )
    $cmp = [System.StringComparer]::OrdinalIgnoreCase
    $newSet = { param($items) $h = [System.Collections.Generic.HashSet[string]]::new($cmp); foreach ($x in $items) { if ($x) { $null = $h.Add([string]$x) } }; , $h }
    $ug = & $newSet @($UserGroupIds)
    $contexts = [System.Collections.Generic.List[object]]::new()
    if (@($Devices).Count -eq 0) { $contexts.Add(@{ device = $null; dg = (& $newSet @()) }) }
    foreach ($d in $Devices) {
        $ids = if ($DeviceGroupIds.ContainsKey([string]$d['id'])) { @($DeviceGroupIds[[string]$d['id']]) } else { @() }
        $contexts.Add(@{ device = $d; dg = (& $newSet $ids) })
    }

    # Candidats : éléments assignés à l'un des groupes concernés, plus les règles globales.
    $cand = [System.Collections.Generic.HashSet[string]]::new($cmp)
    $allGroups = & $newSet @($ug)
    foreach ($c in $contexts) { $allGroups.UnionWith($c.dg) }
    foreach ($g in $allGroups) {
        $l = $null
        if ($Index.ByGroup.TryGetValue($g, [ref]$l)) { foreach ($e in $l) { $null = $cand.Add($e.ObjectId) } }
    }
    foreach ($e in $Index.Global) { $null = $cand.Add($e.ObjectId) }

    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($oid in $cand) {
        $o = $Index.ObjectById[$oid]
        $targets = [System.Collections.Generic.List[object]]::new()
        $sources = [System.Collections.Generic.HashSet[string]]::new()
        $firstInc = $null
        foreach ($c in $contexts) {
            $dev = $c.device
            if ($dev -and $o.platform -and $dev['platform'] -and $o.platform -ne $dev['platform'] -and $o.platform -ne 'Web') { continue }
            $inc = [System.Collections.Generic.List[object]]::new()
            $exc = [System.Collections.Generic.List[object]]::new()
            foreach ($a in $o.assignments) {
                if ($null -eq $a) { continue }
                $src = $null; $label = $null
                if ($a.target -eq 'group') {
                    $gn, $null = Get-IalGroupName -Index $Index -GroupId $a.groupId
                    if ($ug.Contains($a.groupId)) { $src = 'user'; $label = "$gn (utilisateur)" }
                    elseif ($c.dg.Contains($a.groupId)) { $src = 'device'; $label = "$gn (appareil)" }
                }
                elseif ($a.target -in 'allUsers', 'allLicensedUsers') { if ($HasUser) { $src = 'user'; $label = 'Tous les utilisateurs' } }
                elseif ($a.target -eq 'allDevices') { if ($dev) { $src = 'device'; $label = 'Tous les appareils' } }
                if (-not $src) { continue }
                $m = @{ source = $src; label = $label; assignment = $a }
                if ($a.mode -eq 'exclude') { $exc.Add($m) } else { $inc.Add($m) }
            }
            if ($inc.Count -eq 0) { continue }
            if (-not $firstInc) { $firstInc = $inc[0].assignment }
            # Une exclusion n'annule que les inclusions du MÊME type (utilisateur / appareil).
            # Mélange (inclusion utilisateur + exclusion appareil, ou l'inverse) : non pris en charge par
            # Intune (matrice « Exclude groups », Learn) ; l'inclusion reste, l'exclusion est signalée « non garantie ».
            $excSrc = @($exc | ForEach-Object { $_.source } | Select-Object -Unique)
            $kept = @($inc | Where-Object { $_.source -notin $excSrc })
            $mode = if ($kept.Count) { 'include' } else { 'exclude' }
            $mixed = ($kept.Count -gt 0 -and $exc.Count -gt 0)   # inclusion gardée malgré une exclusion de l'autre type
            $shown = if ($kept.Count) { $kept } else { $inc }
            if ($mode -eq 'include') { foreach ($m in $kept) { $null = $sources.Add($m.source) } }
            $targets.Add([ordered]@{
                    deviceId  = $(if ($dev) { $dev['id'] } else { $null })
                    mode      = $mode
                    via       = @($shown | ForEach-Object { $_.label } | Select-Object -Unique)
                    exclVia   = @($exc | ForEach-Object { $_.label } | Select-Object -Unique)
                    mixedExcl = $mixed
                    filtered  = (@($shown | Where-Object { $_.assignment.filterId }).Count -gt 0)
                })
        }
        if ($targets.Count -eq 0) { continue }
        $included = @($targets | Where-Object { $_.mode -eq 'include' })
        $scope = if ($sources.Contains('user') -and $sources.Contains('device')) { 'both' } elseif ($sources.Contains('device')) { 'device' } elseif ($sources.Contains('user')) { 'user' } else { 'none' }
        $out.Add([ordered]@{
                objectId     = $o.id
                name         = $o.name
                family       = $o.family
                typeKey      = $o.typeKey
                odataType    = $o.odataType
                platform     = $o.platform
                lastModified = $o.lastModified
                mode         = $(if ($included.Count) { 'include' } else { 'exclude' })
                scope        = $scope
                intent       = $firstInc.intent
                filter       = (Get-IalFilterInfo -Index $Index -Assignment $firstInc)
                targets      = $targets.ToArray()
            })
    }
    return @($out | Sort-Object @{ e = { $_.family } }, @{ e = { $_.name } })
}

function Get-IalUserView {
    <# Fiche Utilisateur : appareils, groupes (lus à la demande), éléments ciblés par appareil. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$UserId, $Memberships)
    $u = $null
    if (-not $Index.UserById.TryGetValue($UserId, [ref]$u)) { return $null }
    # Appareils actifs d'abord, puis du plus récemment synchronisé au plus ancien.
    $devices = @($u.deviceIds | ForEach-Object { $Index.DeviceById[$_] } |
            Sort-Object @{ e = { Test-IalDeviceStale $_ } }, @{ e = { [string]$_['lastSync'] }; Descending = $true })
    $userGroups = @()
    $warnings = [System.Collections.Generic.List[string]]::new()
    if ($Memberships -and $Memberships.user) {
        if ($Memberships.user.ok) { $userGroups = @($Memberships.user.groups) } else { $warnings.Add("Groupes de l'utilisateur : $($Memberships.user.reason)") }
    }
    $dg = @{}
    foreach ($d in $devices) {
        if (-not $d['aadId']) { $warnings.Add("$($d['name']) : appareil non joint à Entra, ses groupes ne sont pas lisibles."); continue }
        $m = if ($Memberships) { $Memberships.devices[[string]$d['aadId']] } else { $null }
        if ($m -and $m.ok) { $dg[[string]$d['id']] = @($m.groups | ForEach-Object { $_.id }) }
        elseif ($m) { $warnings.Add("$($d['name']) : $($m.reason)") }
    }
    $configs = Get-IalTargeting -Index $Index -Devices $devices -UserGroupIds @($userGroups | ForEach-Object { $_.id }) -DeviceGroupIds $dg -HasUser $true
    return [ordered]@{
        user     = [ordered]@{ id = $u.id; name = $u.name; upn = $u.upn }
        devices  = @($devices | ForEach-Object { ConvertTo-IalDeviceSummary $_ })
        groups   = @(ConvertTo-IalGroupList -Index $Index -Groups $userGroups)
        configs  = @($configs)
        warnings = @($warnings | Select-Object -Unique)
    }
}

function Get-IalDeviceView {
    <# Fiche Machine : utilisateur principal, groupes de l'appareil, éléments ciblés (via l'appareil ou l'utilisateur). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Index, [Parameter(Mandatory)][string]$DeviceId, $Memberships)
    $d = $null
    if (-not $Index.DeviceById.TryGetValue($DeviceId, [ref]$d)) { return $null }
    $u = $null
    $hasUser = [bool]($d['userId'] -and $Index.UserById.TryGetValue([string]$d['userId'], [ref]$u))
    $warnings = [System.Collections.Generic.List[string]]::new()
    $userGroups = @()
    if ($hasUser -and $Memberships -and $Memberships.user) {
        if ($Memberships.user.ok) { $userGroups = @($Memberships.user.groups) } else { $warnings.Add("Groupes de l'utilisateur : $($Memberships.user.reason)") }
    }
    $devGroups = @()
    if (-not $d['aadId']) { $warnings.Add('Appareil non joint à Entra : ses groupes ne sont pas lisibles.') }
    else {
        $m = if ($Memberships) { $Memberships.devices[[string]$d['aadId']] } else { $null }
        if ($m -and $m.ok) { $devGroups = @($m.groups) } elseif ($m) { $warnings.Add($m.reason) }
    }
    $dgMap = @{ ([string]$d['id']) = @($devGroups | ForEach-Object { $_.id }) }
    $configs = Get-IalTargeting -Index $Index -Devices @($d) -UserGroupIds @($userGroups | ForEach-Object { $_.id }) -DeviceGroupIds $dgMap -HasUser $hasUser
    return [ordered]@{
        device         = (ConvertTo-IalDeviceSummary $d)
        user           = $(if ($hasUser) { [ordered]@{ id = $u.id; name = $u.name; upn = $u.upn; deviceCount = $u.deviceIds.Count } } else { $null })
        groups         = @(ConvertTo-IalGroupList -Index $Index -Groups $devGroups)
        userGroupCount = @($userGroups).Count
        configs        = @($configs)
        warnings       = @($warnings | Select-Object -Unique)
    }
}

#endregion
