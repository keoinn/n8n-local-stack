$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
依 .env 的場景與 ngrok 設定啟動本機 n8n，完成後顯示內部與外部網址。

用法：
  .\scripts\start-local-n8n.ps1
  .\scripts\start-local-n8n.cmd
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
    $raw = (($raw -replace '[\r\n]+', '')).Trim()
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
    return $raw.Trim()
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    exit 1
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "找不到 $EnvFile。請先執行 .\scripts\create-envfile.ps1"
    exit 1
}

Set-Location -LiteralPath $Root

$scenario = Get-EnvValue 'N8N_SCENARIO'
$enableNgrok = Get-EnvValue 'ENABLE_NGROK'
$ngrokDomain = Get-EnvValue 'NGROK_DOMAIN'

if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'A' }
$scenario = $scenario.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($enableNgrok)) { $enableNgrok = 'true' }
$enableNgrok = $enableNgrok.ToLowerInvariant()

$composeArgs = @('compose')
if ($scenario -eq 'C') {
    $composeArgs += @('-f', 'compose.yml', '-f', 'compose.remote-supabase.yml')
}
if ($enableNgrok -eq 'true') {
    $composeArgs += @('--profile', 'tunnel', 'up', '-d')
}
elseif ($scenario -eq 'C') {
    $composeArgs += @('up', '-d')
}
else {
    $composeArgs += @('up', '-d', 'postgres', 'n8n')
}

Write-Host "啟動 n8n（場景 $scenario）..." -ForegroundColor White
Write-Host ("  docker " + ($composeArgs -join ' ')) -ForegroundColor DarkGray
Write-Host ''

& docker @composeArgs
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

$internalUrl = 'http://localhost:5678'
$externalUrl = ''
if ($enableNgrok -eq 'true' -and -not [string]::IsNullOrWhiteSpace($ngrokDomain) -and $ngrokDomain -ne 'YOUR_NGROK_DOMAIN') {
    $externalUrl = "https://$ngrokDomain"
}

Write-Host ''
Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host '  n8n 已啟動' -ForegroundColor Cyan
Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host '  內部網址      ' -ForegroundColor White -NoNewline
Write-Host $internalUrl -ForegroundColor Cyan
if ($externalUrl) {
    Write-Host '  外部網址      ' -ForegroundColor White -NoNewline
    Write-Host $externalUrl -ForegroundColor Cyan
    Write-Host '  ngrok 檢查頁  ' -ForegroundColor White -NoNewline
    Write-Host 'http://127.0.0.1:4040' -ForegroundColor Cyan
}
else {
    Write-Host '  外部網址      ' -ForegroundColor White -NoNewline
    Write-Host '未啟用 ngrok，無法使用對外 webhook' -ForegroundColor Yellow
}
Write-Host ''
Write-Host '請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。' -ForegroundColor Green
