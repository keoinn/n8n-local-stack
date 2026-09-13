$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$global:N8N_ORCHESTRATED = $true
$env:N8N_ORCHESTRATED = '1'

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
本機 n8n 工具入口。不帶參數時會顯示選單；有指令時轉發到對應腳本。

用法：
  .\n8n工具程式(Win).cmd
  .\n8n工具程式(Win).cmd <指令> [腳本參數...]

日常：
  start                         開關機（在跑就關、沒在跑就開；尚無 .env 則先建立）
  stop                          關閉容器（保留資料、映像與 .env）
  update                        從 origin/main 更新專案程式碼
  uninstall [--keep-data] [--keep-env] [--keep-images]
                                卸載本機環境

設定與檢查：
  create-env                    引導建立 .env
  check-env                     檢查本機是否就緒
  pull-secrets                  從 GCP 寫入雲端密鑰（場景 B / C）
  start-local [--no-pull]       只依 .env 啟動容器（不跑精靈）
  check-ngrok                   檢查 ngrok 固定網域是否被佔用

資料同步（場景 B）：
  sync-from [--credentials-only] [--keep-exports]
                                從雲端複製到本機
  sync-to [--credentials-only] [--keep-exports] [--yes]
                                把本機資料回寫到雲端

別名：shutdown=stop、env=create-env、check=check-env、
      secrets=pull-secrets、ngrok=check-ngrok

既有的 .\n8n-開關機(Win).cmd、.\scripts\shutdown-n8n.cmd 等仍可單獨執行。
'@ | Write-Host
}

