# 供 scripts/*.ps1 以「. $PSScriptRoot\n8n-exit.ps1」載入。
# 獨立執行時用 exit；由 start-n8n 串接時改 throw，避免結束整個 powershell -File 行程。

function Set-N8nConsoleUtf8 {
    $utf8 = New-Object System.Text.UTF8Encoding $false
    try {
        [Console]::OutputEncoding = $utf8
        [Console]::InputEncoding = $utf8
    }
    catch {
    }
    $global:OutputEncoding = $utf8
    $OutputEncoding = $utf8
    try {
        & chcp.com 65001 | Out-Null
    }
    catch {
    }
}

Set-N8nConsoleUtf8

function Test-N8nOrchestrated {
    return (($env:N8N_ORCHESTRATED -eq '1') -or ($true -eq $global:N8N_ORCHESTRATED))
}

function Exit-N8nScript {
    param([int]$Code = 0)
    $global:LASTEXITCODE = $Code
    if (Test-N8nOrchestrated) {
        throw "n8n-script-exit:$Code"
    }
    exit $Code
}

# 開關機等「會再串接子腳本」的入口：先記住自己是不是被工具選單呼叫，
# 再打開 orchestration。自己結束時用 Exit-N8nHost，被選單呼叫才 throw；
# 雙擊 .cmd 時改 exit，避免把 n8n-script-exit:0 噴到畫面上。
function Enable-N8nOrchestration {
    if ($null -eq $script:N8nOrchestrationParent) {
        $script:N8nOrchestrationParent = Test-N8nOrchestrated
    }
    $global:N8N_ORCHESTRATED = $true
    $env:N8N_ORCHESTRATED = '1'
}

function Exit-N8nHost {
    param([int]$Code = 0)
    $fromParent = $false
    if ($null -ne $script:N8nOrchestrationParent) {
        $fromParent = [bool]$script:N8nOrchestrationParent
    }
    else {
        $fromParent = Test-N8nOrchestrated
    }
    $global:LASTEXITCODE = $Code
    if ($fromParent) {
        throw "n8n-script-exit:$Code"
    }
    exit $Code
}

# 父腳本用 `| Out-Host` 串接時，`& docker` 的 stdout 會變成管線，
# compose 進度列會報「failed to get console」。Start-Process -NoNewWindow
# 讓 docker 寫回原本的 cmd / Windows Terminal 視窗。
function Invoke-DockerOnConsole {
    param(
        [Parameter(Mandatory = $true)][object[]]$DockerArgs,
        [string]$WorkingDirectory = '',
        [switch]$PassThru
    )
    if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $WorkingDirectory = (Get-Location).Path
    }
    $docker = (Get-Command docker -ErrorAction Stop).Source
    $argList = @($DockerArgs | ForEach-Object { [string]$_ })
    $p = Start-Process -FilePath $docker -ArgumentList $argList -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru
    $code = 1
    if ($p) {
        $code = [int]$p.ExitCode
    }
    $global:LASTEXITCODE = $code
    if ($PassThru) {
        return $code
    }
    if ($code -ne 0) {
        Exit-N8nScript $code
    }
}
