# GraphClient.ps1 : SEUL fichier qui parle à Microsoft Graph (mode réel) ou aux fichiers Mock.
#
# Garde-fou « lecture seule » par construction :
#   - Une seule porte d'entrée réseau : Invoke-GraphRead.
#   - Méthode GET uniquement ; seule exception : POST vers /$batch dont CHAQUE sous-requête est un GET.
#   - Hôte unique autorisé : graph.microsoft.com (HTTPS).
#   - 429 / 5xx : respect de Retry-After, repli exponentiel plafonné, nombre maximal de tentatives.
#   - Appels strictement séquentiels (concurrence = 1).
# Toute violation lève une exception AVANT qu'un octet ne parte.

Set-StrictMode -Version 3.0

$script:IalGraph = @{
    Mode      = $null          # 'Real' | 'Mock'
    Sleep     = { param([double]$Seconds) Start-Sleep -Milliseconds ([int]($Seconds * 1000)) }
    Status    = $null          # hashtable synchronisée optionnelle (ThrottledUntil, LastError)
    Stats     = @{ Requests = 0; Retries = 0; Throttled = 0 }
}

#region Erreurs ---------------------------------------------------------------

function New-IalGraphError {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$StatusCode = 0,
        [string]$Kind = 'Graph'      # Guard | Graph | Auth | Forbidden | NotFound | Throttled
    )
    $ex = [System.InvalidOperationException]::new($Message)
    $ex.Data['IalKind'] = $Kind
    $ex.Data['IalStatus'] = $StatusCode
    return $ex
}

#endregion

#region Garde-fou -------------------------------------------------------------

function Assert-IalGraphUri {
    param([Parameter(Mandatory)][string]$Uri)
    $u = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u)) {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : URL non absolue refusée.")
    }
    if ($u.Scheme -ne 'https') {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : schéma '$($u.Scheme)' refusé (HTTPS uniquement).")
    }
    if (-not [string]::Equals($u.Host, $script:IalConfig.GraphHost, [System.StringComparison]::OrdinalIgnoreCase) -or
        $u.UserInfo -or -not $u.IsDefaultPort) {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : hôte '$($u.Authority)' refusé (seul $($script:IalConfig.GraphHost) est autorisé).")
    }
    return $u
}

function Assert-IalReadOnlyRequest {
    <#
        Lève une exception si la requête n'est pas strictement en lecture.
        Retourne le corps normalisé (hashtable) pour un $batch, sinon $null.
    #>
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        $Body
    )
    $u = Assert-IalGraphUri -Uri $Uri
    $m = $Method.Trim().ToUpperInvariant()

    if ($m -eq 'GET') {
        if ($null -ne $Body) {
            throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : un GET ne doit pas avoir de corps.')
        }
        return $null
    }

    if ($m -ne 'POST') {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : méthode '$m' interdite (lecture seule).")
    }

    # Seul POST autorisé : /v1.0/$batch ou /beta/$batch, sans paramètre.
    if ($u.AbsolutePath -notin @('/v1.0/$batch', '/beta/$batch') -or $u.Query) {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : POST refusé hors de /`$batch.")
    }

    if ($Body -is [string]) {
        try { $Body = $Body | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : corps $batch illisible.') }
    }
    if ($null -eq $Body -or -not ($Body -is [System.Collections.IDictionary]) -or -not $Body.Contains('requests')) {
        throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : corps $batch sans liste de requêtes.')
    }
    $reqs = @($Body['requests'])
    if ($reqs.Count -lt 1 -or $reqs.Count -gt $script:IalConfig.BatchSize) {
        throw (New-IalGraphError -Kind Guard -Message "Garde-fou : un `$batch doit contenir de 1 à $($script:IalConfig.BatchSize) sous-requêtes.")
    }
    foreach ($r in $reqs) {
        if (-not ($r -is [System.Collections.IDictionary])) {
            throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : sous-requête $batch invalide.')
        }
        $sm = [string]$r['method']
        if ($sm -cne 'GET' -and $sm.ToUpperInvariant() -ne 'GET') {
            throw (New-IalGraphError -Kind Guard -Message "Garde-fou : sous-requête `$batch '$sm' interdite (GET uniquement).")
        }
        if ($r.Contains('body')) {
            throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : une sous-requête GET ne doit pas avoir de corps.')
        }
        $su = [string]$r['url']
        if (-not $su.StartsWith('/') -or $su.StartsWith('//') -or $su -match '\$batch' -or $su -match '^\s*[a-z]+:') {
            throw (New-IalGraphError -Kind Guard -Message 'Garde-fou : URL de sous-requête $batch refusée.')
        }
    }
    return $Body
}

