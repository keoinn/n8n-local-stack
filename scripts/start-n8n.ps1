$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$MarkerFile = Join-Path $Root 'data\.local-bootstrapped'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
引導完成本機 n8n 啟動：

  1. 若尚無 .env，執行 create-envfile
  2. 詢問是否啟用 Code 節點 task runners 與套件清單
  3. 檢查環境（check-env）
  4. 場景 B / C：必要時拉取雲端密鑰（pull-secrets）
  5. 依 .env 啟動 container（start-local-n8n）
  6. 場景 B：首次啟動時同步雲端資料（sync-from-cloud）

之後再執行本腳本，若映像已在本機，只會啟動既有 container，不會重新下載映像。

用法：
  .\start-n8n.cmd
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
function Write-OkLine([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

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

function Invoke-ProjectScript {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$ScriptArgs = @()
    )
    $path = Join-Path $Root "scripts\$Name"
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Err "找不到 $path"
        return 1
    }
    if ($ScriptArgs.Count -gt 0) {
        Write-Muted ("  → scripts\" + $Name + " " + ($ScriptArgs -join ' '))
    }
    else {
        Write-Muted "  → scripts\$Name"
    }
    Write-Host ''

    # 必須在同一個主控台用 `&` 呼叫，設定精靈的提示才會顯示。
    # 子腳本 stdout 必須 Out-Host，否則 docker 輸出會變成回傳值，呼叫端誤判失敗並 exit。
    $code = 0
    try {
        $global:LASTEXITCODE = 0
        if ($ScriptArgs -and $ScriptArgs.Count -gt 0) {
            & $path @ScriptArgs | Out-Host
        }
        else {
            & $path | Out-Host
        }
        $code = 0
    }
    catch {
        $text = @($_.Exception.Message, [string]$_)
        $joined = ($text -join "`n")
        if ($joined -match 'n8n-script-exit:(\d+)') {
            $code = [int]$Matches[1]
        }
        else {
            Write-Err $_.Exception.Message
            $code = 1
        }
    }
    return [int]$code
}

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

function Read-DefaultValue {
    param(
        [string]$Line1,
        [string]$Line2,
        [string]$Default
    )
    $value = Get-Sanitized (Read-Visible $Line1 $Line2)
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = $Default
        Write-OkLine "已採用預設值 $value。"
    }
    Write-Host ''
    return $value
}

function New-RunnersToken {
    $chars = [char[]]((48..57) + (65..90) + (97..122))
    return -join (1..32 | ForEach-Object { $chars | Get-Random })
}

function Apply-RunnersMode([string]$Enabled) {
    if ($Enabled -eq 'true') {
        Update-EnvVar 'ENABLE_N8N_RUNNERS' 'true'
        Update-EnvVar 'N8N_RUNNERS_MODE' 'external'
        Update-EnvVar 'N8N_NATIVE_PYTHON_RUNNER' 'true'
        if (Test-Placeholder (Get-EnvValue 'N8N_RUNNERS_AUTH_TOKEN')) {
            Update-EnvVar 'N8N_RUNNERS_AUTH_TOKEN' (New-RunnersToken)
        }
    }
    else {
        Update-EnvVar 'ENABLE_N8N_RUNNERS' 'false'
        Update-EnvVar 'N8N_RUNNERS_MODE' 'internal'
        Update-EnvVar 'N8N_NATIVE_PYTHON_RUNNER' 'false'
    }
}

