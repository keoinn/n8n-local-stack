$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$CredentialsOnly = $false
$KeepExports = $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
用法：
  .\scripts\sync-from-cloud.ps1                 完整複製使用者、Credentials、工作流程
  .\scripts\sync-from-cloud.ps1 --credentials-only   只從雲端匯入 Credentials
  .\scripts\sync-from-cloud.ps1 --keep-exports       同步後保留 exports/ 暫存檔
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--credentials-only' { $CredentialsOnly = $true }
        '--keep-exports' { $KeepExports = $true }
        { $_ -in @('-h', '--help') } {
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

function Import-DotEnv([string]$Path) {
    Get-Content -LiteralPath $Path | ForEach-Object {
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
        Set-Item -Path "Env:$key" -Value $value
    }
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Write-Err "找不到 $EnvFile，請先複製 .env.example 並執行 .\scripts\pull-secrets.cmd"
    exit 1
}

Import-DotEnv $EnvFile

$n8nImage = $env:N8N_IMAGE
if ([string]::IsNullOrWhiteSpace($n8nImage)) {
    $n8nImage = 'n8nio/n8n:2.36.8'
}

$requiredVars = @(
    'N8N_ENCRYPTION_KEY',
    'CLOUD_DB_POSTGRESDB_HOST',
    'CLOUD_DB_POSTGRESDB_PORT',
    'CLOUD_DB_POSTGRESDB_DATABASE',
    'CLOUD_DB_POSTGRESDB_USER',
    'CLOUD_DB_POSTGRESDB_PASSWORD'
)
foreach ($varName in $requiredVars) {
    $value = [Environment]::GetEnvironmentVariable($varName)
    if ([string]::IsNullOrWhiteSpace($value)) {
        Write-Err "$varName 是空的。請先執行 .\scripts\pull-secrets.cmd"
        exit 1
    }
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    exit 1
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
    $probe = @'
    if command -v pg_isready >/dev/null 2>&1; then
      pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
    else
      wget -qO- http://127.0.0.1:5678/health >/dev/null
    fi
'@
    while ($true) {
        docker compose exec -T $Service sh -c $probe 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            return
        }
        if ($elapsed -ge $Timeout) {
            Write-Err "$Service 在 $Timeout 秒內沒有變成 healthy。"
            docker compose logs --tail=80 $Service 2>&1 | ForEach-Object { Write-Err "$_" }
            exit 1
        }
        Start-Sleep -Seconds 3
        $elapsed += 3
    }
}

function Invoke-Docker([object[]]$DockerArgs) {
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

Write-Host '確認本機 Postgres 與 n8n 已做過 migration ...'
Invoke-Docker @('compose', 'up', '-d', 'postgres', 'n8n')
Wait-ForService postgres 90
Wait-ForService n8n 240

Write-Host '暫停本機 n8n，避免匯入時寫入衝突 ...'
Invoke-Docker @('compose', 'stop', 'n8n')

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

function Export-FromCloud([object[]]$ExportArgs) {
    $runArgs = @('run', '--rm', '--user', 'node') + $cloudDbEnv + @('-v', "${exportsVolume}:/exports", $n8nImage) + @($ExportArgs)
    Invoke-Docker $runArgs
}

if (-not $CredentialsOnly) {
    Write-Host '從 Supabase 匯出全部 entities ...'
    $entitiesDir = Join-Path $Root 'exports\entities'
    if (Test-Path -LiteralPath $entitiesDir) {
        Remove-Item -LiteralPath $entitiesDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $entitiesDir | Out-Null
    Export-FromCloud @('export:entities', '--outputDir=/exports/entities')
}

Write-Host '從 Supabase 匯出 Credentials ...'
Export-FromCloud @('export:credentials', '--all', '--output=/exports/credentials.json')

if ($CredentialsOnly) {
    Write-Host '把 Credentials 匯入本機 ...'
    Invoke-Docker @('compose', 'run', '--rm', '--no-deps', 'n8n', 'import:credentials', '--input=/exports/credentials.json')
}
else {
    Write-Host '把 entities 匯入本機（會清空本機對應資料表） ...'
    Invoke-Docker @('compose', 'run', '--rm', '--no-deps', 'n8n', 'import:entities', '--inputDir=/exports/entities', '--truncateTables', 'true')
    Write-Host '取消發布本機全部工作流程，避免和 Cloud Run 同時觸發 ...'
    docker compose run --rm --no-deps n8n unpublish:workflow --all
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'unpublish:workflow 失敗，改用 update:workflow --active=false ...'
        Invoke-Docker @('compose', 'run', '--rm', '--no-deps', 'n8n', 'update:workflow', '--all', '--active=false')
    }
}

Write-Host '重新啟動本機 n8n ...'
Invoke-Docker @('compose', 'up', '-d', 'n8n')
Wait-ForService n8n 240

if (-not $KeepExports) {
    Write-Host '清除 exports/ 暫存檔 ...'
    $entitiesDir = Join-Path $Root 'exports\entities'
    $credentialsFile = Join-Path $Root 'exports\credentials.json'
    if (Test-Path -LiteralPath $entitiesDir) {
        Remove-Item -LiteralPath $entitiesDir -Recurse -Force
    }
    if (Test-Path -LiteralPath $credentialsFile) {
        Remove-Item -LiteralPath $credentialsFile -Force
    }
}

Write-Host ''
Write-Host '同步完成。編輯器：http://localhost:5678'
Write-Host '請用 Cloud Run 同一組帳密登入。'
Write-Host '需要外網 webhook 時：docker compose --profile tunnel up -d'