#endregion

#region Transports ------------------------------------------------------------
# Un transport reçoit (Method, Uri, BodyHashtable) et renvoie
#   @{ StatusCode = <int>; Headers = <IDictionary>; Content = <hashtable|$null> }
# Il ne lève pas d'exception pour un code HTTP d'erreur.

$script:IalTransportReal = {
    param([string]$Method, [string]$Uri, $Body)
    $sc = $null; $rh = $null
    $p = @{
        Method                  = $Method
        Uri                     = $Uri
        OutputType              = 'HashTable'
        SkipHttpErrorCheck      = $true
        StatusCodeVariable      = 'sc'
        ResponseHeadersVariable = 'rh'
        ErrorAction             = 'Stop'
    }
    if ($null -ne $Body) {
        $p.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $p.ContentType = 'application/json'
    }
    $content = Invoke-MgGraphRequest @p
    return @{ StatusCode = [int]$sc; Headers = $rh; Content = $content }
}

#endregion

#region Appel unique ----------------------------------------------------------

function Get-IalRetryAfterSeconds {
    param($Headers, [int]$Attempt)
    $ra = $null
    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($k in @($Headers.Keys)) {
            if ([string]::Equals([string]$k, 'Retry-After', [System.StringComparison]::OrdinalIgnoreCase)) { $ra = $Headers[$k] }
        }
    }
    if ($ra -is [array]) { $ra = $ra | Select-Object -First 1 }
    $sec = 0.0
    if ($null -ne $ra -and [double]::TryParse([string]$ra, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$sec) -and $sec -ge 0) {
        return [math]::Min($sec, [double]$script:IalConfig.RetryMaxDelaySec)
    }
    $exp = $script:IalConfig.RetryBaseDelaySec * [math]::Pow(2, $Attempt - 1)
    return [math]::Min($exp, [double]$script:IalConfig.RetryMaxDelaySec)
}

function Invoke-GraphRead {
    <#
        .SYNOPSIS
        Unique porte d'entrée vers Graph. Lecture seule garantie par Assert-IalReadOnlyRequest.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [string]$Method = 'GET',
        $Body
    )
    $normalizedBody = Assert-IalReadOnlyRequest -Method $Method -Uri $Uri -Body $Body
    if (-not $script:IalGraph.Mode) {
        throw (New-IalGraphError -Kind Guard -Message 'GraphClient non initialisé (mode réel ou Mock).')
    }
    $transport = if ($script:IalGraph.Mode -eq 'Mock') { $script:IalTransportMock } else { $script:IalTransportReal }
    $methodNorm = $Method.Trim().ToUpperInvariant()

    $attempt = 0
    while ($true) {
        $attempt++
        $script:IalGraph.Stats.Requests++
        $resp = & $transport $methodNorm $Uri $normalizedBody
        $code = [int]$resp.StatusCode

        if ($code -ge 200 -and $code -lt 300) {
            if ($script:IalGraph.Status) { $script:IalGraph.Status['ThrottledUntil'] = $null }
            return $resp.Content
        }

        $retryable = ($code -eq 429 -or $code -ge 500)
        if ($retryable -and $attempt -lt $script:IalConfig.MaxRetries) {
            $wait = Get-IalRetryAfterSeconds -Headers $resp.Headers -Attempt $attempt
            $script:IalGraph.Stats.Retries++
            if ($code -eq 429) {
                $script:IalGraph.Stats.Throttled++
                if ($script:IalGraph.Status) { $script:IalGraph.Status['ThrottledUntil'] = (Get-Date).AddSeconds($wait).ToString('o') }
            }
            Write-IalLog -Level WARN -Message ("Graph HTTP {0}, nouvelle tentative {1}/{2} dans {3:0.#} s" -f $code, ($attempt + 1), $script:IalConfig.MaxRetries, $wait)
            & $script:IalGraph.Sleep $wait
            continue
        }

        $kind = switch ($code) { 401 { 'Auth' } 403 { 'Forbidden' } 404 { 'NotFound' } 429 { 'Throttled' } default { 'Graph' } }
        throw (New-IalGraphError -Kind $kind -StatusCode $code -Message "Graph a répondu HTTP $code après $attempt tentative(s).")
    }
}