function Write-Title([string]$Message) { Write-Host $Message -ForegroundColor Cyan }
function Write-Body([string]$Message) { Write-Host $Message -ForegroundColor White }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-OkLine([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

function Get-NormalizedCommand([string]$Raw) {
    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return ''
    }
    switch ($Raw.Trim().ToLowerInvariant()) {
        { $_ -in @('start', '1') } { return 'start' }
        { $_ -in @('stop', 'shutdown', '2') } { return 'stop' }
        { $_ -in @('update', '3') } { return 'update' }
        { $_ -in @('uninstall', '4') } { return 'uninstall' }
        { $_ -in @('create-env', 'create-envfile', 'env', '5') } { return 'create-env' }
        { $_ -in @('check-env', 'check', '6') } { return 'check-env' }
        { $_ -in @('pull-secrets', 'secrets', '7') } { return 'pull-secrets' }
        { $_ -in @('start-local', 'start-local-n8n', '8') } { return 'start-local' }
        { $_ -in @('check-ngrok', 'check-ngrok-service', 'ngrok', '9') } { return 'check-ngrok' }
        { $_ -in @('sync-from', 'sync-from-cloud', '10') } { return 'sync-from' }
        { $_ -in @('sync-to', 'sync-to-cloud', '11') } { return 'sync-to' }
        { $_ -in @('0', 'q', 'quit', 'exit') } { return 'quit' }
        { $_ -in @('-h', '--help', 'help', 'h', '/?') } { return 'help' }
        default { return $Raw.Trim().ToLowerInvariant() }
    }
}

function Get-ScriptRelPath([string]$Command) {
    switch ($Command) {
        'start' { return 'scripts\start-n8n.ps1' }
        'stop' { return 'scripts\shutdown-n8n.ps1' }
        'update' { return 'scripts\update-n8n.ps1' }
        'uninstall' { return 'scripts\uninstall-local-n8n.ps1' }
        'create-env' { return 'scripts\create-envfile.ps1' }
        'check-env' { return 'scripts\check-env.ps1' }
        'pull-secrets' { return 'scripts\pull-secrets.ps1' }
        'start-local' { return 'scripts\start-local-n8n.ps1' }
        'check-ngrok' { return 'scripts\check-ngrok-service.ps1' }
        'sync-from' { return 'scripts\sync-from-cloud.ps1' }
        'sync-to' { return 'scripts\sync-to-cloud.ps1' }
        default { return $null }
    }
}

function Show-Menu {
    Write-Host ''
    Write-Title '════════════════════════════════════════════════════════════'
    Write-Title '  n8n 工具選單'
    Write-Title '════════════════════════════════════════════════════════════'
    Write-Host ''
    Write-Host '日常' -ForegroundColor Blue
    Write-Body '  1) start         開關機（在跑就關）'
    Write-Body '  2) stop          關閉容器'
    Write-Body '  3) update        更新專案程式碼'
    Write-Body '  4) uninstall     卸載本機環境'
    Write-Host ''
    Write-Host '設定與檢查' -ForegroundColor Blue
    Write-Body '  5) create-env    引導建立 .env'
    Write-Body '  6) check-env     檢查本機是否就緒'
    Write-Body '  7) pull-secrets  從 GCP 寫入雲端密鑰'
    Write-Body '  8) start-local   只啟動容器（不跑精靈）'
    Write-Body '  9) check-ngrok   檢查 ngrok 是否被佔用'
    Write-Host ''
    Write-Host '資料同步（場景 B）' -ForegroundColor Blue
    Write-Body ' 10) sync-from     從雲端複製到本機'
    Write-Body ' 11) sync-to       把本機回寫到雲端'
    Write-Host ''
    Write-Muted '  也可輸入指令與參數，例如：sync-from --credentials-only'
    Write-Muted '  0) 離開    h) 說明'
    Write-Host ''
}

function Invoke-ToolScript {
    param(
        [Parameter(Mandatory = $true)][string]$RelPath,
        [string[]]$ScriptArgs = @()
    )
    $path = Join-Path $Root $RelPath
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Err "找不到 $path"
        return 1
    }
    if ($ScriptArgs.Count -gt 0) {
        Write-Muted ("  → " + $RelPath + ' ' + ($ScriptArgs -join ' '))
    }
    else {
        Write-Muted ("  → " + $RelPath)
    }
    Write-Host ''

    # 必須在同一個主控台用 `&` 呼叫。另開 powershell.exe 時，雙擊 .cmd
    # 會把子行程 stdin/stdout 接到管線，Write-Host / 確認提示不會出現在視窗裡。
    # 子腳本 stdout 必須 Out-Host，否則 docker 輸出會變成回傳值。
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

function Invoke-ToolCommand {
    param(
        [Parameter(Mandatory = $true)][string]$RawCommand,
        [string[]]$ScriptArgs = @()
    )
    $cmd = Get-NormalizedCommand $RawCommand
    if ([string]::IsNullOrWhiteSpace($cmd)) {
        Write-Err '請指定指令。'
        Show-Usage
        return 1
    }
    if ($cmd -eq 'help') {
        Show-Usage
        return 0
    }
    if ($cmd -eq 'quit') {
        return 0
    }

    $rel = Get-ScriptRelPath $cmd
    if ([string]::IsNullOrWhiteSpace($rel)) {
        Write-Err "未知指令：$RawCommand"
        Show-Usage
        return 1
    }
    return (Invoke-ToolScript -RelPath $rel -ScriptArgs $ScriptArgs)
}

function Invoke-InteractiveMenu {
    while ($true) {
        Show-Menu
        Write-Host '請輸入編號或指令：' -ForegroundColor Magenta -NoNewline
        $line = Read-Host
        if ($null -eq $line) {
            $line = ''
        }
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) {
            Write-WarnLine '沒有輸入。請輸入編號或指令，或按 0 離開。'
            continue
        }

        $parts = @($line -split '\s+' | Where-Object { $_ -ne '' })
        $cmd = Get-NormalizedCommand $parts[0]
        $extra = @()
        if ($parts.Count -gt 1) {
            $extra = $parts[1..($parts.Count - 1)]
        }

        if ($cmd -eq 'quit') {
            Write-OkLine '已離開。'
            return 0
        }
        if ($cmd -eq 'help') {
            Write-Host ''
            Show-Usage
            continue
        }

        Write-Host ''
        $rc = Invoke-ToolCommand -RawCommand $cmd -ScriptArgs $extra
        Write-Host ''
        if ($rc -eq 0) {
            Write-OkLine '指令完成。'
        }
        else {
            Write-WarnLine "指令結束代碼：$rc"
        }
    }
}

Set-Location -LiteralPath $Root

if ($args.Count -eq 0) {
    $null = Invoke-InteractiveMenu
    exit 0
}

$first = [string]$args[0]
$normalized = Get-NormalizedCommand $first
if ($normalized -eq 'help') {
    Show-Usage
    exit 0
}

$rest = @()
if ($args.Count -gt 1) {
    $rest = $args[1..($args.Count - 1)]
}

$code = Invoke-ToolCommand -RawCommand $first -ScriptArgs $rest
exit $code
