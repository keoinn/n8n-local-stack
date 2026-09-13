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

function Update-EnvVar([string]$Key, [string]$Value) {
    $value = (($Value -replace '[\r\n]+', '')).Trim()
    $quoted = "'" + $value.Replace("'", "'\''") + "'"
    $line = "$Key=$quoted"
    $lines = @()
    if (Test-Path -LiteralPath $EnvFile) {
        $lines = [System.IO.File]::ReadAllLines($EnvFile, $Utf8NoBom)
    }
    $found = $false
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($existing in $lines) {
        if (-not $found -and $existing.StartsWith("$Key=") -and -not $existing.StartsWith('#')) {
            $out.Add($line)
            $found = $true
        }
        else {
            $out.Add($existing)
        }
    }
    if (-not $found) {
        if ($out.Count -gt 0 -and $out[$out.Count - 1] -ne '') {
            $out.Add('')
        }
        $out.Add($line)
    }
    [System.IO.File]::WriteAllText($EnvFile, (($out -join "`n") + "`n"), $Utf8NoBom)
}

function New-RunnersToken {
    $chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'.ToCharArray()
    return -join (1..32 | ForEach-Object { $chars | Get-Random })
}

function Ensure-RunnersAuthToken {
    $token = Get-EnvValue 'N8N_RUNNERS_AUTH_TOKEN'
    if ([string]::IsNullOrWhiteSpace($token) -or $token.StartsWith('YOUR_')) {
        $token = New-RunnersToken
        Update-EnvVar 'N8N_RUNNERS_AUTH_TOKEN' $token
        Write-Host '  已寫入 N8N_RUNNERS_AUTH_TOKEN（task runner 連線用）。' -ForegroundColor DarkGray
    }
}

$RunnersImageName = 'n8n-local-stack:runners'
$RunnersStampFile = Join-Path $Root 'data\.runners-build-stamp'

function Get-RunnersBuildFingerprint {
    $parts = @(
        (Get-EnvValue 'N8N_RUNNERS_IMAGE')
        (Get-EnvValue 'NODE_FUNCTION_ALLOW_BUILTIN')
        (Get-EnvValue 'NODE_FUNCTION_ALLOW_EXTERNAL')
        (Get-EnvValue 'N8N_RUNNERS_PY_PACKAGES')
        (Get-EnvValue 'N8N_RUNNERS_STDLIB_ALLOW')
        (Get-EnvValue 'N8N_RUNNERS_EXTERNAL_ALLOW')
        (Get-EnvValue 'N8N_RUNNERS_ALLOW_TRANSITIVE_IMPORTS')
    )
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $buffer = New-Object System.IO.MemoryStream
        $enc = [System.Text.UTF8Encoding]::new($false)
        foreach ($part in $parts) {
            $bytes = $enc.GetBytes(($part + "`n"))
            $buffer.Write($bytes, 0, $bytes.Length)
        }
        foreach ($rel in @('docker/runners/Dockerfile', 'docker/runners/n8n-task-runners.json')) {
            $path = Join-Path $Root $rel
            if (Test-Path -LiteralPath $path) {
                $fileBytes = [System.IO.File]::ReadAllBytes($path)
                $buffer.Write($fileBytes, 0, $fileBytes.Length)
            }
        }
        $hash = $sha.ComputeHash($buffer.ToArray())
        return -join ($hash | ForEach-Object { $_.ToString('x2') })
    }
    finally {
        $sha.Dispose()
    }
}

function Write-RunnersStamp {
    $dir = Split-Path -Parent $RunnersStampFile
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir | Out-Null
    }
    [System.IO.File]::WriteAllText($RunnersStampFile, ((Get-RunnersBuildFingerprint) + "`n"), $Utf8NoBom)
}

