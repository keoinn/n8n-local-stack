$ErrorActionPreference = 'Continue'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$script:Pass = 0
$script:Warn = 0
$script:Fail = 0

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
檢查本機是否已具備啟動 n8n 的條件。

會檢查：
  1. .env 是否存在
  2. N8N_SCENARIO 是否為 A / B / C
  3. 該場景必填變數是否已填（非空白、非範本值）
  4. Docker 是否安裝，且 daemon 是否在執行
  5. 場景 B / C 是否已安裝 gcloud，並已登入

用法：
  .\scripts\check-env.ps1
  .\scripts\check-env.cmd
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
function Write-Section([string]$Message) { Write-Host ''; Write-Host $Message -ForegroundColor Blue }
function Write-Body([string]$Message) { Write-Host $Message -ForegroundColor White }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }

function Write-Ok([string]$Message) {
    Write-Host '  [OK]    ' -ForegroundColor Green -NoNewline
    Write-Host $Message
    $script:Pass++
}

function Write-WarnItem([string]$Message, [string]$Hint = '') {
    Write-Host '  [WARN]  ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
    if (-not [string]::IsNullOrEmpty($Hint)) {
        Write-Muted "          $Hint"
    }
    $script:Warn++
}

function Write-FailItem([string]$Message, [string]$Hint = '') {
    Write-Host '  [FAIL]  ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    if (-not [string]::IsNullOrEmpty($Hint)) {
        Write-Muted "          $Hint"
    }
    $script:Fail++
}

function Write-Skip([string]$Message) {
    Write-Host '  [—]     ' -ForegroundColor DarkGray -NoNewline
    Write-Host $Message -ForegroundColor DarkGray
}

$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

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

function Test-Placeholder([string]$Value) {
    $v = Get-Sanitized $Value
    if ([string]::IsNullOrWhiteSpace($v)) {
        return $true
    }
    return $v.StartsWith('YOUR_')
}

function Test-SecretKey([string]$Key) {
    return $Key -in @(
        'POSTGRES_PASSWORD',
        'NGROK_AUTHTOKEN',
        'N8N_ENCRYPTION_KEY',
        'CLOUD_DB_POSTGRESDB_PASSWORD'
    )
}

function Test-RequiredEnv([string]$Key, [string]$Hint) {
    $value = Get-EnvValue $Key
    if (Test-Placeholder $value) {
        Write-FailItem "$Key 未設定或仍為範本值" $Hint
        return $false
    }
    if (Test-SecretKey $Key) {
        Write-Ok "$Key 已設定"
    }
    else {
        Write-Ok "$Key=$value"
    }
    return $true
}

function Test-OptionalEnv([string]$Key, [string]$Hint) {
    $value = Get-EnvValue $Key
    if (Test-Placeholder $value) {
        Write-WarnItem "$Key 尚未寫入" $Hint
        return $false
    }
    if (Test-SecretKey $Key) {
        Write-Ok "$Key 已設定"
    }
    else {
        Write-Ok "$Key=$value"
    }
    return $true
}

function Get-CommandOutput([string]$FileName, [string[]]$CmdArgs) {
    try {
        $output = & $FileName @CmdArgs 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ''
        }
        if ($null -eq $output) {
            return ''
        }
        if ($output -is [array]) {
            return (Get-Sanitized ([string]$output[0]))
        }
        return (Get-Sanitized ([string]$output))
    }
    catch {
        return ''
    }
}

