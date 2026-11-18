# Sync.ps1 : synchronisation complète et incrémentale (spec 5.6), exécution en arrière-plan.
#
# Modèle « Data » (instantané complet, aussi écrit dans le cache) :
#   @{ Groups = liste @{id;displayName}; Filters = @{id -> @{id;name;platform}};
#      Objects = Dictionary id -> objet normalisé (avec assignations); Uncovered = liste;
#      LastSyncAt; LastFullSyncAt; FamilySyncAt = @{typeKey -> date} }
#
# Un seul écrivain : la synchronisation construit un NOUVEAU Data et un NOUVEL index,
# puis échange les références dans l'état partagé (lecteurs jamais bloqués).

Set-StrictMode -Version 3.0

function New-IalAppState {
    <# État partagé, synchronisé : plusieurs lecteurs (serveur), un seul écrivain (synchro). #>
    param([ValidateSet('Real', 'Mock')][string]$Mode)
    $s = [hashtable]::Synchronized(@{})
    $s.Mode = $Mode
    $s.TenantId = $null
    # Scopes présents dans le jeton (réel : Get-MgContext ; Mock : simulés) et types optionnels activés
    # explicitement par l'utilisateur. Servent UNIQUEMENT à décider quoi lire : rien n'est demandé.
    $s.TokenScopes = @($script:IalConfig.Scopes)
    $s.EnabledOptionalTypes = @()
    $s.Index = $null
    $s.Data = $null
    $s.DataSource = $null      # 'cache' | 'sync'
    $s.Phase = 'idle'          # idle | groups | lists | assignments | indexing | saving | done | error
    $s.Done = 0
    $s.Total = 0
    $s.Message = ''
    $s.StartedAt = $null
    $s.LastSyncAt = $null
    $s.LastFullSyncAt = $null
    $s.LastDurationSec = $null
    $s.LastSyncStats = $null
    $s.LastError = $null
    $s.ThrottledUntil = $null
    $s.SyncRunning = $false
    $s.CancelSync = $false
    $s.StopRequested = $false
    $s.CacheSavedAt = $null
    $s.CspViolations = 0
    $s.ForegroundSync = $false     # repli V16 : synchro dans le runspace principal
    $s.JobInitFailed = $false
    $s.JobInitFailedMode = 'incremental'
    $s.SimulateJobInitFailure = $false
    $s.Lock = [object]::new()
    return $s
}

function Set-IalStateData {
    <# Construit l'index d'un jeu de données et l'installe dans l'état (échange atomique). #>
    param([System.Collections.IDictionary]$State, [System.Collections.IDictionary]$Data, [string]$Source)
    $index = New-IalIndex -Data @{
        Groups = $Data.Groups; Filters = $Data.Filters; Objects = @($Data.Objects.Values)
        Devices = $(if ($Data.Contains('Devices') -and $Data.Devices) { @($Data.Devices) } else { @() })
        Uncovered = $Data.Uncovered; SyncedAt = $Data.LastSyncAt
    }
    $State.Data = $Data
    $State.Index = $index           # échange de référence : les lecteurs voient l'ancien OU le nouveau
    $State.LastSyncAt = $Data.LastSyncAt
    $State.LastFullSyncAt = $Data.LastFullSyncAt
    $State.DataSource = $Source
    return $index
}

function Assert-IalSyncNotCancelled {
    param([System.Collections.IDictionary]$State)
    if ($State.CancelSync -or $State.StopRequested) {
        throw [System.OperationCanceledException]::new('Synchronisation annulée.')
    }
}

function Test-IalFullResyncDue {
    param([System.Collections.IDictionary]$Data)
    if (-not $Data -or -not $Data.LastFullSyncAt) { return $true }
    $d = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$Data.LastFullSyncAt, [ref]$d)) { return $true }
    return ([datetimeoffset]::Now - $d).TotalDays -ge $script:IalConfig.FullResyncAfterDays
}