#endregion

#region Pagination et lots ----------------------------------------------------

function Invoke-GraphList {
    <# Suit @odata.nextLink. Protection contre les boucles (lien déjà vu, nombre de pages max). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Uri)
    $items = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $next = $Uri
    $pages = 0
    while ($next) {
        if (-not $seen.Add($next)) {
            throw (New-IalGraphError -Message 'Pagination : lien nextLink déjà visité (boucle détectée).')
        }
        if (++$pages -gt $script:IalConfig.MaxPagesPerList) {
            throw (New-IalGraphError -Message "Pagination : plus de $($script:IalConfig.MaxPagesPerList) pages, arrêt.")
        }
        $page = Invoke-GraphRead -Uri $next
        if ($page -and $page.Contains('value')) {
            foreach ($v in @($page['value'])) { if ($null -ne $v) { $items.Add($v) } }
        }
        $next = if ($page -and $page.Contains('@odata.nextLink')) { [string]$page['@odata.nextLink'] } else { $null }
    }
    return , $items
}

function Invoke-GraphBatch {
    <#
        .SYNOPSIS
        Exécute des GET en lots de 20 via /$batch.
        .PARAMETER Requests
        Liste de @{ id = '<clé unique>'; url = '/chemin/relatif' }
        .OUTPUTS
        Hashtable id -> @{ status = <int>; body = <hashtable> }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Requests,
        [ValidateSet('v1.0', 'beta')][string]$Version = 'beta'
    )
    $results = @{}
    $batchUri = if ($Version -eq 'v1.0') { "$($script:IalConfig.GraphBaseV1)/`$batch" } else { "$($script:IalConfig.GraphBaseBeta)/`$batch" }
    $size = $script:IalConfig.BatchSize
    for ($i = 0; $i -lt $Requests.Count; $i += $size) {
        $pending = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $Requests[$i..([math]::Min($i + $size, $Requests.Count) - 1)]) { $pending.Add($r) }

        $attempt = 0
        while ($pending.Count -gt 0) {
            $attempt++
            $body = @{ requests = @(foreach ($r in $pending) { @{ id = [string]$r.id; method = 'GET'; url = [string]$r.url } }) }
            $resp = Invoke-GraphRead -Method POST -Uri $batchUri -Body $body

            $retry = [System.Collections.Generic.List[object]]::new()
            $maxWait = 0.0
            $byId = @{}
            foreach ($r in $pending) { $byId[[string]$r.id] = $r }
            foreach ($sub in @($resp['responses'])) {
                $sid = [string]$sub['id']
                $st = [int]$sub['status']
                if (($st -eq 429 -or $st -ge 500) -and $attempt -lt $script:IalConfig.MaxRetries -and $byId.ContainsKey($sid)) {
                    $retry.Add($byId[$sid])
                    $w = Get-IalRetryAfterSeconds -Headers $sub['headers'] -Attempt $attempt
                    if ($w -gt $maxWait) { $maxWait = $w }
                    if ($st -eq 429) { $script:IalGraph.Stats.Throttled++ }
                }
                else {
                    $results[$sid] = @{ status = $st; body = $sub['body'] }
                }
            }
            # Sous-requêtes sans réponse : on les retente aussi.
            foreach ($r in $pending) {
                $rid = [string]$r.id
                if (-not $results.ContainsKey($rid) -and -not $retry.Contains($r)) { $retry.Add($r) }
            }
            if ($retry.Count -gt 0) {
                if ($attempt -ge $script:IalConfig.MaxRetries) {
                    foreach ($r in $retry) { $results[[string]$r.id] = @{ status = 0; body = $null } }
                    break
                }
                $script:IalGraph.Stats.Retries++
                if ($maxWait -le 0) { $maxWait = Get-IalRetryAfterSeconds -Headers $null -Attempt $attempt }
                Write-IalLog -Level WARN -Message ("`$batch : {0} sous-requête(s) à retenter dans {1:0.#} s" -f $retry.Count, $maxWait)
                & $script:IalGraph.Sleep $maxWait
            }
            $pending = $retry
        }
    }
    return $results
}

