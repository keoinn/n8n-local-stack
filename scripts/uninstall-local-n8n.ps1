$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $Root

$KeepData = $false
$KeepImages = $false
$KeepEnv = $false

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function Show-Usage {
    @'
移除本專案的 container、network、Docker volume，以及 compose 用到的 image。
預設一併清空 bind mount 資料夾 data/、exports/，並刪除 .env。
不會刪各目錄的 .gitkeep。

用法：
  .\uninstall-local-n8n.cmd
  .\uninstall-local-n8n.cmd --keep-data     只拆 Docker，保留 data/ 與 exports/
  .\uninstall-local-n8n.cmd --keep-env      保留 .env
  .\uninstall-local-n8n.cmd --keep-images   不刪 n8n / postgres / ngrok 映像
'@ | Write-Host
}

foreach ($arg in $args) {
    switch ($arg) {
        '--keep-data' { $KeepData = $true }
        '--keep-env' { $KeepEnv = $true }
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

$downArgs = @('compose', '--profile', 'tunnel', '--profile', 'runners', 'down', '--volumes', '--remove-orphans')
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

function Clear-BindMountDir([string]$Rel) {
    $path = Join-Path $Root $Rel
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    Get-ChildItem -LiteralPath $path -Force | Where-Object { $_.Name -ne '.gitkeep' } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
    $gitkeep = Join-Path $path '.gitkeep'
    if (-not (Test-Path -LiteralPath $gitkeep)) {
        New-Item -ItemType File -Path $gitkeep | Out-Null
    }
}

if (-not $KeepData) {
    Write-Host '清空 bind mount：data/n8n、data/postgres、exports/（保留 .gitkeep）...'
    $marker = Join-Path $Root 'data\.local-bootstrapped'
    $markerRoot = Join-Path $Root '.n8n-local-bootstrapped'
    foreach ($path in @($marker, $markerRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    foreach ($rel in @('data\n8n', 'data\postgres', 'exports')) {
        Clear-BindMountDir $rel
    }
}

if (-not $KeepEnv) {
    $envPath = Join-Path $Root '.env'
    if (Test-Path -LiteralPath $envPath) {
        Write-Host '刪除 .env ...'
        Remove-Item -LiteralPath $envPath -Force
    }
}
elseif (-not $KeepData) {
    $envPath = Join-Path $Root '.env'
    if (Test-Path -LiteralPath $envPath) {
        Write-Host '資料已清空，清除 .env 的 N8N_LOCAL_BOOTSTRAPPED ...'
        $utf8 = New-Object System.Text.UTF8Encoding $false
        $lines = [System.IO.File]::ReadAllLines($envPath, $utf8)
        $out = New-Object System.Collections.Generic.List[string]
        $found = $false
        foreach ($existing in $lines) {
            if (-not $found -and $existing.StartsWith('N8N_LOCAL_BOOTSTRAPPED=') -and -not $existing.StartsWith('#')) {
                $out.Add("N8N_LOCAL_BOOTSTRAPPED=''")
                $found = $true
            }
            else {
                $out.Add($existing)
            }
        }
        if (-not $found) {
            $out.Add("N8N_LOCAL_BOOTSTRAPPED=''")
        }
        [System.IO.File]::WriteAllText($envPath, (($out -join "`n") + "`n"), $utf8)
    }
}

Write-Host ''
if ($KeepEnv) {
    Write-Host '完成。.env 有保留。'
}
else {
    Write-Host '完成。.env 已刪除。'
}
if (-not $KeepData) {
    Write-Host '本機 n8n / Postgres 資料已清空，重新測試請再 compose up。'
}
