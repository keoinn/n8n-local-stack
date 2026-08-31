$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
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

function Update-EnvVar([string]$Key, [string]$Value) {
    $quoted = "'" + $Value.Replace("'", "'\''") + "'"
    $line = "$Key=$quoted"
    $lines = @()
    if (Test-Path -LiteralPath $EnvFile) {
        $lines = @(Get-Content -LiteralPath $EnvFile)
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
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($EnvFile, (($out -join "`n") + "`n"), $utf8NoBom)
}

if (-not (Test-Path -LiteralPath $EnvFile)) {
    Copy-Item -LiteralPath (Join-Path $Root '.env.example') -Destination $EnvFile
    Write-Host "已從 .env.example 建立 $EnvFile"
}

Import-DotEnv $EnvFile

$gcpProject = $env:GCP_PROJECT
if ([string]::IsNullOrWhiteSpace($gcpProject)) { $gcpProject = 'n8n-and-ai-168888' }
$gcpRegion = $env:GCP_REGION
if ([string]::IsNullOrWhiteSpace($gcpRegion)) { $gcpRegion = 'asia-east1' }
$gcpRunService = $env:GCP_RUN_SERVICE
if ([string]::IsNullOrWhiteSpace($gcpRunService)) { $gcpRunService = 'n8n' }

New-Item -ItemType Directory -Force -Path (Join-Path $Root 'data\n8n'), (Join-Path $Root 'data\postgres'), (Join-Path $Root 'exports') | Out-Null

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 gcloud，請先安裝 Google Cloud SDK 並登入。'
    exit 1
}

Write-Host '從 Secret Manager 讀取 n8n-encryption-key ...'
$encryptionKey = ((& gcloud secrets versions access latest --secret=n8n-encryption-key --project=$gcpProject) | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($encryptionKey)) {
    Write-Err 'n8n-encryption-key 是空的。'
    exit 1
}
Update-EnvVar 'N8N_ENCRYPTION_KEY' $encryptionKey
Write-Host '已寫入 N8N_ENCRYPTION_KEY'

Write-Host '從 Secret Manager 讀取 supabase-db-password ...'
$dbPassword = ((& gcloud secrets versions access latest --secret=supabase-db-password --project=$gcpProject) | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($dbPassword)) {
    Write-Err 'supabase-db-password 是空的。'
    exit 1
}
Update-EnvVar 'CLOUD_DB_POSTGRESDB_PASSWORD' $dbPassword
Write-Host '已寫入 CLOUD_DB_POSTGRESDB_PASSWORD'

Write-Host '從 Cloud Run 讀取 Supabase 連線設定 ...'
$cloudJson = & gcloud run services describe $gcpRunService --project=$gcpProject --region=$gcpRegion --format=json
if ($LASTEXITCODE -eq 0) {
    $cloudJsonText = if ($cloudJson -is [array]) { $cloudJson -join "`n" } else { [string]$cloudJson }
    $svc = $cloudJsonText | ConvertFrom-Json
    $mapping = @{
        DB_POSTGRESDB_HOST     = 'CLOUD_DB_POSTGRESDB_HOST'
        DB_POSTGRESDB_PORT     = 'CLOUD_DB_POSTGRESDB_PORT'
        DB_POSTGRESDB_DATABASE = 'CLOUD_DB_POSTGRESDB_DATABASE'
        DB_POSTGRESDB_USER     = 'CLOUD_DB_POSTGRESDB_USER'
        DB_POSTGRESDB_SCHEMA   = 'CLOUD_DB_POSTGRESDB_SCHEMA'
    }
    $envs = @($svc.spec.template.spec.containers[0].env)
    foreach ($item in $envs) {
        $name = [string]$item.name
        $value = [string]$item.value
        if ($mapping.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace($value)) {
            Update-EnvVar $mapping[$name] $value
            Write-Host "已寫入 $($mapping[$name])"
        }
    }
}
else {
    Write-Err '無法讀取 Cloud Run 服務，請自行確認 .env 裡的 CLOUD_DB_POSTGRESDB_*。'
}

Update-EnvVar 'GCP_PROJECT' $gcpProject
Update-EnvVar 'GCP_REGION' $gcpRegion
Update-EnvVar 'GCP_RUN_SERVICE' $gcpRunService

Write-Host ''
Write-Host '完成。請確認 .env 的勿動區已寫入 N8N_ENCRYPTION_KEY 與 CLOUD_DB_*。'
Write-Host ''
Write-Host '場景 B（複製到本機 Postgres，不改雲端資料）：'
Write-Host '  docker compose --profile tunnel up -d'
Write-Host '  .\scripts\sync-from-cloud.cmd'
Write-Host ''
Write-Host '場景 C（本機 n8n 直連遠端 Supabase）：'
Write-Host '  docker compose -f compose.yml -f compose.remote-supabase.yml --profile tunnel up -d'
Write-Host '  不要跑 .\scripts\sync-from-cloud.cmd'
Write-Host ''
Write-Host '注意：'
Write-Host '  - 請先 pull-secrets 再啟動容器，n8n 才會用 Cloud Run 同一把 encryption key。'
Write-Host '  - 場景 C 與 Cloud Run 共用同一顆庫；兩邊同時開著，排程 / webhook 可能各跑一次。'
Write-Host '  - 從 A / B 切到 C 時，先 docker compose --profile tunnel down。'
Write-Host '  - 只要本機編輯、不上 ngrok，把指令裡的 --profile tunnel 拿掉即可。'
