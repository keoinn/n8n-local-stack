@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
set "N8N_CRED_SELF=%~f0"
set "N8N_CRED_ROOT=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$enc = New-Object System.Text.UTF8Encoding $false; $raw = [System.IO.File]::ReadAllText($env:N8N_CRED_SELF, $enc); $mark = [string][char]13 + [string][char]10 + '#POWERSHELL' + [string][char]13 + [string][char]10; $i = $raw.IndexOf($mark); if ($i -lt 0) { [Console]::Error.WriteLine('POWERSHELL marker missing'); exit 1 }; $code = $raw.Substring($i + $mark.Length); $sb = [scriptblock]::Create($code); & $sb %*"
set "EXITCODE=%ERRORLEVEL%"
echo.
echo 按下任意鍵關閉視窗
pause >nul
exit /b %EXITCODE%
#POWERSHELL
param(
    [Parameter(Position = 0)]
    [string]$Action = '',
    [Alias('y')]
    [switch]$Yes,
    [Alias('h')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'
# PowerShell 7 會把原生程式的 stderr 當成錯誤；docker 的提示不應中斷腳本。
$PSNativeCommandUseErrorActionPreference = $false

function Set-ConsoleUtf8 {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        [Console]::OutputEncoding = $utf8
        [Console]::InputEncoding = $utf8
    }
    catch {
    }
    $global:OutputEncoding = $utf8
    $script:OutputEncoding = $utf8
    try {
        & chcp.com 65001 | Out-Null
    }
    catch {
    }
}

Set-ConsoleUtf8

$Root = $env:N8N_CRED_ROOT
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = $PSScriptRoot
}
$Root = [System.IO.Path]::GetFullPath($Root)
$CredentialDir = Join-Path $Root 'credential_files'
$ComposeFile = Join-Path $Root 'compose.yml'

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
把目前這台機器上的 n8n Docker 憑證匯出成檔案，或從檔案匯回。

匯出會在這個腳本同一層建立 credential_files，並把每筆憑證寫成一個 JSON。
匯入只讀取 credential_files；資料夾不存在就停止，不會建立資料夾。

用法：
  .\n8n憑證匯出匯入.cmd              顯示選單
  .\n8n憑證匯出匯入.cmd export       匯出到 credential_files\
  .\n8n憑證匯出匯入.cmd import       從 credential_files\ 匯入
  .\n8n憑證匯出匯入.cmd import -Yes  匯入時略過確認

執行前請先啟動本機 n8n。
JSON 內是解密後的明文（含 OAuth Client Secret），請勿提交到 git。
匯入時會用這台 n8n 目前的金鑰重新加密。
'@ | Write-Host
}

$ExportsDir = Join-Path $Root 'exports'
$ExportStagingDir = Join-Path $ExportsDir '_credential_export_tmp'
$ImportStagingDir = Join-Path $ExportsDir '_credential_import_tmp'

function Invoke-Docker {
    param([Parameter(Mandatory = $true)][string[]]$DockerArgs)
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        throw "docker 指令失敗（結束代碼 $LASTEXITCODE）。"
    }
}

function Assert-ComposeReady {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Write-Err '找不到 docker。請先安裝並啟動 Docker Desktop。'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $ComposeFile -PathType Leaf)) {
        Write-Err "找不到 Docker Compose 檔：$ComposeFile"
        exit 1
    }
    Set-Location -LiteralPath $Root
}

function Get-CredentialFiles {
    if (-not (Test-Path -LiteralPath $CredentialDir -PathType Container)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $CredentialDir -Filter '*.json' -File)
}

function Remove-StagingDir([string]$Path) {
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Test-N8nContainerRunning {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $id = @(
            & docker compose ps --status running -q n8n 2>$null |
                ForEach-Object { "$_".Trim() } |
                Where-Object { $_ }
        ) | Select-Object -First 1
        return [bool]$id
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-N8nCli {
    param([Parameter(Mandatory = $true)][string[]]$CliArgs)
    # 用正在跑的容器，才會用到同一把加密金鑰。不要另掛資料夾。
    if (Test-N8nContainerRunning) {
        Invoke-Docker (@('compose', 'exec', '-T', 'n8n', 'n8n') + $CliArgs)
        return
    }
    Invoke-Docker (@('compose', 'run', '--rm', '--no-deps', 'n8n') + $CliArgs)
}

function Invoke-N8nNode {
    param([Parameter(Mandatory = $true)][string]$ScriptInContainer)
    if (Test-N8nContainerRunning) {
        Invoke-Docker @('compose', 'exec', '-T', 'n8n', 'node', $ScriptInContainer)
        return
    }
    Invoke-Docker @('compose', 'run', '--rm', '--no-deps', '--entrypoint', 'node', 'n8n', $ScriptInContainer)
}

function Convert-PlainCredentialData {
    # data 若是「字串包著的 JSON 物件」，匯入會把它當密文原樣寫回，OAuth Client Secret 會壞掉。
    # 密文（不是 { 開頭）保持不動。
    $jsPath = Join-Path $ExportsDir '_normalize_credentials.js'
    $js = @'
const fs = require('fs');
const path = require('path');
const dir = '/exports/_credential_import_tmp';
for (const name of fs.readdirSync(dir)) {
  if (!name.endsWith('.json')) continue;
  const full = path.join(dir, name);
  const credential = JSON.parse(fs.readFileSync(full, 'utf8'));
  if (typeof credential.data !== 'string') continue;
  const trimmed = credential.data.trim();
  if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) continue;
  try {
    const parsed = JSON.parse(trimmed);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) continue;
    credential.data = parsed;
    fs.writeFileSync(full, JSON.stringify(credential, null, 2));
  } catch (error) {}
}
'@
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($jsPath, $js.Replace("`n", "`r`n"), $utf8)
    try {
        Invoke-N8nNode '/exports/_normalize_credentials.js'
    }
    finally {
        if (Test-Path -LiteralPath $jsPath) {
            Remove-Item -LiteralPath $jsPath -Force
        }
    }
}

