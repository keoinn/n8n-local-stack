$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'n8n-exit.ps1')

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$UpdateRef = 'main'
if (-not [string]::IsNullOrWhiteSpace($env:N8N_UPDATE_REF)) {
    $UpdateRef = $env:N8N_UPDATE_REF.Trim()
}

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
從 origin/main 更新本專案程式碼。

會 fetch、切到 main，再快轉合併。不會還原或丟棄你改過的檔案。
.env 與 data/ 不受影響。若偵測到本機改過專案檔，會停止更新。

用法：
  .\scripts\update-n8n.cmd
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
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
function Write-Body([string]$Message) { Write-Host $Message -ForegroundColor White }
function Write-Muted([string]$Message) { Write-Host $Message -ForegroundColor DarkGray }
function Write-OkLine([string]$Message) { Write-Host $Message -ForegroundColor Green }
function Write-WarnLine([string]$Message) { Write-Host $Message -ForegroundColor Yellow }

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

Write-Host ''
Write-Title '════════════════════════════════════════════════════════════'
Write-Title '  更新本機 n8n 專案'
Write-Title '════════════════════════════════════════════════════════════'
Write-Host ''

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 git，無法更新程式碼。'
    Write-Body '請先安裝 git 原始碼控制工具：'
    Write-Host '  https://git-scm.com/' -ForegroundColor Cyan
    Exit-N8nScript 1
}

$inside = Invoke-Git -Quiet -GitArgs @('rev-parse', '--is-inside-work-tree')
if ($inside -ne 0) {
    Write-Err '找不到 git，無法更新程式碼。'
    Write-Body '請先安裝 git 原始碼控制工具：'
    Write-Host '  https://git-scm.com/' -ForegroundColor Cyan
    Exit-N8nScript 1
}

Write-Body "正在從 origin/$UpdateRef 更新專案 ..."

$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$status = @(git -C $Root status --porcelain --untracked-files=no 2>$null | Where-Object { $_.Trim() -ne '' })
$ErrorActionPreference = $prev
if ($status.Count -gt 0) {
    Write-Err '偵測到本機改過專案檔，已停止更新以免覆蓋你的修改。'
    Write-WarnLine '設定請只改 .env。若要更新，請先自行處理本機變更後再執行 .\scripts\update-n8n.cmd。'
    Exit-N8nScript 1
}

$before = ''
$ErrorActionPreference = 'Continue'
$before = ((git -C $Root rev-parse HEAD 2>$null) | Out-String).Trim()
$ErrorActionPreference = $prev

if ((Invoke-Git -GitArgs @('fetch', 'origin', $UpdateRef)) -ne 0) {
    Write-Err "從 origin/$UpdateRef 更新失敗。"
    Exit-N8nScript 1
}

$branch = ''
$ErrorActionPreference = 'Continue'
$branch = ((git -C $Root rev-parse --abbrev-ref HEAD 2>$null) | Out-String).Trim()
$ErrorActionPreference = $prev
if ($branch -ne $UpdateRef) {
    if ((Invoke-Git -GitArgs @('checkout', '-q', $UpdateRef)) -ne 0) {
        if ((Invoke-Git -GitArgs @('checkout', '-q', '-B', $UpdateRef, "origin/$UpdateRef")) -ne 0) {
            Write-Err "無法切換到 $UpdateRef。"
            Exit-N8nScript 1
        }
    }
}

if ((Invoke-Git -GitArgs @('merge', '--ff-only', "origin/$UpdateRef")) -ne 0) {
    Write-Err "無法快轉到 origin/$UpdateRef。"
    Exit-N8nScript 1
}

$after = ''
$ErrorActionPreference = 'Continue'
$after = ((git -C $Root rev-parse HEAD 2>$null) | Out-String).Trim()
$ErrorActionPreference = $prev

Write-Host ''
if ($before -and ($before -eq $after)) {
    Write-OkLine '────────────────────────────────────────────────────────────'
    Write-OkLine '  專案已是最新。'
    Write-OkLine '────────────────────────────────────────────────────────────'
}
else {
    Write-OkLine '────────────────────────────────────────────────────────────'
    Write-OkLine '  專案已更新。'
    Write-OkLine '────────────────────────────────────────────────────────────'
}
Write-Host ''
Write-Muted '之後要啟動，請執行 .\n8n-開關機(Win).cmd'
Write-Host ''