function Configure-Runners {
    $current = (Get-EnvValue 'ENABLE_N8N_RUNNERS').ToLowerInvariant()
    if ($current -in @('true', 'false')) {
        Write-Section '【步驟 2】Code 節點與 task runners'
        Apply-RunnersMode $current
        if ($current -eq 'true') {
            Write-OkLine '已啟用 task runners，將依 .env 建立映像並啟動 sidecar。'
            Write-Muted '  若要關閉或改套件清單，請編輯 .env 後再執行本腳本。'
        }
        else {
            Write-OkLine '未啟用 task runners，略過建立映像。'
            Write-Muted '  若之後需要 Code 節點額外套件，請把 .env 的 ENABLE_N8N_RUNNERS 改成 true，或刪除該列後再啟動。'
        }
        Write-Host ''
        return
    }

    Write-Section '【步驟 2】Code 節點與 task runners'
    Write-Host ''
    Write-Body 'Code 節點若要使用額外的 JavaScript / Python 套件（例如 pdf-lib、pymupdf），'
    Write-Body '需要另外啟動 task runners，並建立含這些套件的映像。'
    Write-Host ''
    Write-Body '若你只編輯流程、不需要在 Code 節點安裝額外套件，建議關閉。'
    Write-Body '關閉後不會下載 runners 基底映像，也不會建立自訂映像，啟動較快。'
    Write-Host ''

    while ($true) {
        $raw = Get-Sanitized (Read-Visible '是否啟用 task runners（Code 節點額外套件）？[Y/N]' '（直接按 Enter 採用預設值：停用）：')
        if ([string]::IsNullOrWhiteSpace($raw)) {
            Apply-RunnersMode 'false'
            Write-WarnLine '已停用 task runners。Code 節點只能使用 n8n 內建能力，不會建立 runners 映像。'
            Write-Host ''
            return
        }
        $normalized = $raw.ToLowerInvariant()
        if ($normalized -in @('y', 'yes', 'true', '1', '是')) {
            Apply-RunnersMode 'true'
            Write-OkLine '已啟用 task runners。接下來請確認套件清單，直接按 Enter 即採用預設值。'
            Write-Host ''
            break
        }
        if ($normalized -in @('n', 'no', 'false', '0', '否')) {
            Apply-RunnersMode 'false'
            Write-WarnLine '已停用 task runners。Code 節點只能使用 n8n 內建能力，不會建立 runners 映像。'
            Write-Host ''
            return
        }
        Write-WarnLine '無效的選項。請輸入 Y（啟用）或 N（停用）。'
    }

    $jsBuiltin = Get-EnvValue 'NODE_FUNCTION_ALLOW_BUILTIN'
    $jsExternal = Get-EnvValue 'NODE_FUNCTION_ALLOW_EXTERNAL'
    $pyStdlib = Get-EnvValue 'N8N_RUNNERS_STDLIB_ALLOW'
    $pyPackages = Get-EnvValue 'N8N_RUNNERS_PY_PACKAGES'
    $pyImports = Get-EnvValue 'N8N_RUNNERS_EXTERNAL_ALLOW'
    if ([string]::IsNullOrWhiteSpace($jsBuiltin)) { $jsBuiltin = 'crypto' }
    if ([string]::IsNullOrWhiteSpace($jsExternal)) { $jsExternal = 'pdf-lib' }
    if ([string]::IsNullOrWhiteSpace($pyStdlib)) { $pyStdlib = '*' }
    if ([string]::IsNullOrWhiteSpace($pyPackages)) { $pyPackages = 'pymupdf' }
    if ([string]::IsNullOrWhiteSpace($pyImports)) { $pyImports = 'pymupdf,fitz' }

    Write-Body 'JavaScript Code 節點可 require 的 Node 內建模組。多數情況保留 crypto 即可。'
    $jsBuiltin = Read-DefaultValue -Line1 '請輸入允許的內建模組（逗號分隔）' -Line2 "（直接按 Enter 採用預設值 ${jsBuiltin}）：" -Default $jsBuiltin

    Write-Body '要預先裝進 runners 映像、供 JavaScript Code 節點使用的 npm 套件。'
    Write-Body '改過清單後，下次啟動會重建映像。'
    $jsExternal = Read-DefaultValue -Line1 '請輸入要安裝的 npm 套件（逗號分隔）' -Line2 "（直接按 Enter 採用預設值 ${jsExternal}）：" -Default $jsExternal

    Write-Body 'Python Code 節點可使用的標準庫。填 * 代表全部開放。'
    $pyStdlib = Read-DefaultValue -Line1 '請輸入 N8N_RUNNERS_STDLIB_ALLOW' -Line2 "（直接按 Enter 採用預設值 ${pyStdlib}）：" -Default $pyStdlib

    Write-Body '要 pip 安裝進映像的 Python 套件名稱（安裝名，例如 pymupdf）。'
    $pyPackages = Read-DefaultValue -Line1 '請輸入要安裝的 Python 套件（逗號分隔）' -Line2 "（直接按 Enter 採用預設值 ${pyPackages}）：" -Default $pyPackages

    Write-Body 'Python Code 節點允許 import 的模組名稱。安裝名與 import 名可能不同'
    Write-Body '（例如安裝 pymupdf，程式裡要 import fitz）。'
    $pyImports = Read-DefaultValue -Line1 '請輸入允許 import 的模組（逗號分隔）' -Line2 "（直接按 Enter 採用預設值 ${pyImports}）：" -Default $pyImports

    Update-EnvVar 'NODE_FUNCTION_ALLOW_BUILTIN' $jsBuiltin
    Update-EnvVar 'NODE_FUNCTION_ALLOW_EXTERNAL' $jsExternal
    Update-EnvVar 'N8N_RUNNERS_STDLIB_ALLOW' $pyStdlib
    Update-EnvVar 'N8N_RUNNERS_PY_PACKAGES' $pyPackages
    Update-EnvVar 'N8N_RUNNERS_EXTERNAL_ALLOW' $pyImports

    Write-OkLine 'task runners 套件設定已寫入 .env。'
    Write-Muted "  JS 內建：$jsBuiltin"
    Write-Muted "  JS 外部：$jsExternal"
    Write-Muted "  Python 標準庫：$pyStdlib"
    Write-Muted "  Python 安裝套件：$pyPackages"
    Write-Muted "  Python 可 import：$pyImports"
    Write-Host ''
}

