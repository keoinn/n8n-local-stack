$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$CredentialsOnly = $false
$KeepExports = $false
$AssumeYes = $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
把本機 n8n 資料回寫到 Supabase。僅限場景 B。

會清空雲端對應資料表再匯入。Cloud Run 若仍在跑，可能與回寫衝突。
回寫後，雲端工作流程的發布狀態會與本機相同。

用法：
  .\scripts\sync-to-cloud.cmd                 完整回寫使用者、Credentials、工作流程
  .\scripts\sync-to-cloud.cmd --credentials-only   只把本機 Credentials 寫回雲端
  .\scripts\sync-to-cloud.cmd --keep-exports       回寫後保留 exports/ 暫存檔
  .\scripts\sync-to-cloud.cmd --yes                略過確認（非互動或腳本使用）
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--credentials-only' { $CredentialsOnly = $true }
        '--keep-exports' { $KeepExports = $true }
        { $_ -in @('--yes', '-y') } { $AssumeYes = $true }
        { $_ -in @('-h', '--help') } {
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

function Import-DotEnv([string]$Path) {
    [System.IO.File]::ReadAllLines($Path, $Utf8NoBom) | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) {
            return
        }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) {
            return
        }
        $key = $line.Substring(0, $eq).Trim()
        $value = $line.Substring($eq + 1).Trim()
        if ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2).Replace("'\\''", "'")
        }
        elseif ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        else {
            $hash = $value.IndexOf(' #')
            if ($hash -ge 0) {
                $value = $value.Substring(0, $hash).TrimEnd()
            }
        }
        if ($key -eq 'N8N_ORCHESTRATED') {
            return
        }
        Set-Item -Path "Env:$key" -Value $value
    }
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "找不到 $EnvFile，請先執行 .\start-n8n.cmd 或 .\scripts\create-envfile.cmd"
    Exit-N8nScript 1
}

Import-DotEnv $EnvFile

$n8nImage = $env:N8N_IMAGE
if ([string]::IsNullOrWhiteSpace($n8nImage)) {
    $n8nImage = 'n8nio/n8n:2.36.8'
}

$scenario = (Get-EnvValue 'N8N_SCENARIO').ToUpperInvariant()
if ($scenario -ne 'B') {
    Write-Err "此腳本只適用場景 B（本機 Postgres 複本回寫雲端）。目前 N8N_SCENARIO=$(if ($scenario) { $scenario } else { '未設定' })。"
    if ($scenario -eq 'C') {
        Write-Err '場景 C 已直連 Supabase，不需要回寫。'
    }
    Exit-N8nScript 1
}

$requiredVars = @(
    'N8N_ENCRYPTION_KEY',
    'POSTGRES_DB',
    'POSTGRES_USER',
    'POSTGRES_PASSWORD',
    'CLOUD_DB_POSTGRESDB_HOST',
    'CLOUD_DB_POSTGRESDB_PORT',
    'CLOUD_DB_POSTGRESDB_DATABASE',
    'CLOUD_DB_POSTGRESDB_USER',
    'CLOUD_DB_POSTGRESDB_PASSWORD'
)
foreach ($varName in $requiredVars) {
    $value = Get-EnvValue $varName
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Err "$varName 是空的。請先執行 .\scripts\pull-secrets.cmd"
        Exit-N8nScript 1
    }
    Set-Item -Path "Env:$varName" -Value $value
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    Exit-N8nScript 1
}

function Confirm-Writeback {
    if ($AssumeYes) {
        return
    }
    if ([Console]::IsInputRedirected) {
        Write-Err '非互動環境請加上 --yes。'
        Exit-N8nScript 1
    }
    Write-Host ''
    Write-Host '即將用本機 n8n 資料覆寫 Supabase（Cloud Run 正在用的那份）。'
    Write-Host '  · 雲端使用者、憑證與工作流程會先被清空再匯入'
    Write-Host '  · 雲端流程的發布狀態會變成與本機相同'
    Write-Host '  · 請先把 Cloud Run 縮成 0，或暫停雲端流程，避免兩邊同時寫入'
    Write-Host ''
    Write-Host '確定回寫請輸入 WRITE：' -NoNewline
    $answer = [Console]::ReadLine()
    if ($null -eq $answer) {
        $answer = ''
    }
    $answer = $answer.Trim()
    if ($answer -ne 'WRITE') {
        Write-Err '已取消。'
        Exit-N8nScript 1
    }
    Write-Host ''
}

