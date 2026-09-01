$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$ExampleFile = Join-Path $Root '.env.example'
$BackupFile = Join-Path $Root ('.env.backup.' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
引導建立本專案根目錄的 .env 設定檔。

流程：
  1. 若已有 .env，先改名為 .env.backup.YYYYMMDD-HHMMSS（不會覆蓋舊備份）
  2. 由 .env.example 複製出新的 .env
  3. 詢問部署場景與是否啟用 ngrok，並寫入對應變數
  4. 依場景以互動方式填入必要機密資訊

用法：
  .\scripts\create-envfile.ps1
  .\scripts\create-envfile.cmd
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
function Write-Section([string]$Message) { Write-Host $Message -ForegroundColor Blue }
function Write-Body([string]$Message) { Write-Host $Message -ForegroundColor White }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-Ok([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

function Update-EnvVar([string]$Key, [string]$Value) {
    $value = Get-Sanitized $Value
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

function Get-Sanitized([string]$Value) {
    if ($null -eq $Value) {
        return ''
    }
    return (($Value -replace '[\r\n]+', '')).Trim()
}

function Write-Prompt([string]$Line1, [string]$Line2 = '') {
    Write-Host $Line1 -ForegroundColor Magenta
    if (-not [string]::IsNullOrEmpty($Line2)) {
        Write-Host $Line2 -ForegroundColor Magenta -NoNewline
        Write-Host ' ' -NoNewline
    }
}

function Read-Visible([string]$Line1, [string]$Line2 = '') {
    Write-Prompt $Line1 $Line2
    return [Console]::ReadLine()
}

function Get-Step3Prefix {
    $script:Step3++
    return "【步驟 3-$($script:Step3)】"
}

function Read-RequiredValue {
    param(
        [string]$Line1,
        [string]$Line2 = ''
    )
    while ($true) {
        $value = Get-Sanitized (Read-Visible $Line1 $Line2)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            Write-Host ''
            return $value
        }
        Write-WarnLine '此欄位為必填，請重新輸入。'
    }
}

function Test-NgrokDomain {
    param(
        [string]$Domain,
        [ref]$Message
    )
    $d = Get-Sanitized $Domain
    if ([string]::IsNullOrWhiteSpace($d)) {
        $Message.Value = '此欄位為必填，請重新輸入。'
        return $false
    }
    if ($d -match '(?i)https?://') {
        $Message.Value = '請勿加入通訊協定 (https://)，僅填寫主機名稱。'
        return $false
    }
    if ($d -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') {
        $Message.Value = '網域格式不正確。請填寫至少包含主域名與頂級網域的主機名，例如 example.ngrok-free.dev。'
        return $false
    }
    return $true
}

if (-not (Test-Path -LiteralPath $ExampleFile)) {
    Write-Err "找不到 $ExampleFile，無法建立 .env。"
    exit 1
}

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  n8n 本機環境設定精靈'
Write-Title '════════════════════════════════════════════════════════════'
Write-Host ''
Write-Section '【事前準備】'
Write-Host ''
Write-Body '若需啟用 ngrok 對外通道（Webhook、OAuth 回呼），請先前往'
Write-Host '  https://ngrok.com/' -ForegroundColor Cyan
Write-Body '註冊帳號，並備妥 Auth Token 與固定網域。'
Write-Host ''
Write-Body '若需同步 Google Cloud Run 既有服務（場景 B、C），請先安裝 Google Cloud SDK，'
Write-Body '再以 gcloud 完成身分驗證。'
Write-Host ''
Write-Muted '  Windows：'
Write-Host '    winget install -e --id Google.CloudSDK' -ForegroundColor Cyan
Write-Muted '  macOS：'
Write-Host '    brew install --cask google-cloud-sdk' -ForegroundColor Cyan
Write-Muted '  安裝完成後執行：'
Write-Host '    gcloud auth login' -ForegroundColor Cyan
Write-Host ''
Write-Body '本精靈將引導您建立專案根目錄的 .env 設定檔。'
Write-Body '既有的 .env 會先備份為 .env.backup.YYYYMMDD-HHMMSS，每次執行各自保留。'
Write-Host ''

if (Test-Path -LiteralPath $EnvFile) {
    Write-WarnLine '偵測到既有 .env，將改名為帶時間戳的備份檔。'
    Move-Item -LiteralPath $EnvFile -Destination $BackupFile -Force
    Write-Ok "已備份為 $BackupFile"
}
else {
    Write-Muted '未發現既有 .env，將直接由範本建立。'
}

Copy-Item -LiteralPath $ExampleFile -Destination $EnvFile -Force
Write-Ok "已由 .env.example 建立 $EnvFile"
Write-Host ''

Write-Section '【步驟 1】選擇部署場景'
Write-Host ''
Write-Body '請依資料存放位置選擇下列其中一種場景：'
Write-Host ''
Write-Host '  A  從空白環境開始' -ForegroundColor Cyan
Write-Muted '     使用本機 Postgres。不連線 Google Cloud Run，亦無須設定 gcloud。'
Write-Muted '     適合全新註冊與獨立開發。'
Write-Host ''
Write-Host '  B  繼承 Google Cloud Run 的資料到本機 Postgres' -ForegroundColor Cyan
Write-Muted '     將雲端使用者、憑證與工作流程複製到本機。Cloud Run 與 Supabase 不會被改寫。'
Write-Muted '     適合本機練習，且不想影響線上資料。'
Write-Host ''
Write-Host '  C  本機 n8n 直連遠端 Supabase' -ForegroundColor Cyan
Write-Muted '     與 Cloud Run 共用同一顆資料庫。帳號與流程即為線上那份。'
Write-Muted '     兩邊同時執行時，排程與 Webhook 可能重複觸發。'
Write-Host ''

$Scenario = ''
while ($true) {
    $raw = Get-Sanitized (Read-Visible '請選擇欲採用的場景 [A/B/C]' '（直接按 Enter 採用預設值 A）：')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $raw = 'A'
    }
    $raw = $raw.ToUpperInvariant()
    if ($raw -in @('A', 'B', 'C')) {
        $Scenario = $raw
        break
    }
    Write-WarnLine '無效的選項。請輸入 A、B 或 C。'
}
Write-Ok "已選擇場景 $Scenario。"
Write-Host ''

Write-Section '【步驟 2】是否啟用 ngrok 對外通道'
Write-Host ''
Write-Body 'n8n 若需接收外部 Webhook（例如 Google OAuth 回呼、對外 callback），'
Write-Body '必須透過 ngrok 建立可從外網存取的 HTTPS 通道。'
Write-Host ''
Write-WarnLine '若停用 ngrok，僅能在本機編輯器操作，將無法使用 n8n webhook 對外連線。'
Write-Body '啟用時，稍後將請您提供 Ngrok Auth Token 與固定網域（僅填主機名，請勿加入通訊協定 (https://)）。'
Write-Host ''

$EnableNgrok = ''
while ($true) {
    $raw = Get-Sanitized (Read-Visible '是否啟用 ngrok 整合？[Y/n]' '（直接按 Enter 採用預設值：啟用）：')
    if ([string]::IsNullOrWhiteSpace($raw)) {
        $EnableNgrok = 'true'
        break
    }
    $normalized = $raw.ToLowerInvariant()
    if ($normalized -in @('y', 'yes', 'true', '1', '是')) {
        $EnableNgrok = 'true'
        break
    }
    if ($normalized -in @('n', 'no', 'false', '0', '否')) {
        $EnableNgrok = 'false'
        break
    }
    Write-WarnLine '無效的選項。請輸入 Y（啟用）或 N（停用）。'
}
if ($EnableNgrok -eq 'true') {
    Write-Ok '已啟用 ngrok 整合。'
}
else {
    Write-WarnLine '已停用 ngrok。本機將無法使用對外 webhook。'
}
Write-Host ''

Write-Section "【步驟 3】填寫場景 $Scenario 所需設定"
Write-Host ''
switch ($Scenario) {
    'A' { Write-Body '場景 A 僅需本機 Postgres 密碼。請勿填寫 Cloud Run 或 Supabase 的帳密。' }
    'B' {
        Write-Body '場景 B 需要本機 Postgres 密碼，以及 Google Cloud Run 的專案、區域與服務名稱。'
        Write-Body '後續請再執行 pull-secrets，以寫入加密金鑰與雲端資料庫連線。'
    }
    'C' {
        Write-Body '場景 C 使用遠端 Supabase，無需本機 Postgres 密碼。'
        Write-Body '請提供 Google Cloud Run 的專案、區域與服務名稱，後續再執行 pull-secrets。'
    }
}
if ($EnableNgrok -eq 'true') {
    Write-Body '您已選擇啟用 ngrok，稍後將一併詢問 Auth Token 與網域。'
}
Write-Host ''

$PostgresPassword = ''
$GcpProject = ''
$GcpRegion = ''
$GcpRunService = ''
$NgrokAuthToken = ''
$NgrokDomain = ''
$script:Step3 = 0

if ($Scenario -in @('A', 'B')) {
    $prefix = Get-Step3Prefix
    $PostgresPassword = Read-RequiredValue -Line1 "${prefix}請提供本機 Postgres 資料庫密碼（POSTGRES_PASSWORD）" -Line2 '此密碼僅供本機容器使用，請勿填寫雲端資料庫帳密：'
}

if ($Scenario -in @('B', 'C')) {
    $prefix = Get-Step3Prefix
    $GcpProject = Read-RequiredValue -Line1 "${prefix}請提供 Google Cloud 專案 ID（GCP_PROJECT）："
    $prefix = Get-Step3Prefix
    $GcpRegion = Read-RequiredValue -Line1 "${prefix}請提供 Google Cloud Run 服務所在區域（GCP_REGION），例如 asia-east1："
    $prefix = Get-Step3Prefix
    $GcpRunService = Read-RequiredValue -Line1 "${prefix}請提供 Google Cloud Run 服務名稱（GCP_RUN_SERVICE）："
}

if ($EnableNgrok -eq 'true') {
    $prefix = Get-Step3Prefix
    $NgrokAuthToken = Read-RequiredValue -Line1 "${prefix}請提供 Ngrok Auth Token（NGROK_AUTHTOKEN）" -Line2 '可於 ngrok 官方網站儀表板取得：'
    $prefix = Get-Step3Prefix
    while ($true) {
        $NgrokDomain = Get-Sanitized (Read-Visible "${prefix}請提供 Ngrok 固定網域（NGROK_DOMAIN）" '僅填主機名，例如 example.ngrok-free.dev，請勿加入通訊協定 (https://)：')
        $domainError = ''
        if (Test-NgrokDomain -Domain $NgrokDomain -Message ([ref]$domainError)) {
            Write-Host ''
            break
        }
        Write-WarnLine $domainError
    }
}

Update-EnvVar 'N8N_SCENARIO' $Scenario
Update-EnvVar 'ENABLE_NGROK' $EnableNgrok

if ($PostgresPassword) {
    Update-EnvVar 'POSTGRES_PASSWORD' $PostgresPassword
}
if ($GcpProject) {
    Update-EnvVar 'GCP_PROJECT' $GcpProject
    Update-EnvVar 'GCP_REGION' $GcpRegion
    Update-EnvVar 'GCP_RUN_SERVICE' $GcpRunService
}
if ($EnableNgrok -eq 'true') {
    Update-EnvVar 'NGROK_AUTHTOKEN' $NgrokAuthToken
    Update-EnvVar 'NGROK_DOMAIN' $NgrokDomain
}
else {
    Update-EnvVar 'NGROK_AUTHTOKEN' ''
    Update-EnvVar 'NGROK_DOMAIN' ''
}

Write-Host ''
Write-Ok '────────────────────────────────────────────────────────────'
Write-Ok '  .env 已建立完成。'
Write-Ok '────────────────────────────────────────────────────────────'
Write-Host ''
Write-Body '寫入摘要（機密值不會顯示）：'
Write-Muted "  N8N_SCENARIO=$Scenario"
Write-Muted "  ENABLE_NGROK=$EnableNgrok"
if ($Scenario -in @('A', 'B')) {
    Write-Muted '  POSTGRES_PASSWORD=（已設定）'
}
if ($Scenario -in @('B', 'C')) {
    Write-Muted "  GCP_PROJECT=$GcpProject"
    Write-Muted "  GCP_REGION=$GcpRegion"
    Write-Muted "  GCP_RUN_SERVICE=$GcpRunService"
}
if ($EnableNgrok -eq 'true') {
    Write-Muted '  NGROK_AUTHTOKEN=（已設定）'
    Write-Muted "  NGROK_DOMAIN=$NgrokDomain"
}
else {
    Write-Muted '  NGROK_AUTHTOKEN / NGROK_DOMAIN=（已留空）'
}
if (Test-Path -LiteralPath $BackupFile) {
    Write-Muted "  先前設定備份：$BackupFile"
}

Write-Host ''
Write-Ok '設定精靈結束。'