#endregion

#region Mode Mock -------------------------------------------------------------
# Lit mock/fixtures/<dataset>.json et simule Graph (pagination, $batch, 429, 500, 403).
# Aucun appel réseau.

$script:IalMock = @{
    FixturesDir = $null
    Dataset     = 'base'
    Data        = $null
    ById        = @{}
    PathToKey   = @{}
    Faults      = @{ Throttle429Once = @(); Error500Once = @(); Forbidden = @(); BatchSub429Once = $false; LoopNextLink = @(); RejectSelect = @() }
    Fired       = [System.Collections.Generic.HashSet[string]]::new()
    CallLog     = [System.Collections.Generic.List[string]]::new()
    ListPageSize = 100
}

function Initialize-IalGraphMock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FixturesDir,
        [string]$Dataset = 'base'
    )
    $script:IalGraph.Mode = 'Mock'
    $script:IalMock.FixturesDir = $FixturesDir
    $script:IalMock.PathToKey = @{}
    foreach ($t in $script:IalObjectTypes) { $script:IalMock.PathToKey[$t.Path.ToLowerInvariant()] = $t.Key }
    Set-IalMockDataset -Name $Dataset
}

function Set-IalMockDataset {
    param([Parameter(Mandatory)][string]$Name)
    $file = Join-Path $script:IalMock.FixturesDir "$Name.json"
    if (-not (Test-Path -LiteralPath $file)) {
        throw "Jeu Mock introuvable : $file. Lancez d'abord mock/New-MockData.ps1."
    }
    $script:IalMock.Dataset = $Name
    $script:IalMock.Data = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable
    # Accès direct par id (évite un parcours linéaire par sous-requête $batch)
    $byId = @{}
    foreach ($k in $script:IalMock.Data['objects'].Keys) {
        $d = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($o in $script:IalMock.Data['objects'][$k]) { $d[[string]$o['id']] = $o }
        $byId[$k] = $d
    }
    $script:IalMock.ById = $byId
    $gn = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($g in @($script:IalMock.Data['groups'])) { $gn[[string]$g['id']] = [string]$g['displayName'] }
    $script:IalMock.GroupNames = $gn
    $script:IalMock.Fired.Clear()
}

function Reset-IalMockFaults {
    $script:IalMock.Faults = @{ Throttle429Once = @(); Error500Once = @(); Forbidden = @(); BatchSub429Once = $false; LoopNextLink = @(); RejectSelect = @() }
    $script:IalMock.Fired.Clear()
    $script:IalMock.CallLog.Clear()
}