function Invoke-IalSync {
    <#
        Synchronisation (appel synchrone ; voir Start-IalSyncJob pour l'arrière-plan).
        .PARAMETER Mode
          incremental : relit les listes légères ; assignations des seuls objets nouveaux/modifiés.
          full        : relit toutes les assignations.
        Une synchro incrémentale devient complète s'il n'y a pas de données ou si la dernière synchro
        complète date de plus de FullResyncAfterDays jours.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [ValidateSet('incremental', 'full')][string]$Mode = 'incremental'
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $prev = $State.Data
    $reason = ''
    if ($Mode -eq 'incremental' -and -not $prev) { $Mode = 'full'; $reason = ' (aucune donnée existante)' }
    elseif ($Mode -eq 'incremental' -and (Test-IalFullResyncDue -Data $prev)) { $Mode = 'full'; $reason = " (dernière synchro complète de plus de $($script:IalConfig.FullResyncAfterDays) jour(s))" }

    $State.StartedAt = (Get-Date).ToString('o')
    $State.LastError = $null
    $State.Done = 0; $State.Total = 0
    $script:IalGraph.Status = $State
    $req0 = $script:IalGraph.Stats.Requests
    Write-IalLog -Level INFO -Message "Synchronisation $(if ($Mode -eq 'full') { 'complète' } else { 'incrémentale' })$reason : début."

    try {
        # 1. Groupes et filtres (listes légères, relues entièrement)
        $State.Phase = 'groups'; $State.Message = 'Lecture des groupes'
        $groups = Get-IalGroups
        Assert-IalSyncNotCancelled $State
        $filters = @{}
        try { $filters = Get-IalFilters }
        catch {
            Write-IalLog -Level WARN -Message "Filtres d'assignation illisibles : $($_.Exception.Message)"
            if ($prev) { $filters = $prev.Filters }
        }

        # 2. Listes légères et comparaison avec l'existant
        $State.Phase = 'lists'; $State.Message = 'Lecture des listes'
        $now = (Get-Date).ToUniversalTime().ToString('o')
        $uncovered = [System.Collections.Generic.List[object]]::new()

        # Appareils gérés (fiches Utilisateur / Machine) : liste légère relue entièrement à chaque synchro.
        # Un échec ici n'interrompt pas la synchro : les données précédentes sont gardées.
        $devices = if ($prev -and $prev.Contains('Devices') -and $prev.Devices) { $prev.Devices } else { [System.Collections.Generic.List[object]]::new() }
        try { $devices = Get-IalManagedDevices }
        catch {
            if ($_.Exception.Data['IalKind'] -eq 'Forbidden') {
                $devices = [System.Collections.Generic.List[object]]::new()
                $uncovered.Add([ordered]@{ key = 'managedDevices'; family = 'Appareils (fiches Utilisateur / Machine)'; reason = 'Accès refusé par Graph (403)' })
                Write-IalLog -Level WARN -Message 'Appareils : accès refusé (403), fiches Utilisateur / Machine indisponibles.'
            }
            else { Write-IalLog -Level WARN -Message "Appareils illisibles : $($_.Exception.Message) (données précédentes conservées)." }
        }
        Assert-IalSyncNotCancelled $State
        $familySyncAt = @{}
        if ($prev -and $prev.FamilySyncAt) { foreach ($k in $prev.FamilySyncAt.Keys) { $familySyncAt[$k] = $prev.FamilySyncAt[$k] } }
        $plan = [System.Collections.Generic.List[object]]::new()   # @{ Type; List; ToRead }
        $stats = [ordered]@{ mode = $Mode; added = 0; changed = 0; deleted = 0; unchanged = 0; assignmentsRead = 0; requests = 0; durationSec = 0 }
        $prevObjs = if ($prev) { $prev.Objects } else { $null }
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $rereadAlways = @($script:IalConfig.AssignmentRereadTypes)

        foreach ($t in $script:IalObjectTypes) {
            Assert-IalSyncNotCancelled $State
            $cov = Get-IalTypeCoverage -Type $t -TokenScopes @($State.TokenScopes) -EnabledOptionalTypes @($State.EnabledOptionalTypes)
            if (-not $cov.Covered) {
                $uncovered.Add([ordered]@{ key = $t.Key; family = $t.Family; reason = $cov.Reason })
                continue
            }
            try { $list = Get-IalObjectList -Type $t }
            catch {
                if ($_.Exception.Data['IalKind'] -eq 'Forbidden') {
                    $uncovered.Add([ordered]@{ key = $t.Key; family = $t.Family; reason = 'Accès refusé par Graph (403)' })
                    Write-IalLog -Level WARN -Message "Type $($t.Key) : accès refusé (403), marqué non couvert."
                    continue
                }
                throw
            }
            $toRead = [System.Collections.Generic.List[string]]::new()
            foreach ($o in $list) {
                $null = $seen.Add($o.id)
                $old = $null
                $has = $prevObjs -and $prevObjs.TryGetValue($o.id, [ref]$old)
                if (-not $has) { $stats.added++; $toRead.Add($o.id); continue }
                $modified = [string]$old['lastModified'] -ne [string]$o.lastModified
                if ($modified) { $stats.changed++ } else { $stats.unchanged++ }
                if ($Mode -eq 'full' -or $modified -or $null -eq $old['assignments'] -or $t.Key -in $rereadAlways) {
                    $toRead.Add($o.id)
                }
                else {
                    $o.assignments = $old['assignments']    # inchangé : on garde les assignations connues
                }
            }
            $plan.Add(@{ Type = $t; List = $list; ToRead = $toRead })
            $familySyncAt[$t.Key] = $now
        }
        if ($prevObjs) {
            foreach ($id in $prevObjs.Keys) { if (-not $seen.Contains($id)) { $stats.deleted++ } }
        }

        # 3. Assignations des seuls objets à relire (lots $batch de 20)
        $State.Phase = 'assignments'; $State.Message = 'Lecture des assignations'
        $State.Done = 0
        $State.Total = 0
        foreach ($p in $plan) { $State.Total += $p.ToRead.Count }
        $objects = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($p in $plan) {
            Assert-IalSyncNotCancelled $State
            $assign = Get-IalAssignments -Type $p.Type -ObjectIds ([string[]]@($p.ToRead)) -OnProgress {
                param($n)
                $State.Done += $n
                Assert-IalSyncNotCancelled $State
            }
            foreach ($o in $p.List) {
                if ($assign.ContainsKey($o.id)) { $o.assignments = $assign[$o.id]; $stats.assignmentsRead++ }
                $objects[$o.id] = $o
            }
        }

        # 4. Nouvel index, échange atomique
        $State.Phase = 'indexing'; $State.Message = "Construction de l'index"
        $data = @{
            Groups         = $groups
            Filters        = $filters
            Objects        = $objects
            Devices        = $devices
            Uncovered      = $uncovered
            LastSyncAt     = $now
            LastFullSyncAt = $(if ($Mode -eq 'full') { $now } elseif ($prev) { $prev.LastFullSyncAt } else { $now })
            FamilySyncAt   = $familySyncAt
        }
        $index = Set-IalStateData -State $State -Data $data -Source 'sync'

        # 5. Cache disque (atomique)
        $State.Phase = 'saving'; $State.Message = 'Enregistrement du cache'
        if (Save-IalCache -Mode $State.Mode -Data $data -TenantId $State.TenantId) { $State.CacheSavedAt = (Get-Date).ToString('o') }

        $stats.requests = $script:IalGraph.Stats.Requests - $req0
        $stats.durationSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $State.LastSyncStats = $stats
        $State.LastDurationSec = $stats.durationSec
        $State.Phase = 'done'; $State.Message = ''
        Write-IalLog -Level INFO -Message ("Synchronisation {0} terminée en {1} s : {2:N0} groupes, {3:N0} objets, {9:N0} appareils ({4} nouveaux, {5} modifiés, {6} supprimés), {7} assignations relues, {8} requêtes." -f `
                $(if ($Mode -eq 'full') { 'complète' } else { 'incrémentale' }), $stats.durationSec, $index.Counts.groups, $index.Counts.objects,
            $stats.added, $stats.changed, $stats.deleted, $stats.assignmentsRead, $stats.requests, $index.Counts.devices)
    }
    catch [System.OperationCanceledException] {
        $State.Phase = if ($State.Index) { 'done' } else { 'idle' }
        $State.Message = ''
        Write-IalLog -Level WARN -Message 'Synchronisation annulée ; les données précédentes restent affichées.'
    }
    catch {
        $State.Phase = 'error'
        $State.LastError = $_.Exception.Message
        Write-IalLog -Level ERROR -Message "Synchronisation interrompue : $($_.Exception.Message)"
        throw
    }
    finally {
        $State.ThrottledUntil = $null
    }
}

function Invoke-IalSyncFull {
    <# Raccourci : synchronisation complète, synchrone. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    Invoke-IalSync -State $State -Mode full
}

function Start-IalSyncJob {
    <#
        Lance la synchronisation dans un ThreadJob (l'interface reste réactive).
        Retourne le job, ou $null si une synchronisation est déjà en cours.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][string]$Root,
        [ValidateSet('incremental', 'full')][string]$Mode = 'incremental'
    )
    [System.Threading.Monitor]::Enter($State.Lock)
    try {
        if ($State.SyncRunning) { return $null }
        $State.SyncRunning = $true
    }
    finally { [System.Threading.Monitor]::Exit($State.Lock) }
    $State.CancelSync = $false
    $State.Phase = 'groups'; $State.Done = 0; $State.Total = 0

    $settings = @{
        LogDir     = $(if ($script:IalLog.FilePath) { Split-Path $script:IalLog.FilePath -Parent } else { $null })
        CacheDir   = $script:IalCache.Directory
        CacheOn    = $script:IalCache.Enabled
        FixtureDir = $script:IalMock.FixturesDir
        Dataset    = $script:IalMock.Dataset
        Faults     = $script:IalMock.Faults
    }
    return Start-ThreadJob -Name 'IalSync' -ArgumentList $Root, $State, $Mode, $settings -ScriptBlock {
        param($root, $state, $mode, $settings)
        $ErrorActionPreference = 'Stop'
        foreach ($f in 'Config', 'Log', 'GraphClient', 'Collectors', 'Index', 'Cache', 'Sync') { . (Join-Path $root "src\$f.ps1") }
        try {
            if ($settings.LogDir) { Initialize-IalLog -Directory $settings.LogDir } else { Initialize-IalLog }
            Initialize-IalCache -Directory $settings.CacheDir -Disabled:(-not $settings.CacheOn)
            try {
                if ($state.Contains('SimulateJobInitFailure') -and $state.SimulateJobInitFailure) {
                    throw 'Aucune connexion Graph active dans ce processus. (simulé)'
                }
                if ($state.Mode -eq 'Mock') {
                    Initialize-IalGraphMock -FixturesDir $settings.FixtureDir -Dataset $settings.Dataset
                    if ($settings.Faults) { $script:IalMock.Faults = $settings.Faults }
                }
                else { Initialize-IalGraphReal }
            }
            catch {
                # Initialisation impossible dans ce runspace (point V16) : le serveur basculera au premier plan.
                $state.JobInitFailed = $true
                $state.JobInitFailedMode = $mode
                $state.LastError = $_.Exception.Message
                throw
            }
            Invoke-IalSync -State $state -Mode $mode
        }
        finally { $state.SyncRunning = $false }
    }
}

function Invoke-IalSyncForeground {
    <#
        Synchronisation dans le runspace PRINCIPAL (repli V16) : le serveur ne répond pas pendant la
        synchro, mais la session Graph du processus est forcément visible. Ne lève jamais d'exception.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [ValidateSet('incremental', 'full')][string]$Mode = 'incremental'
    )
    [System.Threading.Monitor]::Enter($State.Lock)
    try {
        if ($State.SyncRunning) { return }
        $State.SyncRunning = $true
    }
    finally { [System.Threading.Monitor]::Exit($State.Lock) }
    $State.CancelSync = $false
    try { Invoke-IalSync -State $State -Mode $Mode }
    catch { }    # déjà journalisé par Invoke-IalSync ; l'état passe en « error »
    finally { $State.SyncRunning = $false }
}
