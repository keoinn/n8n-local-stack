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