function Test-RunnersImage {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker image inspect $RunnersImageName *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Test-RunnersNeedsBuild {
    if (-not (Test-RunnersImage)) {
        return $true
    }
    if (-not (Test-Path -LiteralPath $RunnersStampFile)) {
        return $false
    }
    $current = Get-RunnersBuildFingerprint
    $stamp = ((Get-Content -LiteralPath $RunnersStampFile -Raw -ErrorAction SilentlyContinue) -replace '[\r\n]+', '').Trim()
    return -not ($current -and $current -eq $stamp)
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
$enableRunners = Get-EnvValue 'ENABLE_N8N_RUNNERS'
$ngrokDomain = Get-EnvValue 'NGROK_DOMAIN'

if ([string]::IsNullOrWhiteSpace($scenario)) { $scenario = 'A' }
$scenario = $scenario.ToUpperInvariant()
if ([string]::IsNullOrWhiteSpace($enableNgrok)) { $enableNgrok = 'false' }
$enableNgrok = $enableNgrok.ToLowerInvariant()
if ([string]::IsNullOrWhiteSpace($enableRunners)) { $enableRunners = 'false' }
$enableRunners = $enableRunners.ToLowerInvariant()

if ($enableRunners -eq 'true') {
    Ensure-RunnersAuthToken
}
else {
    docker compose --profile runners stop task-runners 2>$null | Out-Null
}

$composeArgs = @('compose')
if ($scenario -eq 'C') {
    $composeArgs += @('-f', 'compose.yml', '-f', 'compose.remote-supabase.yml')
}
if ($enableNgrok -eq 'true') {
    $composeArgs += @('--profile', 'tunnel')
}
if ($enableRunners -eq 'true') {
    $composeArgs += @('--profile', 'runners')
}
if ($enableNgrok -eq 'true' -or $scenario -eq 'C') {
    $composeArgs += @('up', '-d')
}
elseif ($enableRunners -eq 'true') {
    $composeArgs += @('up', '-d', 'postgres', 'n8n', 'task-runners')
}
else {
    $composeArgs += @('up', '-d', 'postgres', 'n8n')
}
if ($NoPull) {
    $composeArgs += @('--pull', 'never')
}
if ($enableRunners -eq 'true') {
    if (Test-RunnersNeedsBuild) {
        $composeArgs += '--build'
    }
    else {
        Write-Host '  task-runners 映像已存在且套件清單未改，略過重建。' -ForegroundColor DarkGray
    }
}

if ($NoPull) {
    Write-Host "啟動 n8n（場景 $scenario，不下載映像）..." -ForegroundColor White
}
else {
    Write-Host "啟動 n8n（場景 $scenario）..." -ForegroundColor White
}
Write-Host ("  docker " + ($composeArgs -join ' ')) -ForegroundColor DarkGray
Write-Host ''

# start-n8n.ps1 用 `| Out-Host` 呼叫本腳本時，PowerShell 會把 stdout 變成管線。
# docker compose --build 的 TTY 進度列需要真實 Win32 console；走管線就會
# 「failed to get console: The handle is invalid」。
# Start-Process -NoNewWindow 讓 docker 寫回原本的 cmd 視窗，進度列可保留。
function Invoke-DockerOnConsole([string[]]$DockerArgs) {
    $docker = (Get-Command docker -ErrorAction Stop).Source
    $p = Start-Process -FilePath $docker -ArgumentList $DockerArgs -WorkingDirectory $Root -NoNewWindow -Wait -PassThru
    if ($null -eq $p -or $p.ExitCode -ne 0) {
        $code = 1
        if ($p) {
            $code = [int]$p.ExitCode
        }
        Exit-N8nScript $code
    }
}

Invoke-DockerOnConsole $composeArgs
if ($enableRunners -eq 'true') {
    Write-RunnersStamp
}

if ($enableNgrok -eq 'true' -and $env:N8N_ORCHESTRATED -ne '1') {
    & (Join-Path $PSScriptRoot 'check-ngrok-service.ps1') | Out-Host
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
    $ngrokStatus = ''
    $statusFile = Join-Path $Root 'data\.ngrok-status'
    if (Test-Path -LiteralPath $statusFile) {
        $ngrokStatus = ([System.IO.File]::ReadAllText($statusFile, $Utf8NoBom)).Trim()
    }
    if ($enableNgrok -eq 'true' -and -not [string]::IsNullOrWhiteSpace($ngrokDomain) -and $ngrokDomain -ne 'YOUR_NGROK_DOMAIN') {
        $externalUrl = "https://$ngrokDomain"
    }

    Write-Host ''
    Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host '  n8n 已啟動' -ForegroundColor Cyan
    Write-Host '════════════════════════════════════════════════════════════' -ForegroundColor Cyan
    Write-Host ''
    Write-AlignedField '內部網址' $internalUrl
    if ($ngrokStatus -eq 'occupied') {
        Write-AlignedField '外部網址' '固定網域已被其他設備佔用，無法使用對外 webhook' 'Yellow'
    }
    elseif ($externalUrl) {
        Write-AlignedField '外部網址' $externalUrl
        Write-AlignedField 'ngrok 檢查頁' 'http://127.0.0.1:4040'
    }
    else {
        Write-AlignedField '外部網址' '未啟用 ngrok，無法使用對外 webhook' 'Yellow'
    }
    Write-Host ''
    if ($ngrokStatus -eq 'occupied') {
        Write-Host '  請以內部網址開啟本機編輯器；固定網域已被其他設備佔用。' -ForegroundColor Green
    }
    else {
        Write-Host '  請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。' -ForegroundColor Green
    }
}