function Write-Bootstrapped([string]$Scenario) {
    Update-EnvVar 'N8N_LOCAL_BOOTSTRAPPED' $Scenario
    try {
        Write-Marker $Scenario
    }
    catch {
        Write-WarnLine "無法寫入啟動紀錄檔：$($_.Exception.Message)"
    }
}

function Write-Marker([string]$Scenario) {
    $dataDir = Join-Path $Root 'data'
    New-Item -ItemType Directory -Force -Path $dataDir | Out-Null
    $stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
    $text = "N8N_SCENARIO=$Scenario`nBOOTSTRAPPED_AT=$stamp`n"
    foreach ($target in @($MarkerFile, (Join-Path $Root '.n8n-local-bootstrapped'))) {
        [System.IO.File]::WriteAllText($target, $text, $Utf8NoBom)
    }
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

function Get-NgrokCheckStatus {
    $path = Join-Path $Root 'data\.ngrok-status'
    if (-not (Test-Path -LiteralPath $path)) {
        return ''
    }
    return ([System.IO.File]::ReadAllText($path, $Utf8NoBom)).Trim()
}

function Write-ReadyBanner {
    $enableNgrok = (Get-EnvValue 'ENABLE_NGROK').ToLowerInvariant()
    $ngrokDomain = Get-EnvValue 'NGROK_DOMAIN'
    $ngrokStatus = Get-NgrokCheckStatus
    if ([string]::IsNullOrWhiteSpace($enableNgrok)) {
        $enableNgrok = 'false'
    }
    $internalUrl = 'http://localhost:5678'
    $externalUrl = ''
    if ($enableNgrok -eq 'true' -and -not [string]::IsNullOrWhiteSpace($ngrokDomain) -and $ngrokDomain -ne 'YOUR_NGROK_DOMAIN') {
        $externalUrl = "https://$ngrokDomain"
    }

    Write-Host ''
    Write-Title '════════════════════════════════════════════════════════════'
    Write-Title '  n8n 已啟動'
    Write-Title '════════════════════════════════════════════════════════════'
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
        Write-OkLine '  請以內部網址開啟本機編輯器；固定網域已被其他設備佔用。'
    }
    else {
        Write-OkLine '  請以內部網址開啟本機編輯器；OAuth / Webhook 請使用外部網址。'
    }
}

function Get-MarkerScenario {
    foreach ($candidate in @($MarkerFile, (Join-Path $Root '.n8n-local-bootstrapped'))) {
        if (-not (Test-Path -LiteralPath $candidate)) {
            continue
        }
        $lines = [System.IO.File]::ReadAllLines($candidate, $Utf8NoBom)
        $raw = ''
        foreach ($line in $lines) {
            $clean = $line.TrimStart([char]0xFEFF)
            if ($clean.StartsWith('N8N_SCENARIO=')) {
                $raw = $clean.Substring('N8N_SCENARIO='.Length)
            }
        }
        $raw = Get-Sanitized $raw
        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            return $raw
        }
    }
    return ''
}

function Test-ProjectContainers {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ids = @(docker ps -aq --filter 'label=com.docker.compose.project=n8n-local' 2>$null | Where-Object { $_ })
    $ErrorActionPreference = $prev
    return ($ids.Count -gt 0)
}

function Test-DockerImage([string]$Image) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker image inspect $Image *> $null
    $ok = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    return $ok
}

function Invoke-Git {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs,
        [switch]$Quiet
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    if ($Quiet) {
        & git -C $Root @GitArgs *> $null
    }
    else {
        & git -C $Root @GitArgs
    }
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    return [int]$code
}