function Test-NativeOk([string]$FileName, [string[]]$CmdArgs) {
    try {
        & $FileName @CmdArgs *> $null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  n8n 本機環境檢查'
Write-Title '════════════════════════════════════════════════════════════'

$scenario = ''
$enableNgrok = ''
$hasEnv = $false

Write-Section '【設定檔】'

if (Test-Path -LiteralPath $EnvFile) {
    Write-Ok ".env 存在（$EnvFile）"
    $hasEnv = $true
}
else {
    Write-FailItem '.env 不存在' '請先執行 .\scripts\create-envfile.ps1'
}

if ($hasEnv) {
    $scenario = (Get-EnvValue 'N8N_SCENARIO').ToUpperInvariant()
    $enableNgrok = (Get-EnvValue 'ENABLE_NGROK').ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($scenario)) {
        Write-FailItem 'N8N_SCENARIO 未設定' '請填 A、B 或 C，或重新執行 .\scripts\create-envfile.ps1'
    }
    elseif ($scenario -in @('A', 'B', 'C')) {
        Write-Ok "N8N_SCENARIO=$scenario"
    }
    else {
        Write-FailItem "N8N_SCENARIO=$scenario 不是有效場景" '請改為 A、B 或 C'
        $scenario = ''
    }

    switch ($scenario) {
        'A' {
            [void](Test-RequiredEnv 'POSTGRES_PASSWORD' '場景 A 需要本機 Postgres 密碼，請勿填雲端資料庫帳密。')
            [void](Test-RequiredEnv 'POSTGRES_DB' '請在 .env 設定 POSTGRES_DB（預設 n8n）。')
            [void](Test-RequiredEnv 'POSTGRES_USER' '請在 .env 設定 POSTGRES_USER（預設 n8n）。')
        }
        'B' {
            [void](Test-RequiredEnv 'POSTGRES_PASSWORD' '場景 B 需要本機 Postgres 密碼，請勿填雲端資料庫帳密。')
            [void](Test-RequiredEnv 'POSTGRES_DB' '請在 .env 設定 POSTGRES_DB（預設 n8n）。')
            [void](Test-RequiredEnv 'POSTGRES_USER' '請在 .env 設定 POSTGRES_USER（預設 n8n）。')
            [void](Test-RequiredEnv 'GCP_PROJECT' '請填 Google Cloud 專案 ID。')
            [void](Test-RequiredEnv 'GCP_REGION' '請填 Cloud Run 區域，例如 asia-east1。')
            [void](Test-RequiredEnv 'GCP_RUN_SERVICE' '請填 Cloud Run 服務名稱。')
            [void](Test-OptionalEnv 'N8N_ENCRYPTION_KEY' '啟動前請執行 .\scripts\pull-secrets.cmd，否則無法解密雲端 Credentials。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_HOST' '同步雲端資料前請執行 .\scripts\pull-secrets.cmd。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_USER' '同步雲端資料前請執行 .\scripts\pull-secrets.cmd。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_PASSWORD' '同步雲端資料前請執行 .\scripts\pull-secrets.cmd。')
        }
        'C' {
            [void](Test-RequiredEnv 'GCP_PROJECT' '請填 Google Cloud 專案 ID。')
            [void](Test-RequiredEnv 'GCP_REGION' '請填 Cloud Run 區域，例如 asia-east1。')
            [void](Test-RequiredEnv 'GCP_RUN_SERVICE' '請填 Cloud Run 服務名稱。')
            [void](Test-OptionalEnv 'N8N_ENCRYPTION_KEY' '啟動前請執行 .\scripts\pull-secrets.cmd。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_HOST' '場景 C 直連遠端 Supabase，啟動前請執行 .\scripts\pull-secrets.cmd。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_USER' '場景 C 直連遠端 Supabase，啟動前請執行 .\scripts\pull-secrets.cmd。')
            [void](Test-OptionalEnv 'CLOUD_DB_POSTGRESDB_PASSWORD' '場景 C 直連遠端 Supabase，啟動前請執行 .\scripts\pull-secrets.cmd。')
            $remoteCompose = Join-Path $Root 'compose.remote-supabase.yml'
            if (Test-Path -LiteralPath $remoteCompose) {
                Write-Ok 'compose.remote-supabase.yml 存在'
            }
            else {
                Write-FailItem '找不到 compose.remote-supabase.yml' '場景 C 啟動時需要此檔。'
            }
        }
        default {
            Write-Skip '場景必填變數：因 N8N_SCENARIO 無效而略過'
        }
    }

    switch ($enableNgrok) {
        { $_ -in @('true', 'yes', '1', 'y') } {
            Write-Ok 'ENABLE_NGROK=true'
            [void](Test-RequiredEnv 'NGROK_AUTHTOKEN' '可於 https://ngrok.com/ 儀表板取得 Auth Token。')
            $ngrokDomain = Get-EnvValue 'NGROK_DOMAIN'
            if (Test-Placeholder $ngrokDomain) {
                Write-FailItem 'NGROK_DOMAIN 未設定或仍為範本值' '只填主機名，不要加 https://。'
            }
            elseif ($ngrokDomain -match '(?i)https?://') {
                Write-FailItem "NGROK_DOMAIN=$ngrokDomain 含有通訊協定" '請只填主機名，例如 example.ngrok-free.dev。'
            }
            elseif ($ngrokDomain -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') {
                Write-FailItem "NGROK_DOMAIN=$ngrokDomain 格式不正確" '請填至少包含主域名與頂級網域的主機名。'
            }
            else {
                Write-Ok "NGROK_DOMAIN=$ngrokDomain"
            }
        }
        { $_ -in @('false', 'no', '0', 'n') } {
            Write-Ok 'ENABLE_NGROK=false（僅本機編輯，無法使用對外 webhook）'
        }
        '' {
            Write-WarnItem 'ENABLE_NGROK 未設定' '啟動腳本會預設為 true。請在 .env 明確填 true 或 false。'
        }
        default {
            Write-FailItem "ENABLE_NGROK=$enableNgrok 不是有效值" '請填 true 或 false。'
        }
    }
}
else {
    Write-Skip '場景與必填變數：因缺少 .env 而略過'
}

Write-Section '【Docker】'

$dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
if ($dockerCmd) {
    $dockerVer = Get-CommandOutput 'docker' @('--version')
    if ($dockerVer) {
        Write-Ok "Docker 已安裝（$dockerVer）"
    }
    else {
        Write-Ok 'Docker 已安裝'
    }

    if (Test-NativeOk 'docker' @('info')) {
        Write-Ok 'Docker daemon 正在執行'
    }
    else {
        Write-FailItem 'Docker 已安裝但 daemon 未啟動' '請開啟 Docker Desktop，等到引擎就緒後再重試。'
    }

    if (Test-NativeOk 'docker' @('compose', 'version')) {
        $composeVer = Get-CommandOutput 'docker' @('compose', 'version')
        if ($composeVer) {
            Write-Ok "Docker Compose 可用（$composeVer）"
        }
        else {
            Write-Ok 'Docker Compose 可用'
        }
    }
    else {
        Write-FailItem '找不到 docker compose 外掛' '本專案使用 Docker Compose V2（docker compose，不是 docker-compose）。'
    }
}
else {
    Write-FailItem '找不到 docker 指令' '請安裝 Docker Desktop，然後重新開啟終端機。'
    Write-Skip 'Docker daemon / Compose：因找不到 docker 而略過'
}

Write-Section '【Google Cloud SDK】'

switch ($scenario) {
    { $_ -in @('B', 'C') } {
        $gcloudCmd = Get-Command gcloud -ErrorAction SilentlyContinue
        if ($gcloudCmd) {
            Write-Ok "gcloud 已安裝（$($gcloudCmd.Source)）"

            $account = Get-CommandOutput 'gcloud' @('auth', 'list', '--filter=status:ACTIVE', '--format=value(account)')
            if ($account) {
                Write-Ok "gcloud 已登入（$account）"
            }
            else {
                Write-FailItem 'gcloud 尚未登入' '請執行：gcloud auth login'
            }

            $gcloudProject = Get-CommandOutput 'gcloud' @('config', 'get-value', 'project')
            if ([string]::IsNullOrWhiteSpace($gcloudProject) -or $gcloudProject -eq '(unset)') {
                Write-WarnItem 'gcloud 尚未設定預設專案' '請執行：gcloud config set project <你的 GCP 專案 ID>'
            }
            else {
                $envProject = Get-EnvValue 'GCP_PROJECT'
                if (-not (Test-Placeholder $envProject) -and $gcloudProject -ne $envProject) {
                    Write-WarnItem "gcloud 目前專案是 $gcloudProject，與 .env 的 GCP_PROJECT=$envProject 不同" "pull-secrets 會使用 .env 的 GCP_PROJECT；若不對請執行 gcloud config set project $envProject"
                }
                else {
                    Write-Ok "gcloud 專案=$gcloudProject"
                }
            }
        }
        else {
            Write-FailItem '找不到 gcloud' 'Windows 可執行：winget install -e --id Google.CloudSDK'
            Write-Skip 'gcloud 登入與專案：因找不到 gcloud 而略過'
        }
    }
    'A' {
        Write-Skip '場景 A 不需要 gcloud'
    }
    default {
        Write-Skip 'gcloud：因場景未確定而略過'
    }
}

Write-Host ''
Write-Title '────────────────────────────────────────────────────────────'
if ($script:Fail -eq 0 -and $script:Warn -eq 0) {
    Write-Host "  摘要：$($script:Pass) 項通過，環境已就緒。" -ForegroundColor Green
}
elseif ($script:Fail -eq 0) {
    Write-Host "  摘要：$($script:Pass) 項通過、$($script:Warn) 項警告。可繼續，但建議先處理警告。" -ForegroundColor Yellow
}
else {
    Write-Host "  摘要：$($script:Pass) 項通過、$($script:Warn) 項警告、$($script:Fail) 項失敗。" -ForegroundColor Red
}
Write-Title '────────────────────────────────────────────────────────────'
Write-Host ''

if ($script:Fail -gt 0) {
    Write-Body '建議下一步：'
    if (-not $hasEnv) {
        Write-Muted '  .\scripts\create-envfile.ps1'
    }
    elseif ($scenario -in @('B', 'C')) {
        Write-Muted '  修正上方失敗項目後，若密鑰尚未寫入，再執行 .\scripts\pull-secrets.cmd'
    }
    else {
        Write-Muted '  修正 .env 或安裝缺少的工具後，再執行本檢查。'
    }
}
elseif ($script:Warn -gt 0) {
    Write-Body '建議下一步：'
    if ($scenario -in @('B', 'C')) {
        Write-Muted '  .\scripts\pull-secrets.cmd'
        Write-Muted '  完成後再執行 .\scripts\start-local-n8n.cmd'
    }
    else {
        Write-Muted '  .\scripts\start-local-n8n.cmd'
    }
}
else {
    Write-Body '建議下一步：'
    Write-Muted '  .\scripts\start-local-n8n.cmd'
}
Write-Host ''

if ($script:Fail -gt 0) {
    exit 1
}
exit 0
