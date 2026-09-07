$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$StatusFile = Join-Path $Root 'data\.ngrok-status'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
服務啟動後，透過 Docker 日誌檢查 ngrok 固定網域是否已被其他設備佔用。
若被佔用，會停止本機 ngrok 容器（n8n / Postgres 不受影響）。

用法：
  .\scripts\check-ngrok-service.cmd
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        { $_ -in @('-h', '--help', '/?') } {
            Show-Usage
            Exit-N8nScript 0
        }
        default {
            Write-Err "未知參數：$arg"
            Show-Usage
            Exit-N8nScript 1
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

function Write-Status([string]$Value) {
    $dir = Join-Path $Root 'data'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [System.IO.File]::WriteAllText($StatusFile, ($Value + "`n"), $Utf8NoBom)
}

function Test-NgrokOccupied([string]$Logs) {
    return $Logs -match 'ERR_NGROK_334|ERR_NGROK_108|already online|already bound|simultaneous ngrok agent|another ngrok agent'
}

function Test-NgrokReady([string]$Logs) {
    return $Logs -match 'started tunnel'
}

function Invoke-NgrokCompose {
    param([Parameter(Mandatory = $true)][string[]]$ComposeArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = & docker @script:NgrokComposePrefix @ComposeArgs 2>&1 | Out-String
    $ErrorActionPreference = $prev
    if ($null -eq $output) {
        return ''
    }
    return [string]$output
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    Write-Status 'unknown'
    return
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "找不到 $EnvFile。"
    Write-Status 'unknown'
    return
}

Set-Location -LiteralPath $Root

$scenario = Get-EnvValue 'N8N_SCENARIO'
$enableNgrok = Get-EnvValue 'ENABLE_NGROK'
if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'A' }
$scenario = $scenario.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($enableNgrok)) { $enableNgrok = 'false' }
$enableNgrok = $enableNgrok.ToLowerInvariant()

if ($enableNgrok -ne 'true') {
    Write-Status 'skipped'
    Write-Host '未啟用 ngrok，略過通道檢查。' -ForegroundColor DarkGray
    return
}

$script:NgrokComposePrefix = @('compose')
if ($scenario -eq 'C') {
    $script:NgrokComposePrefix += @('-f', 'compose.yml', '-f', 'compose.remote-supabase.yml')
}
$script:NgrokComposePrefix += @('--profile', 'tunnel')

Write-Host '檢查 ngrok 通道是否可用 ...' -ForegroundColor White
$cidRaw = Invoke-NgrokCompose -ComposeArgs @('ps', '-a', '-q', 'ngrok')
$cid = (($cidRaw -split '\r?\n') | Where-Object { $_ -match '^[a-fA-F0-9]{12,}$' } | Select-Object -Last 1)
if ([string]::IsNullOrWhiteSpace($cid)) {
    Write-Host '找不到 ngrok 容器，略過通道檢查。' -ForegroundColor Yellow
    Write-Status 'unknown'
    return
}

$occupied = $false
$ready = $false
for ($i = 0; $i -lt 12; $i++) {
    $logs = Invoke-NgrokCompose -ComposeArgs @('logs', '--no-color', '--tail', '120', 'ngrok')
    if (Test-NgrokOccupied $logs) {
        $occupied = $true
        break
    }
    if (Test-NgrokReady $logs) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 2
}

if (-not $occupied -and -not $ready) {
    $logs = Invoke-NgrokCompose -ComposeArgs @('logs', '--no-color', '--tail', '120', 'ngrok')
    if (Test-NgrokOccupied $logs) {
        $occupied = $true
    }
    elseif (Test-NgrokReady $logs) {
        $ready = $true
    }
}

if ($occupied) {
    Write-Host '固定網域已被其他設備佔用，已停止本機 ngrok。' -ForegroundColor Yellow
    Write-Host '  請先在另一台裝置關閉 ngrok 後，再執行同一支啟動腳本。' -ForegroundColor DarkGray
    $null = Invoke-NgrokCompose -ComposeArgs @('stop', 'ngrok')
    Write-Status 'occupied'
    return
}

if ($ready) {
    Write-Host 'ngrok 通道已就緒。' -ForegroundColor Green
    Write-Status 'ok'
    return
}

Write-Host '暫時無法確認 ngrok 是否已連上，容器仍會繼續執行。' -ForegroundColor Yellow
Write-Status 'unknown'
