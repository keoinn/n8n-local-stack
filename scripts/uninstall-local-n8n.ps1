$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $Root

$KeepData = $false
$KeepImages = $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
移除本專案的 container、network、Docker volume，以及 compose 用到的 image。
預設一併清空 bind mount 資料夾 data/、exports/（本機 n8n / Postgres 資料）。
不會刪除 .env。

用法：
  .\scripts\uninstall-local-n8n.ps1
  .\scripts\uninstall-local-n8n.ps1 --keep-data     只拆 Docker，保留 data/ 與 exports/
  .\scripts\uninstall-local-n8n.ps1 --keep-images   不刪 n8n / postgres / ngrok 映像
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--keep-data' { $KeepData = $true }
        '--keep-images' { $KeepImages = $true }
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

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Err '找不到 docker。'
    exit 1
}

function Invoke-Docker([object[]]$DockerArgs) {
    & docker @DockerArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}

$downArgs = @('compose', '--profile', 'tunnel', 'down', '--volumes', '--remove-orphans')
if (-not $KeepImages) {
    $downArgs += @('--rmi', 'all')
}

Write-Host '停止並移除本專案 container / network / volume ...'
Invoke-Docker $downArgs
if (Test-Path -LiteralPath (Join-Path $Root 'compose.remote-supabase.yml')) {
    Invoke-Docker (@('compose', '-f', 'compose.yml', '-f', 'compose.remote-supabase.yml') + $downArgs[1..($downArgs.Count - 1)])
}

$projectContainers = @(docker ps -aq --filter 'label=com.docker.compose.project=n8n-local' | Where-Object { $_ })
if ($projectContainers.Count -gt 0) {
    Write-Host '清除殘留 container ...'
    docker rm -f @projectContainers
}

$projectVolumes = @(docker volume ls -q --filter 'label=com.docker.compose.project=n8n-local' | Where-Object { $_ })
if ($projectVolumes.Count -gt 0) {
    Write-Host '清除殘留 Docker volume ...'
    docker volume rm @projectVolumes
}

if (-not $KeepData) {
    Write-Host '清空 bind mount：data/n8n、data/postgres、exports/ ...'
    foreach ($rel in @('data\n8n', 'data\postgres', 'exports')) {
        $path = Join-Path $Root $rel
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
    New-Item -ItemType Directory -Force -Path `
        (Join-Path $Root 'data\n8n'), `
        (Join-Path $Root 'data\postgres'), `
        (Join-Path $Root 'exports') | Out-Null
}

Write-Host ''
Write-Host '完成。.env 有保留。'
if (-not $KeepData) {
    Write-Host '本機 n8n / Postgres 資料已清空，重新測試請再 compose up。'
}