function Update-ProjectIfPossible {
    if ($env:N8N_SKIP_SELF_UPDATE -eq '1') {
        return
    }

    $updateRef = 'main'
    if (-not [string]::IsNullOrWhiteSpace($env:N8N_UPDATE_REF)) {
        $updateRef = $env:N8N_UPDATE_REF.Trim()
    }

    Write-Host ''
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-WarnLine '目前無法自動更新程式碼。'
        Write-WarnLine '若要更新，請先安裝 git 原始碼控制工具：'
        Write-Host '  https://git-scm.com/' -ForegroundColor Cyan
        Write-Host ''
        return
    }

    $inside = Invoke-Git -Quiet -GitArgs @('rev-parse', '--is-inside-work-tree')
    if ($inside -ne 0) {
        Write-WarnLine '目前無法自動更新程式碼。'
        Write-WarnLine '若要更新，請先安裝 git 原始碼控制工具：'
        Write-Host '  https://git-scm.com/' -ForegroundColor Cyan
        Write-Host ''
        return
    }

    Write-Body "正在從 origin/$updateRef 更新專案 ..."

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $status = @(git -C $Root status --porcelain --untracked-files=no 2>$null | Where-Object { $_.Trim() -ne '' })
    $ErrorActionPreference = $prev
    if ($status.Count -gt 0) {
        Write-WarnLine '偵測到本機改過專案檔，已略過自動更新以免覆蓋你的修改。'
        Write-WarnLine '設定請只改 .env。若要更新，請先自行處理本機變更後再啟動。'
        Write-Host ''
        return
    }

    $before = ''
    $ErrorActionPreference = 'Continue'
    $before = ((git -C $Root rev-parse HEAD 2>$null) | Out-String).Trim()
    $ErrorActionPreference = $prev

    if ((Invoke-Git -GitArgs @('fetch', 'origin', $updateRef)) -ne 0) {
        Write-WarnLine '更新失敗，將以目前的程式碼繼續啟動。'
        Write-Host ''
        return
    }

    $branch = ''
    $ErrorActionPreference = 'Continue'
    $branch = ((git -C $Root rev-parse --abbrev-ref HEAD 2>$null) | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ($branch -ne $updateRef) {
        if ((Invoke-Git -GitArgs @('checkout', '-q', $updateRef)) -ne 0) {
            if ((Invoke-Git -GitArgs @('checkout', '-q', '-B', $updateRef, "origin/$updateRef")) -ne 0) {
                Write-WarnLine "無法切換到 $updateRef，將以目前的程式碼繼續啟動。"
                Write-Host ''
                return
            }
        }
    }

    if ((Invoke-Git -GitArgs @('merge', '--ff-only', "origin/$updateRef")) -ne 0) {
        Write-WarnLine "無法快轉到 origin/$updateRef，將以目前的程式碼繼續啟動。"
        Write-Host ''
        return
    }

    $after = ''
    $ErrorActionPreference = 'Continue'
    $after = ((git -C $Root rev-parse HEAD 2>$null) | Out-String).Trim()
    $ErrorActionPreference = $prev
    if ($before -and ($before -eq $after)) {
        Write-OkLine '專案已是最新。'
        Write-Host ''
        return
    }

    Write-OkLine '專案已更新。'
    $env:N8N_SKIP_SELF_UPDATE = '1'
    & $PSCommandPath @args
    exit $LASTEXITCODE
}

Update-ProjectIfPossible

$global:N8N_ORCHESTRATED = $true
$env:N8N_ORCHESTRATED = '1'
Set-Location -LiteralPath $Root

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  n8n 本機啟動精靈'
Write-Title '════════════════════════════════════════════════════════════'

Write-Section '【步驟 1】設定檔'
if (Test-Path -LiteralPath $EnvFile) {
    Write-OkLine '已有 .env，略過建立。'
    Write-Muted '  若要重建，請自行執行 .\scripts\create-envfile.cmd'
}
else {
    Write-Body '尚未找到 .env，開始引導建立。'
    $rc = Invoke-ProjectScript 'create-envfile.ps1'
    if ($rc -ne 0) {
        Write-Err "建立 .env 未完成（結束代碼 $rc）。"
        exit $rc
    }
    if (-not (Test-Path -LiteralPath $EnvFile)) {
        Write-Err '仍找不到 .env，無法繼續。'
        exit 1
    }
    Write-OkLine '設定已寫入，接著設定 Code 節點並啟動 n8n。'
}

Configure-Runners

$scenario = (Get-EnvValue 'N8N_SCENARIO').ToUpperInvariant()
$n8nImage = Get-EnvValue 'N8N_IMAGE'
if ([string]::IsNullOrWhiteSpace($n8nImage)) {
    $n8nImage = 'n8nio/n8n:2.36.8'
}

$envBoot = (Get-EnvValue 'N8N_LOCAL_BOOTSTRAPPED').ToUpperInvariant()
$prevScenario = Get-MarkerScenario
$bootstrapped = (($envBoot -eq $scenario) -or (-not [string]::IsNullOrWhiteSpace($prevScenario) -and $prevScenario -eq $scenario))

