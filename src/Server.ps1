# Server.ps1 : serveur HTTP local (HttpListener, 127.0.0.1 uniquement), routes et en-têtes de sécurité.
# Aucune route n'écrit vers Graph. Les POST sont des actions LOCALES.

Set-StrictMode -Version 3.0

# CSP minimale : uniquement 'self', aucun assouplissement. (L'exception img-src data: qu'exigeait la
# librairie WebGL a été retirée avec la librairie : rendu 100 % CSS, décision de l'utilisateur.)
# Tout blocage éventuel est journalisé via /csp-report.
$script:IalCsp = "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; font-src 'self'; connect-src 'self'; manifest-src 'none'; worker-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; report-uri /csp-report"
$script:IalPermissionsPolicy = 'camera=(), microphone=(), geolocation=(), usb=(), serial=(), hid=(), payment=(), bluetooth=(), display-capture=()'
$script:IalCspMaxLogged = 50

$script:IalContentTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.ico'  = 'image/x-icon'
    '.woff2' = 'font/woff2'
}

function New-IalSessionToken {
    $b = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($b)
    return [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-IalTokenEqual {
    <# Comparaison en temps constant. #>
    param([string]$Expected, [string]$Actual)
    if ([string]::IsNullOrEmpty($Actual)) { return $false }
    $a = [System.Text.Encoding]::UTF8.GetBytes($Expected)
    $b = [System.Text.Encoding]::UTF8.GetBytes($Actual)
    return [System.Security.Cryptography.CryptographicOperations]::FixedTimeEquals($a, $b)
}

function Get-IalStaticWhitelist {
    <#
        Liste blanche des fichiers servis : construite UNE fois au démarrage depuis web/.
        Exclut liens symboliques / jonctions et extensions inattendues.
        Clé : chemin URL (/static/...), valeur : chemin disque.
    #>
    param([Parameter(Mandatory)][string]$WebRoot)
    $root = (Resolve-Path -LiteralPath $WebRoot).ProviderPath.TrimEnd('\')
    $wl = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
    foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
        if (-not $script:IalContentTypes.ContainsKey($f.Extension.ToLowerInvariant())) { continue }
        # Dossier vendor : jamais servi (la librairie WebGL n'est plus utilisée ; rendu 100 % CSS).
        $relCheck = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        if ($relCheck -like 'vendor/*') { continue }
        # Refus de tout élément de chemin qui est un point d'analyse (lien symbolique, jonction)
        $reparse = $false
        $p = $f
        while ($p -and $p.FullName.TrimEnd('\') -ne $root) {
            if ($p.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { $reparse = $true; break }
            $p = if ($p -is [System.IO.FileInfo]) { $p.Directory } else { $p.Parent }
        }
        if ($reparse) { continue }
        $rel = $f.FullName.Substring($root.Length + 1).Replace('\', '/')
        $wl['/static/' + $rel] = $f.FullName
    }
    $index = Join-Path $root 'index.html'
    if (Test-Path -LiteralPath $index) { $wl['/'] = $index }
    return $wl
}

function Get-IalFreePort {
    $t = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $t.Start()
    try { return $t.LocalEndpoint.Port } finally { $t.Stop() }
}

function Start-IalServer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$WebRoot,
        [int]$Port = 0,
        [string]$Token
    )
    if (-not $Token) { $Token = New-IalSessionToken }
    $attempts = if ($Port -gt 0) { 1 } else { 5 }
    for ($i = 1; $i -le $attempts; $i++) {
        $p = if ($Port -gt 0) { $Port } else { Get-IalFreePort }
        $l = [System.Net.HttpListener]::new()
        $l.Prefixes.Add("http://$($script:IalConfig.ListenAddress):$p/")
        $l.IgnoreWriteExceptions = $true
        try {
            $l.Start()
            return [pscustomobject]@{
                Listener  = $l
                Port      = $p
                Token     = $Token
                Host      = "$($script:IalConfig.ListenAddress):$p"
                Origin    = "http://$($script:IalConfig.ListenAddress):$p"
                Whitelist = (Get-IalStaticWhitelist -WebRoot $WebRoot)
            }
        }
        catch {
            $l.Close()
            if ($i -ge $attempts) { throw (Tx "Impossible d'écouter sur 127.0.0.1:$p : $($_.Exception.Message)" "Cannot listen on 127.0.0.1:${p}: $($_.Exception.Message)") }
        }
    }
}

function Stop-IalServer {
    param($Server)
    if ($Server -and $Server.Listener) {
        try { $Server.Listener.Stop() } catch { }
        try { $Server.Listener.Close() } catch { }
    }
}

#region Réponses --------------------------------------------------------------

function Set-IalSecurityHeaders {
    param($Response, [switch]$Api)
    $h = $Response.Headers
    $h['Content-Security-Policy'] = $script:IalCsp
    $h['Permissions-Policy'] = $script:IalPermissionsPolicy
    $h['X-Content-Type-Options'] = 'nosniff'
    $h['Referrer-Policy'] = 'no-referrer'
    $h['Cross-Origin-Resource-Policy'] = 'same-origin'
    $h['Cross-Origin-Opener-Policy'] = 'same-origin'
    $h['X-Frame-Options'] = 'DENY'
    $h['Cache-Control'] = if ($Api) { 'no-store' } else { 'no-cache' }
}

function Send-IalBytes {
    param($Context, [int]$Status, [string]$ContentType, [byte[]]$Bytes, [switch]$Api)
    $res = $Context.Response
    $res.StatusCode = $Status
    Set-IalSecurityHeaders -Response $res -Api:$Api
    $res.ContentType = $ContentType
    $res.ContentLength64 = $Bytes.Length
    if ($Context.Request.HttpMethod -ne 'HEAD' -and $Bytes.Length -gt 0) {
        $res.OutputStream.Write($Bytes, 0, $Bytes.Length)
    }
    $res.OutputStream.Close()
}

function Send-IalJson {
    param($Context, [int]$Status = 200, $Body)
    $json = if ($null -eq $Body) { 'null' } else { ConvertTo-Json -InputObject $Body -Depth 10 -Compress -EscapeHandling EscapeHtml }
    Send-IalBytes -Context $Context -Status $Status -ContentType 'application/json; charset=utf-8' -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($json)) -Api
}

function Send-IalError {
    <# Message français, sans détail interne. #>
    param($Context, [int]$Status, [string]$Message)
    Send-IalJson -Context $Context -Status $Status -Body ([ordered]@{ error = $Message })
}

#endregion

#region Page d'accueil (langue et thème enregistrés, voir Cache.ps1) -------------

function Get-IalIndexBytes {
    <# Page d'accueil avec la langue et le thème enregistrés écrits dans <html> : aucun flash au chargement. #>
    param([string]$Path)
    $html = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    $l = $script:IalPrefs.Values.lang; $t = $script:IalPrefs.Values.theme
    $html = ([regex]'<html[^>]*>').Replace($html, "<html lang=""$l"" data-lang=""$l"" data-theme=""$t"">", 1)
    return [System.Text.UTF8Encoding]::new($false).GetBytes($html)
}

#endregion

#region Routes API ------------------------------------------------------------

function Get-IalStatusBody {
    param([System.Collections.IDictionary]$State)
    $idx = $State.Index
    $body = [ordered]@{
        mode            = $State.Mode
        connected       = $true
        phase           = $State.Phase
        message         = $State.Message
        progress        = [ordered]@{ done = $State.Done; total = $State.Total }
        lastSyncAt      = $State.LastSyncAt
        lastFullSyncAt  = $State.LastFullSyncAt
        lastDurationSec = $State.LastDurationSec
        throttledUntil  = $State.ThrottledUntil
        error           = $(if ($State.LastError) { 'La dernière synchronisation a échoué. Consultez le journal local.' } else { $null })
        counts          = $(if ($idx) { $idx.Counts } else { $null })
        uncovered       = $(if ($idx) { @($idx.Uncovered) } else { @() })
        ready           = ($null -ne $idx)
        syncRunning     = [bool]$State.SyncRunning
        lastSyncStats   = $State.LastSyncStats
        dataSource      = $State.DataSource
        cacheEnabled    = [bool]$script:IalCache.Enabled
        cacheSavedAt    = $State.CacheSavedAt
        cspViolations   = [int]$State.CspViolations
        foregroundSync  = [bool]$State.ForegroundSync
        tenantId        = $State.TenantId     # identifiant du tenant (non secret), affiché dans les réglages
    }
    # États simulés pour vérifier l'interface (mode Mock UNIQUEMENT, paramètre -DemoState).
    if ($State.Mode -eq 'Mock' -and $State.Contains('DemoState') -and $State.DemoState) {
        $total = if ($idx) { $idx.Counts.objects } else { 2000 }
        switch ($State.DemoState) {
            'syncing' { $body.phase = 'assignments'; $body.message = 'Lecture des assignations'; $body.progress = [ordered]@{ done = [int]($total * 0.63); total = $total } }
            'throttled' { $body.phase = 'assignments'; $body.progress = [ordered]@{ done = [int]($total * 0.4); total = $total }; $body.throttledUntil = (Get-Date).AddMinutes(5).ToString('o') }
            'error' { $body.phase = 'error'; $body.error = 'La dernière synchronisation a échoué. Consultez le journal local.' }
            'stale' { $body.lastSyncAt = (Get-Date).AddDays(-3).ToString('o'); $body.lastFullSyncAt = $body.lastSyncAt }
        }
    }
    return $body
}

function Read-IalJsonBody {
    <# Lit un petit corps JSON (taille déjà bornée). Retourne $null si absent ou invalide. #>
    param($Request)
    if (-not $Request.HasEntityBody) { return $null }
    $max = $script:IalConfig.MaxRequestBodyBytes
    $buf = [byte[]]::new($max + 1)
    $read = 0
    while ($read -le $max) {
        $n = $Request.InputStream.Read($buf, $read, $buf.Length - $read)
        if ($n -le 0) { break }
        $read += $n
    }
    if ($read -gt $max) { return $null }
    try { return ([System.Text.Encoding]::UTF8.GetString($buf, 0, $read) | ConvertFrom-Json -AsHashtable -ErrorAction Stop) }
    catch { return $null }
}

# Jobs de synchronisation lancés depuis ce runspace : leurs messages sont relayés à la console,
# puis ils sont nettoyés une fois terminés.
$script:IalSyncJobs = [System.Collections.Generic.List[object]]::new()

function Register-IalSyncJob { param($Job) if ($Job) { $script:IalSyncJobs.Add($Job) } }

function Update-IalSyncJobs {
    param([System.Collections.IDictionary]$State)
    foreach ($j in @($script:IalSyncJobs)) {
        try { Receive-Job -Job $j -ErrorAction SilentlyContinue | Out-Null } catch { }
        if ($j.State -in 'Completed', 'Failed', 'Stopped') {
            Remove-Job -Job $j -Force -ErrorAction SilentlyContinue
            $null = $script:IalSyncJobs.Remove($j)
        }
    }
    # Repli V16 : si le runspace d'arrière-plan n'a pas pu s'initialiser (session Graph invisible),
    # bascule définitive en synchronisation au premier plan, puis relance immédiate.
    if ($State -and $State.JobInitFailed -and -not $State.ForegroundSync -and -not $State.SyncRunning) {
        $State.JobInitFailed = $false
        $State.ForegroundSync = $true
        Write-IalLog -Level WARN -Message ((Tx 'La synchronisation en arrière-plan n''a pas pu démarrer ({0}). Repli : synchronisation au premier plan ; l''interface ne répondra pas pendant les synchronisations.' 'The background sync could not start ({0}). Fallback: foreground sync; the interface will not respond during syncs.') -f $State.LastError)
        Invoke-IalSyncForeground -State $State -Mode $State.JobInitFailedMode
    }
}

function Stop-IalSyncJobs {
    <# Arrêt propre : demande d'annulation, attente brève, puis arrêt forcé. #>
    param([System.Collections.IDictionary]$State, [int]$TimeoutSec = 10)
    if ($State) { $State.CancelSync = $true }
    foreach ($j in @($script:IalSyncJobs)) {
        $null = Wait-Job -Job $j -Timeout $TimeoutSec
        if ($j.State -eq 'Running') { Stop-Job -Job $j }
    }
    Update-IalSyncJobs
}

# Appartenances (groupes d'un utilisateur / d'un appareil) lues À LA DEMANDE à l'ouverture d'une fiche,
# gardées en mémoire quelques minutes (jamais sur disque). Vidées quand l'index change (nouvelle synchro).
$script:IalMemberCache = @{ Index = $null; Items = @{} }

function Get-IalCachedMemberships {
    param([System.Collections.IDictionary]$State, $Index, [string]$UserId, [string[]]$DeviceAadIds)
    if (-not [object]::ReferenceEquals($script:IalMemberCache.Index, $Index)) {
        $script:IalMemberCache = @{ Index = $Index; Items = @{} }
    }
    $ids = @($DeviceAadIds | Where-Object { $_ } | Sort-Object -Unique)
    $key = '{0}|{1}' -f $UserId, ($ids -join ',')
    $hit = $script:IalMemberCache.Items[$key]
    $ttl = [timespan]::FromMinutes($script:IalConfig.MembershipCacheMin)
    if ($hit -and ([datetime]::UtcNow - $hit.At) -lt $ttl) { return $hit.Value }
    $v = Get-IalMemberships -UserId $UserId -DeviceIds $ids -TokenScopes @($State.TokenScopes)
    if ($script:IalMemberCache.Items.Count -gt 200) { $script:IalMemberCache.Items.Clear() }
    $script:IalMemberCache.Items[$key] = @{ At = [datetime]::UtcNow; Value = $v }
    return $v
}

function Get-IalQueryValue {
    param($Request, [string]$Name)
    $v = $Request.QueryString[$Name]
    if ($null -eq $v) { return '' }
    return [string]$v
}

function Invoke-IalApiRoute {
    param($Context, $Server, [System.Collections.IDictionary]$State, [string]$Path, [string]$Method)
    $req = $Context.Request

    if ($Path -eq '/api/status') {
        if ($Method -ne 'GET') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        return Send-IalJson -Context $Context -Body (Get-IalStatusBody -State $State)
    }
    if ($Path -eq '/api/shutdown') {
        if ($Method -ne 'POST') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        $State.StopRequested = $true
        return Send-IalJson -Context $Context -Body ([ordered]@{ ok = $true; message = 'Arrêt en cours.' })
    }
    if ($Path -eq '/api/refresh') {
        # Action LOCALE : relance une lecture (GET) de Graph ; ne modifie rien dans le tenant.
        if ($Method -ne 'POST') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        $body = Read-IalJsonBody -Request $req
        $mode = if ($body -is [System.Collections.IDictionary] -and $body['mode']) { [string]$body['mode'] } else { 'incremental' }
        if ($mode -notin 'incremental', 'full') { return Send-IalError $Context 400 'Mode de synchronisation invalide.' }
        if ($State.SyncRunning) { return Send-IalError $Context 409 'Une synchronisation est déjà en cours.' }
        if ($State.ForegroundSync) {
            # Repli V16 : on répond d'abord, puis la synchro bloque ce runspace jusqu'à la fin.
            $msg = 'Synchronisation lancée (mode premier plan : l''interface ne répondra pas jusqu''à la fin).'
            Send-IalJson -Context $Context -Status 202 -Body ([ordered]@{ ok = $true; message = $msg })
            Invoke-IalSyncForeground -State $State -Mode $mode
            return
        }
        $job = Start-IalSyncJob -State $State -Root $State.Root -Mode $mode
        if (-not $job) { return Send-IalError $Context 409 'Une synchronisation est déjà en cours.' }
        Register-IalSyncJob $job
        $msg = if ($mode -eq 'full') { 'Synchronisation complète lancée.' } else { 'Synchronisation incrémentale lancée.' }
        return Send-IalJson -Context $Context -Status 202 -Body ([ordered]@{ ok = $true; message = $msg })
    }
    if ($Path -eq '/api/prefs') {
        if ($Method -ne 'POST') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        $body = Read-IalJsonBody -Request $req
        $v = if ($body -is [System.Collections.IDictionary]) { Set-IalPrefs -Changes $body } else { $null }
        if (-not $v) { return Send-IalError $Context 400 'Paramètres invalides.' }
        return Send-IalJson -Context $Context -Body ([ordered]@{ ok = $true; prefs = $v })
    }
    if ($Path -eq '/api/cache/clear') {
        if ($Method -ne 'POST') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        $n = Clear-IalCache
        $State.CacheSavedAt = $null
        $msg = if ($n -gt 0) { 'Cache local effacé. Les données restent affichées jusqu''à l''arrêt de l''outil.' } else { 'Aucun cache local à effacer.' }
        return Send-IalJson -Context $Context -Body ([ordered]@{ ok = $true; message = $msg })
    }

    if ($Method -ne 'GET') { return Send-IalError $Context 405 'Méthode non autorisée.' }
    $idx = $State.Index   # lecture de la référence courante (l'index est immuable)
    if (-not $idx) { return Send-IalError $Context 503 'Données en cours de chargement.' }

    if ($Path -eq '/api/search') {
        $q = Get-IalQueryValue $req 'q'
        if ($q.Length -gt 200) { return Send-IalError $Context 400 'Recherche trop longue.' }
        $kind = Get-IalQueryValue $req 'kind'
        if (-not $kind) { $kind = 'group' }
        if ($kind -notin 'group', 'object', 'user', 'device') { return Send-IalError $Context 400 'Paramètre kind invalide.' }
        $limit = $script:IalConfig.SearchDefaultLimit
        $ls = Get-IalQueryValue $req 'limit'
        if ($ls) {
            $n = 0
            if (-not [int]::TryParse($ls, [ref]$n) -or $n -lt 1) { return Send-IalError $Context 400 'Paramètre limit invalide.' }
            $limit = [math]::Min($n, $script:IalConfig.SearchMaxLimit)
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $res = Search-IalIndex -Index $idx -Query $q -Kind $kind -Limit $limit
        $res['elapsedMs'] = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
        return Send-IalJson -Context $Context -Body $res
    }

    $m = [regex]::Match($Path, '^/api/(?<kind>user|device)/(?<id>[A-Za-z0-9_\-]{1,128})$')
    if ($m.Success) {
        $id = $m.Groups['id'].Value
        try {
            if ($m.Groups['kind'].Value -eq 'user') {
                $u = $null
                if (-not $idx.UserById.TryGetValue($id, [ref]$u)) { return Send-IalError $Context 404 'Utilisateur introuvable.' }
                $aad = @($u.deviceIds | ForEach-Object { $idx.DeviceById[$_]['aadId'] })
                $mem = Get-IalCachedMemberships -State $State -Index $idx -UserId $u.id -DeviceAadIds $aad
                $v = Get-IalUserView -Index $idx -UserId $id -Memberships $mem
            }
            else {
                $d = $null
                if (-not $idx.DeviceById.TryGetValue($id, [ref]$d)) { return Send-IalError $Context 404 'Machine introuvable.' }
                $uid = if ($d['userId'] -and $idx.UserById.ContainsKey([string]$d['userId'])) { [string]$d['userId'] } else { '' }
                $mem = Get-IalCachedMemberships -State $State -Index $idx -UserId $uid -DeviceAadIds @($d['aadId'])
                $v = Get-IalDeviceView -Index $idx -DeviceId $id -Memberships $mem
            }
        }
        catch {
            # Graph injoignable, limité, etc. : la fiche n'est pas affichable, l'outil continue.
            Write-IalLog -Level WARN -Message (Tx "Lecture des appartenances impossible : $($_.Exception.Message)" "Cannot read memberships: $($_.Exception.Message)")
            $st = [int]$_.Exception.Data['IalStatus']
            $msg = if ($st -eq 429) { 'Microsoft Graph limite les requêtes : réessayez dans un instant.' } else { 'Lecture des groupes impossible pour le moment. Consultez le journal local.' }
            return Send-IalError $Context 502 $msg
        }
        return Send-IalJson -Context $Context -Body $v
    }

    $m = [regex]::Match($Path, '^/api/(?<kind>group|object)/(?<id>[A-Za-z0-9_\-]{1,128})$')
    if ($m.Success) {
        $id = $m.Groups['id'].Value
        if ($m.Groups['kind'].Value -eq 'group') {
            $v = Get-IalGroupView -Index $idx -GroupId $id
            if (-not $v) { return Send-IalError $Context 404 'Groupe introuvable.' }
        }
        else {
            $v = Get-IalObjectView -Index $idx -ObjectId $id
            if (-not $v) { return Send-IalError $Context 404 'Élément introuvable.' }
        }
        return Send-IalJson -Context $Context -Body $v
    }
    return Send-IalError $Context 404 'Route inconnue.'
}

#endregion

#region Traitement d'une requête -----------------------------------------------

function Invoke-IalRequest {
    param($Context, $Server, [System.Collections.IDictionary]$State)
    $req = $Context.Request
    $method = $req.HttpMethod.ToUpperInvariant()

    # 1. Host (protection DNS rebinding)
    $hostHeader = [string]$req.Headers['Host']
    if (-not [string]::Equals($hostHeader, $Server.Host, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Send-IalError $Context 403 'Hôte refusé.'
    }
    # 2. Origin (si présent) et Sec-Fetch-Site
    $origin = [string]$req.Headers['Origin']
    if ($origin -and -not [string]::Equals($origin, $Server.Origin, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Send-IalError $Context 403 'Origine refusée.'
    }
    $sfs = [string]$req.Headers['Sec-Fetch-Site']
    if ($sfs -and $sfs -notin 'same-origin', 'none') {
        return Send-IalError $Context 403 'Requête inter-sites refusée.'
    }
    # 3. Chemin brut : refus des séquences de traversée, encodées ou non
    $raw = [string]$req.RawUrl
    $rawPath = ($raw -split '\?', 2)[0]
    if ($rawPath -match '\.\.|\\|%2e|%2f|%5c|%00|//' -or -not $rawPath.StartsWith('/')) {
        return Send-IalError $Context 400 'Chemin refusé.'
    }
    $path = $req.Url.AbsolutePath

    # 4. Rapport de violation CSP envoyé par le navigateur (sans jeton : le navigateur ne peut pas en ajouter).
    #    Ne fait que journaliser, en nombre limité ; aucune donnée n'est renvoyée.
    if ($path -eq '/csp-report') {
        if ($method -ne 'POST') { return Send-IalError $Context 405 'Méthode non autorisée.' }
        if ($req.ContentLength64 -gt $script:IalConfig.MaxRequestBodyBytes) { return Send-IalError $Context 413 'Requête trop volumineuse.' }
        $body = Read-IalJsonBody -Request $req
        $rep = if ($body -is [System.Collections.IDictionary] -and $body['csp-report'] -is [System.Collections.IDictionary]) { $body['csp-report'] } else { $null }
        if ($rep) {
            $clean = { param($v) ([string]$v -replace '[\r\n\t]', ' ').Substring(0, [math]::Min(200, ([string]$v).Length)) }
            $directive = & $clean $(if ($rep['effective-directive']) { $rep['effective-directive'] } else { $rep['violated-directive'] })
            $blocked = & $clean $rep['blocked-uri']
            $State.CspViolations++
            if ($State.CspViolations -le $script:IalCspMaxLogged) {
                Write-IalLog -Level WARN -Message (Tx "CSP : ressource bloquée par « $directive » ($blocked)." "CSP: resource blocked by '$directive' ($blocked).")
            }
        }
        $Context.Response.StatusCode = 204
        Set-IalSecurityHeaders -Response $Context.Response -Api
        $Context.Response.OutputStream.Close()
        return
    }

    # 5. API : jeton de session obligatoire
    if ($path.StartsWith('/api/', [System.StringComparison]::Ordinal)) {
        if (-not (Test-IalTokenEqual -Expected $Server.Token -Actual ([string]$req.Headers['X-Session']))) {
            return Send-IalError $Context 401 'Session invalide. Relancez l''outil.'
        }
        if ($req.HasEntityBody -and $req.ContentLength64 -gt $script:IalConfig.MaxRequestBodyBytes) {
            return Send-IalError $Context 413 'Requête trop volumineuse.'
        }
        return Invoke-IalApiRoute -Context $Context -Server $Server -State $State -Path $path -Method $method
    }

    # 6. Fichiers statiques : liste blanche uniquement
    if ($method -notin 'GET', 'HEAD') { return Send-IalError $Context 405 'Méthode non autorisée.' }
    $file = $null
    if (-not $Server.Whitelist.TryGetValue($path, [ref]$file)) {
        return Send-IalError $Context 404 'Introuvable.'
    }
    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
    $bytes = if ($path -eq '/') { Get-IalIndexBytes -Path $file } else { [System.IO.File]::ReadAllBytes($file) }
    Send-IalBytes -Context $Context -Status 200 -ContentType $script:IalContentTypes[$ext] -Bytes $bytes
}

function Invoke-IalServerLoop {
    <# Boucle principale. S'arrête quand $State.StopRequested passe à $true (route /api/shutdown ou Ctrl+C). #>
    param($Server, [System.Collections.IDictionary]$State)
    $listener = $Server.Listener
    while (-not $State.StopRequested -and $listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(250)) {
            if ($State.StopRequested -or -not $listener.IsListening) { return }
            Update-IalSyncJobs -State $State
        }
        $ctx = $task.Result
        try {
            Invoke-IalRequest -Context $ctx -Server $Server -State $State
        }
        catch {
            Write-IalLog -Level ERROR -Message (Tx "Erreur de traitement d'une requête : $($_.Exception.Message)" "Error while handling a request: $($_.Exception.Message)")
            try { Send-IalError $ctx 500 'Erreur interne. Consultez le journal local.' } catch { }
        }
        finally {
            try { $ctx.Response.Close() } catch { }
        }
    }
}

#endregion
