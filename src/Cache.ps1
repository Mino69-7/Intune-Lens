# Cache.ps1 : lecture / écriture du cache disque (spec 5.6).
#
#  - Emplacement : %LOCALAPPDATA%\IntuneAssignLens\cache\ (jamais Documents, Bureau, OneDrive).
#  - Un fichier par mode (réel / Mock) : les données fictives ne se mélangent jamais aux vraies.
#  - Contenu : JSON compressé (GZip) puis chiffré par DPAPI, portée « utilisateur courant ».
#  - Dossier protégé par une ACL limitée à l'utilisateur courant (héritage coupé).
#  - Écriture atomique : fichier temporaire, vidage sur disque, puis renommage avec remplacement.
#  - Version de schéma : si elle ne correspond pas, le cache est ignoré (resynchronisation).
#  - Ne contient JAMAIS de jeton.

Set-StrictMode -Version 3.0

$script:IalCache = @{
    Directory = $null
    Enabled   = $false
    # Point d'injection pour les tests : exécuté entre l'écriture du fichier temporaire et le renommage.
    BeforeCommit = $null
}

function Initialize-IalCache {
    [CmdletBinding()]
    param(
        [string]$Directory = (Join-Path $env:LOCALAPPDATA "$($script:IalConfig.AppName)\cache"),
        [switch]$Disabled
    )
    $script:IalCache.Directory = $Directory
    $script:IalCache.Enabled = -not $Disabled
}

function Get-IalCachePath {
    param([ValidateSet('Real', 'Mock')][string]$Mode)
    Join-Path $script:IalCache.Directory ("cache-{0}.dat" -f $Mode.ToLowerInvariant())
}

function Protect-IalCacheDirectory {
    <# Crée le dossier si besoin et limite son ACL à l'utilisateur courant (sans héritage). #>
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -ItemType Directory -Path $Path -Force }
    try {
        # Seule la DACL (droits d'accès) est écrite : ni propriétaire ni audit (SACL), qui exigeraient
        # des privilèges. Aucune élévation n'est nécessaire.
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl = [System.Security.AccessControl.DirectorySecurity]::new()
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        $rule = [System.Security.AccessControl.FileSystemAccessRule]::new($me, 'FullControl', $inherit, 'None', 'Allow')
        $acl.AddAccessRule($rule)
        [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($Path), $acl)
    }
    catch {
        Write-IalLog -Level WARN -Message "ACL du dossier de cache non appliquée : $($_.Exception.Message)"
    }
}

function ConvertTo-IalCacheBytes {
    param([Parameter(Mandatory)][string]$Json)
    $raw = [System.Text.UTF8Encoding]::new($false).GetBytes($Json)
    $ms = [System.IO.MemoryStream]::new()
    $gz = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionLevel]::Fastest)
    $gz.Write($raw, 0, $raw.Length)
    $gz.Dispose()
    $packed = $ms.ToArray()
    return [System.Security.Cryptography.ProtectedData]::Protect($packed, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
}

function ConvertFrom-IalCacheBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $packed = [System.Security.Cryptography.ProtectedData]::Unprotect($Bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    $in = [System.IO.MemoryStream]::new($packed)
    $gz = [System.IO.Compression.GZipStream]::new($in, [System.IO.Compression.CompressionMode]::Decompress)
    $out = [System.IO.MemoryStream]::new()
    $gz.CopyTo($out)
    $gz.Dispose()
    return [System.Text.UTF8Encoding]::new($false).GetString($out.ToArray())
}

