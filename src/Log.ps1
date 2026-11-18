# Log.ps1 : journal local lisible, en clair.
# Ne jamais journaliser de jeton (session locale ou Graph) ni de corps de réponse.

Set-StrictMode -Version 3.0

$script:IalLog = @{
    FilePath = $null      # défini par Initialize-IalLog ; $null = console seulement
    Quiet    = $false     # $true = rien à la console (tests)
    Lock     = [object]::new()
}

function Initialize-IalLog {
    [CmdletBinding()]
    param(
        [string]$Directory,
        [switch]$Quiet
    )
    $script:IalLog.Quiet = [bool]$Quiet
    if ($Directory) {
        if (-not (Test-Path -LiteralPath $Directory)) {
            $null = New-Item -ItemType Directory -Path $Directory -Force
        }
        $script:IalLog.FilePath = Join-Path $Directory ('ial-{0:yyyyMMdd}.log' -f (Get-Date))
    }
}

function Write-IalLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level,
        [Parameter(Mandatory)][string]$Message
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    if (-not $script:IalLog.Quiet -and $Level -ne 'DEBUG') {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } default { 'Gray' } }
        Write-Host $line -ForegroundColor $color
    }
    if ($script:IalLog.FilePath) {
        [System.Threading.Monitor]::Enter($script:IalLog.Lock)
        try { Add-Content -LiteralPath $script:IalLog.FilePath -Value $line -Encoding utf8 }
        catch { }  # le journal ne doit jamais faire tomber l'outil
        finally { [System.Threading.Monitor]::Exit($script:IalLog.Lock) }
    }
}
