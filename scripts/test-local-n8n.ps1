$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$EnvFile = Join-Path $Root '.env'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$Live = $false
$script:Pass = 0
$script:Fail = 0
$script:Skip = 0

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
檢查本機腳本路徑、n8n-tools 轉發，以及啟動精靈的前置判斷。

預設只做安全檢查，不會啟動或停止容器。
加 --live 時會查 Docker 是否真的在跑，並核對啟動精靈會採取的動作。

用法：
  .\scripts\test-local-n8n.cmd
  .\scripts\test-local-n8n.cmd --live
  .\n8n工具程式(Win).cmd test
  .\n8n工具程式(Win).cmd test --live
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--live' { $Live = $true }
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

function Write-Title([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }

function Write-Ok([string]$Message) {
    $script:Pass++
    Write-Host '  PASS  ' -ForegroundColor Green -NoNewline
    Write-Host $Message
}

function Write-Fail([string]$Message) {
    $script:Fail++
    Write-Host '  FAIL  ' -ForegroundColor Red -NoNewline
    Write-Host $Message
}

function Write-Skip([string]$Message) {
    $script:Skip++
    Write-Host '  SKIP  ' -ForegroundColor Yellow -NoNewline
    Write-Host $Message
}

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

function Test-ExpectedFile([string]$Rel) {
    if (Test-Path -LiteralPath (Join-Path $Root $Rel)) {
        Write-Ok "存在 $Rel"
    }
    else {
        Write-Fail "找不到 $Rel"
    }
}

function Test-AbsentRoot([string]$Name) {
    if (Test-Path -LiteralPath (Join-Path $Root $Name)) {
        Write-Fail "不應再放在根目錄：$Name"
    }
    else {
        Write-Ok "根目錄已移除 $Name"
    }
}

function Test-Contains([string]$Rel, [string]$Needle) {
    $path = Join-Path $Root $Rel
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Fail "找不到 $Rel"
        return
    }
    $text = [System.IO.File]::ReadAllText($path, $Utf8NoBom)
    if ($text.Contains($Needle)) {
        Write-Ok "$Rel 含有「$Needle」"
    }
    else {
        Write-Fail "$Rel 缺少「$Needle」"
    }
}

function Test-HelpFile([string]$Rel) {
    $path = Join-Path $Root $Rel
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $path -h *> $null
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    if ($code -eq 0) {
        Write-Ok "$Rel --help"
    }
    else {
        Write-Fail "$Rel --help 失敗"
    }
}

function Test-ProjectRunning {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        return $false
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $ids = @(docker ps -q --filter 'label=com.docker.compose.project=n8n-local' 2>$null | Where-Object { $_ })
    $ErrorActionPreference = $prev
    return ($ids.Count -gt 0)
}

Set-Location -LiteralPath $Root

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  n8n 本機測試'
Write-Title '════════════════════════════════════════════════════════════'
if ($Live) {
    Write-Muted '模式：--live（會查 Docker 實際狀態，仍不會啟動或卸載）'
}
else {
    Write-Muted '模式：安全檢查（加 --live 才查 Docker 實際狀態）'
}

Write-Host ''
Write-Title '檔案位置'
@(
    'n8n-開關機(macOS).sh', 'n8n-開關機(Win).cmd', 'n8n工具程式(macOS).sh', 'n8n工具程式(Win).cmd',
    'compose.yml', 'compose.remote-supabase.yml', '.env.example',
    'scripts\n8n-tools.ps1', 'scripts\start-n8n.ps1',
    'scripts\shutdown-n8n.sh', 'scripts\shutdown-n8n.cmd', 'scripts\shutdown-n8n.ps1',
    'scripts\update-n8n.sh', 'scripts\update-n8n.cmd', 'scripts\update-n8n.ps1',
    'scripts\uninstall-local-n8n.sh', 'scripts\uninstall-local-n8n.cmd', 'scripts\uninstall-local-n8n.ps1',
    'scripts\create-envfile.sh', 'scripts\check-env.sh', 'scripts\pull-secrets.sh',
    'scripts\start-local-n8n.sh', 'scripts\check-ngrok-service.sh',
    'scripts\sync-from-cloud.sh', 'scripts\sync-to-cloud.sh',
    'scripts\test-local-n8n.sh', 'scripts\test-local-n8n.cmd', 'scripts\test-local-n8n.ps1'
) | ForEach-Object { Test-ExpectedFile $_ }

