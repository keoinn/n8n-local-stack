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

function Exit-N8nScript {
    param([int]$Code = 0)
    $global:LASTEXITCODE = $Code
    $orchestrated = ($env:N8N_ORCHESTRATED -eq '1') -or ($true -eq $global:N8N_ORCHESTRATED)
    if ($orchestrated) {
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