function Save-IalCache {
    <#
        Écrit l'instantané de données. Atomique : en cas d'arrêt brutal, l'ancien fichier reste intact.
        .PARAMETER Data   jeu de données (Groups, Filters, Objects, Uncovered, dates)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Real', 'Mock')][string]$Mode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Data,
        [string]$TenantId
    )
    if (-not $script:IalCache.Enabled) { return $false }
    $dir = $script:IalCache.Directory
    Protect-IalCacheDirectory -Path $dir
    $target = Get-IalCachePath -Mode $Mode
    $tmp = "$target.$([guid]::NewGuid().ToString('N')).tmp"

    $payload = [ordered]@{
        schema         = $script:IalConfig.SchemaVersion
        app            = $script:IalConfig.AppName
        mode           = $Mode
        tenantId       = $TenantId
        savedAt        = (Get-Date).ToUniversalTime().ToString('o')
        lastSyncAt     = $Data.LastSyncAt
        lastFullSyncAt = $Data.LastFullSyncAt
        familySyncAt   = $Data.FamilySyncAt
        groups         = @($Data.Groups)
        filters        = $Data.Filters
        uncovered      = @($Data.Uncovered)
        objects        = @($Data.Objects.Values)
        devices        = $(if ($Data.Contains('Devices') -and $Data.Devices) { @($Data.Devices) } else { @() })
    }
    $json = ConvertTo-Json -InputObject $payload -Depth 8 -Compress
    $bytes = ConvertTo-IalCacheBytes -Json $json
    try {
        $fs = [System.IO.FileStream]::new($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)    # vidage jusqu'au disque avant le renommage
        }
        finally { $fs.Dispose() }
        if ($script:IalCache.BeforeCommit) { & $script:IalCache.BeforeCommit $tmp }
        [System.IO.File]::Move($tmp, $target, $true)
        Write-IalLog -Level INFO -Message ("Cache enregistré ({0:N0} Ko, chiffré DPAPI)." -f ($bytes.Length / 1KB))
        return $true
    }
    catch {
        Write-IalLog -Level WARN -Message "Cache non enregistré : $($_.Exception.Message)"
        return $false
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Read-IalCache {
    <#
        Lit le cache. Retourne le jeu de données, ou $null si absent, illisible, corrompu,
        d'une autre version de schéma, d'un autre mode ou d'un autre tenant. Ne lève jamais d'exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Real', 'Mock')][string]$Mode,
        [string]$TenantId
    )
    if (-not $script:IalCache.Enabled) { return $null }
    $path = Get-IalCachePath -Mode $Mode
    # Fichiers temporaires orphelins (arrêt brutal pendant une écriture) : nettoyés.
    if (Test-Path -LiteralPath $script:IalCache.Directory) {
        Get-ChildItem -LiteralPath $script:IalCache.Directory -Filter '*.tmp' -File -ErrorAction SilentlyContinue |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $json = ConvertFrom-IalCacheBytes -Bytes ([System.IO.File]::ReadAllBytes($path))
        $c = $json | ConvertFrom-Json -AsHashtable -DateKind String -ErrorAction Stop
    }
    catch {
        Write-IalLog -Level WARN -Message 'Cache illisible ou corrompu : ignoré, une synchronisation complète va suivre.'
        return $null
    }
    if ($c -isnot [System.Collections.IDictionary] -or $c['schema'] -ne $script:IalConfig.SchemaVersion -or $c['app'] -ne $script:IalConfig.AppName) {
        Write-IalLog -Level WARN -Message 'Cache d''une autre version : ignoré.'
        return $null
    }
    if ($c['mode'] -ne $Mode -or ($TenantId -and $c['tenantId'] -and $c['tenantId'] -ne $TenantId)) {
        Write-IalLog -Level WARN -Message 'Cache d''un autre mode ou d''un autre tenant : ignoré.'
        return $null
    }
    try {
        $objects = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($o in @($c['objects'])) {
            if ($o -is [System.Collections.IDictionary] -and $o['id']) {
                $o['lastModified'] = ConvertTo-IalIsoDate $o['lastModified']
                $objects[[string]$o['id']] = $o
            }
        }
        $filters = @{}
        if ($c['filters'] -is [System.Collections.IDictionary]) { foreach ($k in $c['filters'].Keys) { $filters[$k] = $c['filters'][$k] } }
        $fam = @{}
        if ($c['familySyncAt'] -is [System.Collections.IDictionary]) { foreach ($k in $c['familySyncAt'].Keys) { $fam[$k] = $c['familySyncAt'][$k] } }
        return @{
            Groups         = [System.Collections.Generic.List[object]]@(@($c['groups']) | Where-Object { $_ -is [System.Collections.IDictionary] })
            Filters        = $filters
            Objects        = $objects
            # Absent des caches antérieurs aux fiches Utilisateur / Machine : liste vide jusqu'à la synchro.
            Devices        = [System.Collections.Generic.List[object]]@(@($c['devices']) | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['id'] })
            Uncovered      = @($c['uncovered'])
            LastSyncAt     = [string]$c['lastSyncAt']
            LastFullSyncAt = [string]$c['lastFullSyncAt']
            FamilySyncAt   = $fam
            SavedAt        = [string]$c['savedAt']
        }
    }
    catch {
        Write-IalLog -Level WARN -Message 'Cache incohérent : ignoré.'
        return $null
    }
}

function Clear-IalCache {
    <# Efface les fichiers de cache (tous modes). Retourne le nombre de fichiers supprimés. #>
    $n = 0
    if ($script:IalCache.Directory -and (Test-Path -LiteralPath $script:IalCache.Directory)) {
        foreach ($f in Get-ChildItem -LiteralPath $script:IalCache.Directory -File -Filter 'cache-*' -ErrorAction SilentlyContinue) {
            Remove-Item -LiteralPath $f.FullName -Force
            $n++
        }
    }
    return $n
}