@(
    'shutdown-n8n.sh', 'shutdown-n8n.cmd',
    'update-n8n.sh', 'update-n8n.cmd',
    'uninstall-local-n8n.sh', 'uninstall-local-n8n.cmd'
) | ForEach-Object { Test-AbsentRoot $_ }

Write-Host ''
Write-Title 'n8n-tools 轉發'
Test-HelpFile 'scripts\n8n-tools.ps1'
Test-HelpFile 'scripts\start-n8n.ps1'
Test-HelpFile 'scripts\shutdown-n8n.ps1'
Test-HelpFile 'scripts\update-n8n.ps1'
Test-HelpFile 'scripts\uninstall-local-n8n.ps1'
Test-HelpFile 'scripts\create-envfile.ps1'
Test-HelpFile 'scripts\check-env.ps1'
Test-HelpFile 'scripts\start-local-n8n.ps1'
Test-HelpFile 'scripts\check-ngrok-service.ps1'
Test-HelpFile 'scripts\sync-from-cloud.ps1'
Test-HelpFile 'scripts\sync-to-cloud.ps1'

Write-Host ''
Write-Title '啟動前置邏輯'
Test-Contains 'scripts\start-n8n.ps1' '判定為已初始化'
Test-Contains 'scripts\start-n8n.ps1' '判定為尚未初始化'
Test-Contains 'scripts\start-n8n.ps1' 'Test-ProjectRunning'
Test-Contains 'scripts\start-n8n.ps1' 'Stop-RunningStack'
Test-Contains 'scripts\start-n8n.ps1' '這次改為關閉'
Test-Contains 'n8n-開關機(macOS).sh' 'project_is_running'
Test-Contains 'n8n-開關機(macOS).sh' 'stop_running_stack'

if (Test-Path -LiteralPath $EnvFile) {
    Write-Ok '.env 存在，啟動精靈會判定為已初始化'
    $scenario = (Get-EnvValue 'N8N_SCENARIO').ToUpperInvariant()
    if ([string]::IsNullOrWhiteSpace($scenario)) {
        Write-Fail '.env 有檔，但 N8N_SCENARIO 是空的'
    }
    else {
        Write-Ok "N8N_SCENARIO=$scenario"
    }
}
else {
    Write-Ok '.env 不存在，啟動精靈會判定為尚未初始化並建立設定檔'
}

Write-Host ''
Write-Title 'Docker 執行狀態'
if (-not $Live) {
    Write-Skip '未加 --live，略過 Docker 實際狀態'
}
elseif (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Fail '找不到 docker（啟動精靈會略過執行狀態檢查）'
}
else {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    docker info *> $null
    $dockerOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prev
    if (-not $dockerOk) {
        Write-Fail 'docker daemon 未在執行'
    }
    else {
        Write-Ok 'docker 可用'
        if (Test-ProjectRunning) {
            Write-Ok '偵測到 n8n-local 相關容器正在執行；start-n8n 會關閉後結束'
            Write-Muted '  docker ps --filter label=com.docker.compose.project=n8n-local'
            $ErrorActionPreference = 'Continue'
            docker ps --filter 'label=com.docker.compose.project=n8n-local' --format '  {{.Names}}\t{{.Status}}'
            $ErrorActionPreference = $prev
        }
        else {
            Write-Ok '目前沒有正在執行的 n8n-local 容器；start-n8n 會走啟動流程'
        }
    }
}

Write-Host ''
Write-Title '────────────────────────────────────────────────────────────'
if ($script:Fail -eq 0) {
    Write-Host "  測試通過：$($script:Pass) 通過、$($script:Skip) 略過" -ForegroundColor Green
}
else {
    Write-Host "  測試失敗：$($script:Fail) 失敗、$($script:Pass) 通過、$($script:Skip) 略過" -ForegroundColor Red
}
Write-Title '────────────────────────────────────────────────────────────'
Write-Host ''

if ($script:Fail -ne 0) {
    Exit-N8nScript 1
}
Exit-N8nScript 0