$secretsReady = (-not (Test-Placeholder (Get-EnvValue 'N8N_ENCRYPTION_KEY')) -and -not (Test-Placeholder (Get-EnvValue 'CLOUD_DB_POSTGRESDB_HOST')))

$needSecrets = $false
$needSync = $false
switch ($scenario) {
    'B' {
        if (-not $bootstrapped -or -not $secretsReady) { $needSecrets = $true }
        if (-not $bootstrapped) { $needSync = $true }
    }
    'C' {
        if (-not $bootstrapped -or -not $secretsReady) { $needSecrets = $true }
    }
}

Write-Section '【步驟 3】檢查環境'
if ($needSecrets) {
    Write-Muted "  場景 $scenario 首次或密鑰尚未寫入時，check-env 對密鑰的警告可先忽略，下一步會自動拉取。"
}
Write-Host ''
$rc = Invoke-ProjectScript 'check-env.ps1'
if ($rc -ne 0) {
    Write-Err '環境檢查未通過。請修正後再執行 .\start-n8n.cmd'
    exit $rc
}

$noPull = ((Test-DockerImage $n8nImage) -and ($bootstrapped -or (Test-ProjectContainers)))

Write-Section '【步驟 4】雲端密鑰'
switch ($scenario) {
    { $_ -in @('B', 'C') } {
        Write-Body "場景 $scenario 需要 encryption key 與雲端資料庫連線，開始拉取密鑰。"
        $rc = Invoke-ProjectScript 'pull-secrets.ps1'
        if ($rc -ne 0) { exit $rc }
        if (Test-Placeholder (Get-EnvValue 'N8N_ENCRYPTION_KEY')) {
            Write-Err 'pull-secrets 完成後 N8N_ENCRYPTION_KEY 仍是空的，無法繼續。'
            exit 1
        }
    }
    default {
        $label = $scenario
        if ([string]::IsNullOrWhiteSpace($label)) { $label = 'A' }
        Write-OkLine "場景 $label 不需要雲端密鑰。"
    }
}

Write-Section '【步驟 5】啟動 n8n'
if ($noPull) {
    Write-Body '偵測到先前已啟動過，且映像已在本機。此次只啟動 container，不下載映像。'
    $rc = Invoke-ProjectScript 'start-local-n8n.ps1' @('--no-pull')
    if ($rc -ne 0) { exit $rc }
}
else {
    Write-Body '依 .env 啟動容器；本機沒有的映像會在此時下載。'
    $rc = Invoke-ProjectScript 'start-local-n8n.ps1'
    if ($rc -ne 0) { exit $rc }
}

$enableNgrok = (Get-EnvValue 'ENABLE_NGROK').ToLowerInvariant()
if ($enableNgrok -eq 'true') {
    $null = Invoke-ProjectScript 'check-ngrok-service.ps1'
}

$step5Summary = ''
switch ($scenario) {
    'B' {
        if ($needSync) {
            Write-Section '【步驟 6】雲端資料'
            Write-Body '場景 B 首次啟動：將 Cloud Run 資料複製到本機 Postgres。'
            $rc = Invoke-ProjectScript 'sync-from-cloud.ps1'
            if ($rc -ne 0) { exit $rc }
            $step5Summary = '場景 B 已將 Cloud Run 資料複製到本機。'
            try { Write-Bootstrapped $scenario } catch { Write-WarnLine "無法寫入啟動紀錄：$($_.Exception.Message)" }
        }
        else {
            $step5Summary = '場景 B 資料先前已同步，無需再次複製雲端資料。'
        }
    }
    'C' {
        $step5Summary = '場景 C 直連遠端資料庫，無需同步雲端資料。'
    }
    default {
        $step5Summary = '場景 A 從空白環境開始，無需同步雲端資料。'
    }
}

if (-not [string]::IsNullOrWhiteSpace($scenario)) {
    try {
        Write-Bootstrapped $scenario
    }
    catch {
        Write-WarnLine "無法寫入啟動紀錄：$($_.Exception.Message)"
    }
}

Write-ReadyBanner
Write-Section '【步驟 6】雲端資料'
Write-Body $step5Summary
Write-Host ''
Write-OkLine '────────────────────────────────────────────────────────────'
Write-OkLine '  啟動流程完成。'
Write-OkLine '────────────────────────────────────────────────────────────'
Write-Host ''
Write-Muted '之後只要再開一次，執行同一支 .\start-n8n.cmd 即可。'
Write-Host ''