function Get-IalMockQuery {
    param([System.Uri]$U)
    $q = @{}
    $raw = $U.Query.TrimStart('?')
    if (-not $raw) { return $q }
    foreach ($pair in $raw.Split('&')) {
        $kv = $pair.Split('=', 2)
        $q[[System.Uri]::UnescapeDataString($kv[0])] = if ($kv.Count -gt 1) { [System.Uri]::UnescapeDataString($kv[1]) } else { '' }
    }
    return $q
}

function Invoke-IalMockRoute {
    <# Résout un GET Mock. $Path : chemin sans version ni '/' initial. #>
    param([string]$Version, [string]$Path, [hashtable]$Query)
    $data = $script:IalMock.Data
    $f = $script:IalMock.Faults
    $lp = $Path.ToLowerInvariant()
    $skip = if ($Query.ContainsKey('$skiptoken')) { [int]$Query['$skiptoken'] } else { 0 }
    $script:IalMock.CallLog.Add("GET $lp" + $(if ($skip) { "?skip=$skip" } else { '' }))

    # Pannes simulées (une seule fois par clé)
    foreach ($p in @($f.Throttle429Once)) {
        if ($lp -eq $p.ToLowerInvariant() -and $script:IalMock.Fired.Add("429|$lp|$skip")) {
            return @{ StatusCode = 429; Headers = @{ 'Retry-After' = '1' }; Content = @{ error = @{ code = 'TooManyRequests' } } }
        }
    }
    foreach ($p in @($f.RejectSelect)) {
        # Simule un $select refusé : tout $select contenant autre chose que id, nom et date.
        if ($lp -eq $p.ToLowerInvariant() -and $Query.ContainsKey('$select') -and $Query['$select'] -match 'templateReference|platforms') {
            return @{ StatusCode = 400; Headers = @{}; Content = @{ error = @{ code = 'BadRequest' } } }
        }
    }
    foreach ($p in @($f.Error500Once)) {
        if ($lp -eq $p.ToLowerInvariant() -and $script:IalMock.Fired.Add("500|$lp|$skip")) {
            return @{ StatusCode = 500; Headers = @{}; Content = @{ error = @{ code = 'InternalServerError' } } }
        }
    }

    $ok = { param($c) @{ StatusCode = 200; Headers = @{}; Content = $c } }
    $page = {
        param([System.Collections.IList]$All, [int]$Size, [string]$BasePath)
        $end = [math]::Min($skip + $Size, $All.Count)
        $vals = if ($skip -lt $All.Count) { @($All[$skip..($end - 1)]) } else { @() }
        $c = [ordered]@{ value = $vals }
        # Comme Graph, le nextLink conserve la taille de page demandée.
        if ($end -lt $All.Count) {
            $c['@odata.nextLink'] = "https://graph.microsoft.com/$Version/$BasePath`?`$top=$Size&`$skiptoken=$end"
        }
        if ($f.LoopNextLink -contains $lp) {
            $c['@odata.nextLink'] = "https://graph.microsoft.com/$Version/$BasePath`?`$top=$Size&`$skiptoken=$skip"
        }
        $c
    }

    if ($lp -eq 'groups') {
        $size = if ($Query.ContainsKey('$top')) { [int]$Query['$top'] } else { 100 }
        return & $ok (& $page $data['groups'] $size 'groups')
    }
    if ($lp -eq 'devicemanagement/assignmentfilters') {
        return & $ok (& $page $data['filters'] 100 'deviceManagement/assignmentFilters')
    }

    # Appareils gérés et appartenances (fiches Utilisateur / Machine)
    if ($lp -eq 'devicemanagement/manageddevices') {
        if (@($f.Forbidden) -contains 'managedDevices') { return @{ StatusCode = 403; Headers = @{}; Content = @{ error = @{ code = 'Forbidden' } } } }
        $now = [datetime]::UtcNow
        $all = foreach ($d in $(if ($data.Contains('managedDevices')) { @($data['managedDevices']) } else { @() })) {
            # Le jeu stocke « jours avant aujourd'hui » : converti ici en date, comme Graph la renverrait.
            $c = [ordered]@{}
            foreach ($k in $d.Keys) { if ($k -ne 'lastSyncDaysAgo') { $c[$k] = $d[$k] } }
            $c['lastSyncDateTime'] = $now.AddDays(-[double]$d['lastSyncDaysAgo']).AddMinutes(-37).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
            $c
        }
        return & $ok (& $page @($all) 100 'deviceManagement/managedDevices')
    }
    $mm = [regex]::Match($lp, "^(?:users/(?<u>[^/]+)|devices\(deviceid='(?<d>[^']+)'\))/transitivememberof$")
    if ($mm.Success) {
        $isUser = $mm.Groups['u'].Success
        $fk = if ($isUser) { 'userMemberOf' } else { 'deviceMemberOf' }
        if (@($f.Forbidden) -contains $fk) { return @{ StatusCode = 403; Headers = @{}; Content = @{ error = @{ code = 'Authorization_RequestDenied' } } } }
        $id = if ($isUser) { $mm.Groups['u'].Value } else { $mm.Groups['d'].Value }
        $map = if ($data.Contains($fk)) { $data[$fk] } else { @{} }
        if (-not $map.Contains($id)) { return @{ StatusCode = 404; Headers = @{}; Content = @{ error = @{ code = 'Request_ResourceNotFound' } } } }
        $vals = [System.Collections.Generic.List[object]]::new()
        # Comme Graph : les rôles d'annuaire figurent aussi dans transitiveMemberOf (l'outil doit les ignorer).
        if ($isUser) { $vals.Add([ordered]@{ '@odata.type' = '#microsoft.graph.directoryRole'; id = 'role-demo'; displayName = 'Lecteurs de répertoire' }) }
        foreach ($gid in @($map[$id])) {
            $n = $null
            $null = $script:IalMock.GroupNames.TryGetValue([string]$gid, [ref]$n)
            $vals.Add([ordered]@{ '@odata.type' = '#microsoft.graph.group'; id = [string]$gid; displayName = $n })
        }
        return & $ok (& $page $vals 100 $lp)
    }

    # Liste d'un type ou assignations d'un objet
    $m = [regex]::Match($lp, '^(?<type>[a-z]+/[a-z]+)(?:/(?<id>[^/]+)/assignments)?$')
    if ($m.Success -and $script:IalMock.PathToKey.ContainsKey($m.Groups['type'].Value)) {
        $key = $script:IalMock.PathToKey[$m.Groups['type'].Value]
        if (@($f.Forbidden) -contains $key) {
            return @{ StatusCode = 403; Headers = @{}; Content = @{ error = @{ code = 'Forbidden' } } }
        }
        $objs = if ($data['objects'].Contains($key)) { $data['objects'][$key] } else { @() }
        if ($m.Groups['id'].Success) {
            $o = $null
            if ($script:IalMock.ById.Contains($key) -and $script:IalMock.ById[$key].TryGetValue($m.Groups['id'].Value, [ref]$o)) {
                return & $ok ([ordered]@{ value = @($o['assignments']) })
            }
            return @{ StatusCode = 404; Headers = @{}; Content = @{ error = @{ code = 'ResourceNotFound' } } }
        }
        # Liste légère : on retire les assignations (comme $select)
        $light = [System.Collections.Generic.List[object]]::new()
        foreach ($o in $objs) {
            $l = [ordered]@{}
            foreach ($k in $o.Keys) { if ($k -ne 'assignments') { $l[$k] = $o[$k] } }
            $light.Add($l)
        }
        $typePath = ($script:IalObjectTypes | Where-Object { $_.Key -eq $key }).Path
        return & $ok (& $page $light $script:IalMock.ListPageSize $typePath)
    }
    return @{ StatusCode = 404; Headers = @{}; Content = @{ error = @{ code = 'ResourceNotFound' } } }
}

