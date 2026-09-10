$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
停止本機 n8n 容器（含 ngrok，若有啟動）。

不會刪除 data/、映像或 .env。之後再開一次，執行同一支 .\start-n8n.cmd 即可。
若要拆掉環境並清空資料，請改用 .\uninstall-local-n8n.cmd。

用法：
  .\shutdown-n8n.cmd
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        { $_ -in @('-h', '--help', '/?') } {
            Show-Usage
            exit 0
        }
        default {
            Write-Err "未知參數：$arg"
            Show-Usage
            exit 1
        }
    }
}

function Write-Title([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Body([string]$Message) { Write-Host $Message -ForegroundColor White }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-OkLine([string]$Message) { Write-Host $Message -ForegroundColor Green }

function Get-Sanitized([string]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return (($Value -replace '[\r\n]+', '')).Trim()
}

function Get-EnvValue([string]$Key) {
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        return ''
    }
    $lines = [System.IO.File]::ReadAllLines($EnvFile, $Utf8NoBom)
    $raw = ''
    foreach ($line in $lines) {
        if ($line.StartsWith("$Key=") -and -not $line.StartsWith('#')) {
            $raw = $line.Substring($Key.Length + 1)
        }
    }
    $raw = Get-Sanitized $raw
    if ($raw.StartsWith("'") -and $raw.EndsWith("'") -and $raw.Length -ge 2) {
        $raw = $raw.Substring(1, $raw.Length - 2).Replace("'\\''", "'")
    }
    elseif ($raw.StartsWith('"') -and $raw.EndsWith('"') -and $raw.Length -ge 2) {
        $raw = $raw.Substring(1, $raw.Length - 2)
    }
    else {
        $hash = $raw.IndexOf(' #')
        if ($hash -ge 0) {
            $raw = $raw.Substring(0, $hash).TrimEnd()
        }
    }
    return (Get-Sanitized $raw)
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    exit 1
}

Set-Location -LiteralPath $Root

$scenario = (Get-EnvValue 'N8N_SCENARIO').ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($scenario)) {
    $scenario = 'A'
}

$composeArgs = @('compose')
if ($scenario -eq 'C') {
    $composeArgs += @('-f', 'compose.yml', '-f', 'compose.remote-supabase.yml')
}
$composeArgs += @('--profile', 'tunnel', '--profile', 'runners', 'stop')

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  關閉本機 n8n'
Write-Title '════════════════════════════════════════════════════════════'
Write-Host ''
Write-Body "停止容器（場景 $scenario）。資料、映像與 .env 都會保留。"
Write-Muted ("  docker " + ($composeArgs -join ' '))
Write-Host ''

& docker @composeArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host ''
Write-OkLine '────────────────────────────────────────────────────────────'
Write-OkLine '  本機 n8n 已停止。'
Write-OkLine '────────────────────────────────────────────────────────────'
Write-Host ''
Write-Muted '之後再開一次，執行同一支 .\start-n8n.cmd 即可。'
Write-Muted '若要拆掉環境並清空資料，請執行 .\uninstall-local-n8n.cmd'
Write-Host ''