function Write-OAuthSecretWarnings {
    param([System.IO.FileInfo[]]$Files)
    foreach ($file in $Files) {
        try {
            $raw = [System.IO.File]::ReadAllText($file.FullName)
            $credential = $raw | ConvertFrom-Json
        }
        catch {
            continue
        }
        if ($null -eq $credential.data -or $credential.data -is [string]) {
            continue
        }
        $secretProperty = $credential.data.PSObject.Properties['clientSecret']
        if ($null -eq $secretProperty) {
            continue
        }
        $secret = [string]$secretProperty.Value
        $name = [string]$credential.name
        $type = [string]$credential.type
        if ($secret -eq '' -or $secret.Contains('__n8n_BLANK_VALUE_')) {
            Write-Host "警告：$name（$type）的 Client Secret 是空的，或是畫面用的遮罩字。OAuth 匯入後會失敗，請先在 n8n 重新貼上 Client Secret 再匯出。"
        }
    }
}

function Export-N8nCredentials {
    Assert-ComposeReady
    if (-not (Test-Path -LiteralPath $ExportsDir)) {
        New-Item -ItemType Directory -Path $ExportsDir | Out-Null
    }
    if (-not (Test-Path -LiteralPath $CredentialDir)) {
        New-Item -ItemType Directory -Path $CredentialDir | Out-Null
        Write-Host "已建立資料夾：$CredentialDir"
    }
    Remove-StagingDir $ExportStagingDir
    New-Item -ItemType Directory -Path $ExportStagingDir | Out-Null
    Write-Host '正在從本機 n8n 解密並匯出憑證 ...'
    try {
        Invoke-N8nCli @(
            'export:credentials', '--all', '--decrypted', '--pretty', '--separate',
            '--output=/exports/_credential_export_tmp'
        )
    }
    catch {
        Remove-StagingDir $ExportStagingDir
        Write-Err $_.Exception.Message
        exit 1
    }
    $staged = @(Get-ChildItem -LiteralPath $ExportStagingDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($staged.Count -eq 0) {
        Remove-StagingDir $ExportStagingDir
        Write-Host '本機 n8n 目前沒有憑證，credential_files 維持原狀。'
        return
    }
    $old = Get-CredentialFiles
    foreach ($file in $old) {
        Remove-Item -LiteralPath $file.FullName -Force
    }
    foreach ($file in $staged) {
        Move-Item -LiteralPath $file.FullName -Destination (Join-Path $CredentialDir $file.Name) -Force
    }
    Remove-StagingDir $ExportStagingDir
    $files = Get-CredentialFiles
    Write-OAuthSecretWarnings $files
    Write-Host ''
    Write-Host "已匯出 $($files.Count) 個憑證："
    $instCount = 0
    foreach ($file in $files) {
        $extraDesc = ''
        try {
            $credObj = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            if ($credObj.usageScope -eq 'instance') {
                $instCount++
                $extraDesc = " [instance 系統設定: $($credObj.name)]"
            }
        }
        catch {}
        Write-Host "  $($file.Name)$extraDesc"
    }
    if ($instCount -gt 0) {
        Write-Host ''
        Write-Host "附註：其中有 $instCount 個為 instance 系統設定憑證（例如 AI Assistant 模型）。" -ForegroundColor DarkGray
        Write-Host '匯出僅供備份參考；匯入時會自動略過以避免 n8n CLI 限制，如需變更請在 n8n 網頁的 Settings -> AI Assistant 設定。' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host "檔案位置：$CredentialDir"
    Write-Host '這些 JSON 含明文 Client Secret 與 API token，不要提交到 git。'
}

function Import-N8nCredentials {
    param([switch]$AssumeYes)
    if (-not (Test-Path -LiteralPath $CredentialDir -PathType Container)) {
        Write-Err "找不到資料夾 $CredentialDir，已停止匯入。"
        Write-Err '請先執行匯出，或把憑證 JSON 放到腳本同層的 credential_files 後再匯入。'
        exit 1
    }
    $files = Get-CredentialFiles
    if ($files.Count -eq 0) {
        Write-Err 'credential_files 裡沒有 JSON 檔，已停止匯入。'
        exit 1
    }
    Assert-ComposeReady

    $projectFiles = @()
    $instanceFiles = @()
    $oldEncrypted = @()

    foreach ($file in $files) {
        $isInstance = $false
        $credName = ''
        try {
            $existing = [System.IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json
            if ($existing.usageScope -eq 'instance') {
                $isInstance = $true
                $credName = [string]$existing.name
            }
            $dataText = [string]$existing.data
            if ($existing.data -is [string] -and -not $dataText.Trim().StartsWith('{')) {
                $oldEncrypted += $file.Name
            }
        }
        catch {
        }

        if ($isInstance) {
            $instanceFiles += @{
                FileName = $file.Name
                Name = $credName
            }
        }
        else {
            $projectFiles += $file
        }
    }

    if ($instanceFiles.Count -gt 0) {
        Write-Host ''
        Write-Host "注意：偵測到 $($instanceFiles.Count) 個 instance 系統設定憑證（例如 AI Assistant 模型）：" -ForegroundColor Yellow
        foreach ($inst in $instanceFiles) {
            Write-Host "  - $($inst.FileName) ($($inst.Name))" -ForegroundColor Yellow
        }
        Write-Host '說明：n8n CLI 限制不支援匯入已關聯的 instance 憑證（會產生 Unknown instance credential use 錯誤）。' -ForegroundColor Yellow
        Write-Host '腳本會自動略過這些檔案；AI Assistant 如需設定請至 n8n 網頁介面 Settings -> AI Assistant。' -ForegroundColor Yellow
        Write-Host ''
    }

    if ($projectFiles.Count -eq 0) {
        Write-Host 'credential_files 內無可匯入的專案憑證（僅有 instance 系統憑證），已停止匯入。'
        return
    }

    Write-Host "將從 credential_files 匯入 $($projectFiles.Count) 個專案憑證到本機 n8n："
    foreach ($file in $projectFiles) {
        Write-Host "  $($file.Name)"
    }

    if ($oldEncrypted.Count -gt 0) {
        Write-Host ''
        Write-Host '這些檔是舊的加密匯出，OAuth Client Secret 可能是錯的。請先重新匯出再匯入：' -ForegroundColor Yellow
        foreach ($name in $oldEncrypted) {
            Write-Host "  $name" -ForegroundColor Yellow
        }
    }

    if (-not $AssumeYes) {
        Write-Host ''
        $answer = (Read-Host '繼續匯入嗎？(y/N)').Trim()
        if ($answer -notin @('y', 'Y', 'yes', 'YES')) {
            Write-Host '已取消匯入。'
            return
        }
    }

    if (-not (Test-Path -LiteralPath $ExportsDir)) {
        New-Item -ItemType Directory -Path $ExportsDir | Out-Null
    }
    Remove-StagingDir $ImportStagingDir
    New-Item -ItemType Directory -Path $ImportStagingDir | Out-Null
    foreach ($file in $projectFiles) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $ImportStagingDir $file.Name) -Force
    }
    Convert-PlainCredentialData
    Write-Host '正在匯入憑證（OAuth Client Secret 會用目前的金鑰重新加密）...'
    try {
        Invoke-N8nCli @(
            'import:credentials', '--separate', '--input=/exports/_credential_import_tmp'
        )
    }
    catch {
        Remove-StagingDir $ImportStagingDir
        Write-Err $_.Exception.Message
        exit 1
    }
    Remove-StagingDir $ImportStagingDir
    Write-Host ''
    Write-Host '憑證已匯入本機 n8n。若編輯器已開著，重新整理後即可看到。'
    Write-Host 'OAuth 憑證畫面裡的 Client Secret 會顯示成空白，那是遮罩，不代表密碼遺失。請直接按連接測試，不要在空白欄按儲存。'
}

if ($Help -or $Action -in @('-h', '--help', '/?', 'help')) {
    Show-Usage
    exit 0
}

$action = ''
switch -Regex ($Action) {
    '^(export|匯出)$' { $action = 'export' }
    '^(import|匯入)$' { $action = 'import' }
    '^$' { }
    default {
        Write-Err "未知參數：$Action"
        Show-Usage
        exit 1
    }
}

if (-not $action) {
    Show-Usage
    Write-Host ''
    Write-Host '  1) 匯出憑證到 credential_files'
    Write-Host '  2) 從 credential_files 匯入憑證'
    Write-Host '  q) 離開'
    Write-Host ''
    $choice = (Read-Host '請選擇').Trim()
    switch ($choice) {
        '1' { $action = 'export' }
        '2' { $action = 'import' }
        { $_ -in @('q', 'Q', '') } { exit 0 }
        default {
            Write-Err "無法辨識的選項：$choice"
            exit 1
        }
    }
}

switch ($action) {
    'export' { Export-N8nCredentials }
    'import' { Import-N8nCredentials -AssumeYes:$Yes }
}