$script:IalTransportMock = {
    param([string]$Method, [string]$Uri, $Body)
    $u = [System.Uri]$Uri
    $segments = $u.AbsolutePath.TrimStart('/').Split('/', 2)
    $version = $segments[0]
    $path = if ($segments.Count -gt 1) { [System.Uri]::UnescapeDataString($segments[1]) } else { '' }

    if ($Method -eq 'POST' -and $path -eq '$batch') {
        $script:IalMock.CallLog.Add('POST $batch')
        $responses = foreach ($r in @($Body['requests'])) {
            $su = [System.Uri]::new([System.Uri]"https://graph.microsoft.com/$version/", ([string]$r['url']).TrimStart('/'))
            $sp = [System.Uri]::UnescapeDataString($su.AbsolutePath.Substring($version.Length + 2))
            if ($script:IalMock.Faults.BatchSub429Once -and $script:IalMock.Fired.Add("sub429|$sp")) {
                @{ id = $r['id']; status = 429; headers = @{ 'Retry-After' = '1' }; body = @{ error = @{ code = 'TooManyRequests' } } }
                continue
            }
            $res = Invoke-IalMockRoute -Version $version -Path $sp -Query (Get-IalMockQuery $su)
            @{ id = $r['id']; status = $res.StatusCode; headers = $res.Headers; body = $res.Content }
        }
        return @{ StatusCode = 200; Headers = @{}; Content = @{ responses = @($responses) } }
    }
    return Invoke-IalMockRoute -Version $version -Path $path -Query (Get-IalMockQuery $u)
}

