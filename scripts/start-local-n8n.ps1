$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

$NoPull = $false

function Show-Usage {
    @'
依 .env 的場景與 ngrok 設定啟動本機 n8n，完成後顯示內部與外部網址。

用法：
  .\scripts\start-local-n8n.cmd
  .\scripts\start-local-n8n.cmd --no-pull   不重新下載映像，只建立或啟動 container
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--no-pull' { $NoPull = $true }
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

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    Exit-N8nScript 1
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "找不到 $EnvFile。請先執行 .\scripts\create-envfile.cmd"
    Exit-N8nScript 1
}

Set-Location -LiteralPath $Root

$scenario = Get-EnvValue 'N8N_SCENARIO'
$enableNgrok = Get-EnvValue 'ENABLE_NGROK'
$ngrokDomain = Get-EnvValue 'NGROK_DOMAIN'

if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'A' }
$scenario = $scenario.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($enableNgrok)) { $enableNgrok = 'false' }
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
if ($NoPull) {
    $composeArgs += @('--pull', 'never')
}

if ($NoPull) {
    Write-Host "啟動 n8n（場景 $scenario，不下載映像）..." -ForegroundColor White
}
else {
    Write-Host "啟動 n8n（場景 $scenario）..." -ForegroundColor White
}
Write-Host ("  docker " + ($composeArgs -join ' ')) -ForegroundColor DarkGray
Write-Host ''

& docker @composeArgs
if ($LASTEXITCODE -ne 0) {
    Exit-N8nScript $LASTEXITCODE
}

function Get-DisplayWidth([string]$Text) {
    $width = 0
    if ([string]::IsNullOrEmpty($Text)) {
        return 0
    }
    foreach ($ch in $Text.ToCharArray()) {
        if ([int][char]$ch -gt 0x7F) {
            $width += 2
        }
        else {
            $width += 1
        }
    }
    return $width
}

function Write-AlignedField {
    param(
        [string]$Label,
        [string]$Value,
        [ConsoleColor]$ValueColor = 'Cyan'
    )
    $pad = 12 - (Get-DisplayWidth $Label)
    if ($pad -lt 0) {
        $pad = 0
    }
    $old = [Console]::ForegroundColor
    try {
        [Console]::ForegroundColor = [ConsoleColor]::White
        [Console]::Write(('  ' + $Label + (' ' * $pad) + '  '))
        [Console]::ForegroundColor = $ValueColor
        [Console]::WriteLine($Value)
    }
    finally {
        [Console]::ForegroundColor = $old
    }
}

if ($env:N8N_ORCHESTRATED -ne '1') {
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
    Write-AlignedField '內部網址' $internalUrl
    if ($externalUrl) {
        Write-AlignedField '外部網址' $externalUrl
        Write-AlignedField 'ngrok 檢查頁' 'http://127.0.0.1:4040'
    }
    else {
        Write-AlignedField '外部網址' '未啟用 ngrok，無法使用對外 webhook' 'Yellow'
    }
    Write-Host ''
    Write-Host '  請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。' -ForegroundColor Green
}