New-Item -ItemType Directory -Force -Path `
    (Join-Path $Root 'data\n8n'), `
    (Join-Path $Root 'data\postgres'), `
    (Join-Path $Root 'exports\entities') | Out-Null

Set-Location -LiteralPath $Root

function Wait-ForService {
    param(
        [string]$Service,
        [int]$Timeout = 180
    )
    $elapsed = 0
    Write-Host "等待 $Service 就緒 ..."
    while ($true) {
        $id = @(docker compose ps -q $Service 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }) | Select-Object -First 1
        if ($id) {
            $health = docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' $id 2>$null
            if ($health -eq 'healthy') {
                return
            }
        }
        if ($elapsed -ge $Timeout) {
            Write-Err "$Service 在 $Timeout 秒內沒有變成 healthy。"
            docker compose logs --tail=80 $Service 2>&1 | ForEach-Object { Write-Err "$_" }
            Exit-N8nScript 1
        }
        Start-Sleep -Seconds 3
        $elapsed += 3
    }
}

function Invoke-Docker([object[]]$DockerArgs) {
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        Exit-N8nScript $LASTEXITCODE
    }
}

$enableRunners = (Get-EnvValue 'ENABLE_N8N_RUNNERS').ToLowerInvariant()
if ($enableRunners -eq 'true') {
    $upArgs = @('compose', '--profile', 'runners', 'up', '-d', 'postgres', 'n8n', 'task-runners')
    $stopArgs = @('compose', '--profile', 'runners', 'stop', 'n8n', 'task-runners')
    $restartArgs = @('compose', '--profile', 'runners', 'up', '-d', 'n8n', 'task-runners')
}
else {
    $upArgs = @('compose', 'up', '-d', 'postgres', 'n8n')
    $stopArgs = @('compose', 'stop', 'n8n')
    $restartArgs = @('compose', 'up', '-d', 'n8n')
}

Confirm-Writeback

Write-Host '確認本機 Postgres 與 n8n 已做過 migration ...'
Invoke-Docker $upArgs
Wait-ForService postgres 90
Wait-ForService n8n 240

Write-Host '暫停本機 n8n，避免匯出時寫入衝突 ...'
Invoke-Docker $stopArgs

$cloudSchema = $env:CLOUD_DB_POSTGRESDB_SCHEMA
if ([string]::IsNullOrWhiteSpace($cloudSchema)) {
    $cloudSchema = 'public'
}

$exportsVolume = Join-Path $Root 'exports'
$cloudDbEnv = @(
    '-e', "N8N_ENCRYPTION_KEY=$($env:N8N_ENCRYPTION_KEY)",
    '-e', 'DB_TYPE=postgresdb',
    '-e', "DB_POSTGRESDB_HOST=$($env:CLOUD_DB_POSTGRESDB_HOST)",
    '-e', "DB_POSTGRESDB_PORT=$($env:CLOUD_DB_POSTGRESDB_PORT)",
    '-e', "DB_POSTGRESDB_DATABASE=$($env:CLOUD_DB_POSTGRESDB_DATABASE)",
    '-e', "DB_POSTGRESDB_USER=$($env:CLOUD_DB_POSTGRESDB_USER)",
    '-e', "DB_POSTGRESDB_PASSWORD=$($env:CLOUD_DB_POSTGRESDB_PASSWORD)",
    '-e', "DB_POSTGRESDB_SCHEMA=$cloudSchema",
    '-e', 'DB_POSTGRESDB_SSL_ENABLED=true',
    '-e', 'DB_POSTGRESDB_SSL_REJECT_UNAUTHORIZED=false',
    '-e', 'DB_POSTGRESDB_CONNECTION_TIMEOUT=30000',
    '-e', 'N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=true'
)

function Import-ToCloud([object[]]$ImportArgs) {
    $runArgs = @('run', '--rm', '--user', 'node') + $cloudDbEnv + @('-v', "${exportsVolume}:/exports", $n8nImage) + @($ImportArgs)
    Invoke-Docker $runArgs
}

$entitiesDir = Join-Path $Root 'exports\entities'
if (Test-Path -LiteralPath $entitiesDir) {
    Remove-Item -LiteralPath $entitiesDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $entitiesDir | Out-Null

if (-not $CredentialsOnly) {
    Write-Host '從本機匯出全部 entities ...'
    Invoke-Docker @('compose', 'run', '--rm', '--no-deps', 'n8n', 'export:entities', '--outputDir=/exports/entities')
}

Write-Host '從本機匯出 Credentials ...'
Invoke-Docker @('compose', 'run', '--rm', '--no-deps', 'n8n', 'export:credentials', '--all', '--output=/exports/credentials.json')

if ($CredentialsOnly) {
    Write-Host '把本機 Credentials 寫回 Supabase ...'
    Import-ToCloud @('import:credentials', '--input=/exports/credentials.json')
}
else {
    Write-Host '把本機 entities 寫回 Supabase（會清空雲端對應資料表） ...'
    Import-ToCloud @('import:entities', '--inputDir=/exports/entities', '--truncateTables', 'true')
}

Write-Host '重新啟動本機 n8n ...'
Invoke-Docker $restartArgs
Wait-ForService n8n 240

if (-not $KeepExports) {
    Write-Host '清除 exports/ 暫存檔 ...'
    $credentialsFile = Join-Path $Root 'exports\credentials.json'
    if (Test-Path -LiteralPath $entitiesDir) {
        Remove-Item -LiteralPath $entitiesDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $credentialsFile) {
        Remove-Item -LiteralPath $credentialsFile -Force
    }
}

Write-Host ''
Write-Host '本機資料已回寫到 Supabase。'
if (-not $CredentialsOnly) {
    Write-Host '請到 Cloud Run 確認工作流程發布狀態是否符合預期。'
}