#endregion

#region Connexion réelle ------------------------------------------------------

function Connect-IalGraph {
    <# Mode réel uniquement. Jeton limité au processus, scopes explicites. Jamais appelé en Mock. #>
    [CmdletBinding()]
    param([string]$TenantId)
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        throw "Le module Microsoft.Graph.Authentication est absent. Installez-le vous-même ; l'outil n'installe rien."
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    # 4 scopes de base + Device.Read.All (groupes des machines, accord de l'utilisateur). Tous en LECTURE.
    $p = @{ Scopes = (Get-IalConnectScopes); ContextScope = 'Process'; NoWelcome = $true; ErrorAction = 'Stop' }
    if ($TenantId) { $p.TenantId = $TenantId }
    try { Connect-MgGraph @p }
    catch {
        # Consentement refusé ou soumis à approbation pour Device.Read.All : repli sur les 4 scopes de base
        # (déjà consentis). L'outil fonctionne, seuls les groupes des machines manquent.
        if ($_.Exception.Message -notmatch 'AADSTS(65001|65004|90094|90008)|consent|approval|approbation') { throw }
        Write-IalLog -Level WARN -Message "Permission $($script:IalConfig.DeviceScope) non accordée : connexion avec les 4 permissions de base (groupes des machines indisponibles)."
        $p.Scopes = $script:IalConfig.Scopes
        Connect-MgGraph @p
    }
    $script:IalGraph.Mode = 'Real'
    $ctx = Get-MgContext
    $extra = @($ctx.Scopes | Where-Object { $_ -notin (Get-IalConnectScopes) })
    if ($extra.Count -gt 0) {
        Write-IalLog -Level WARN -Message ("Le jeton contient {0} scope(s) au-delà de ceux demandés (consentement préexistant). L'outil reste en lecture seule par construction." -f $extra.Count)
    }
}

function Initialize-IalGraphReal {
    <#
        Dans un runspace secondaire (synchro en arrière-plan) : réutilise la connexion du processus.
        Connect-MgGraph -ContextScope Process rend le contexte visible dans tout le processus. [À VÉRIFIER M6]
        Aucune nouvelle authentification n'est déclenchée ici.
    #>
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    if (-not (Get-MgContext)) { throw 'Aucune connexion Graph active dans ce processus.' }
    $script:IalGraph.Mode = 'Real'
}

function Disconnect-IalGraph {
    if ($script:IalGraph.Mode -eq 'Real') {
        try { Disconnect-MgGraph -ErrorAction Stop | Out-Null } catch { }
    }
}

#endregion
