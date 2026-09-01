@echo off
setlocal EnableExtensions DisableDelayedExpansion
chcp 65001 >nul

REM =============================================================================
REM n8n 本機環境設定精靈（Windows cmd）
REM 互動流程於本檔案實作；寫入 .env 委由 PowerShell 處理，
REM 以避免 cmd 展開密碼中的特殊字元。
REM =============================================================================

if /i "%~1"=="-h" goto :help
if /i "%~1"=="--help" goto :help
if /i "%~1"=="/?" goto :help
if not "%~1"=="" (
  echo 未知參數：%~1 >&2
  echo. >&2
  goto :help
)

for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "ENV_FILE=%ROOT%\.env"
set "EXAMPLE_FILE=%ROOT%\.env.example"
set "BACKUP_FILE="
set "UPSERT_FILE=%ENV_FILE%"

for /f "delims=" %%A in ('echo prompt $E^| cmd') do set "ESC=%%A"
set "C0=%ESC%[0m"
set "CB=%ESC%[1m"
set "CR=%ESC%[31m"
set "CG=%ESC%[32m"
set "CY=%ESC%[33m"
set "CU=%ESC%[34m"
set "CM=%ESC%[35m"
set "CC=%ESC%[36m"
set "CW=%ESC%[97m"
set "CD=%ESC%[2m"

where powershell >nul 2>&1
if errorlevel 1 (
  echo %CR%找不到 powershell，無法安全寫入 .env。%C0% >&2
  exit /b 1
)

if not exist "%EXAMPLE_FILE%" (
  echo %CR%找不到 %EXAMPLE_FILE%，無法建立 .env。%C0% >&2
  exit /b 1
)

echo.
echo %CB%%CC%════════════════════════════════════════════════════════════%C0%
echo %CB%%CC%  n8n 本機環境設定精靈%C0%
echo %CB%%CC%════════════════════════════════════════════════════════════%C0%
echo.
echo %CB%%CU%【事前準備】%C0%
echo.
echo %CW%若需啟用 ngrok 對外通道（Webhook、OAuth 回呼），請先前往%C0%
echo %CC%  https://ngrok.com/%C0%
echo %CW%註冊帳號，並備妥 Auth Token 與固定網域。%C0%
echo.
echo %CW%若需同步 Google Cloud Run 既有服務（場景 B、C），請先安裝 Google Cloud SDK，%C0%
echo %CW%再以 gcloud 完成身分驗證。%C0%
echo.
echo %CD%  Windows：%C0%
echo %CC%    winget install -e --id Google.CloudSDK%C0%
echo %CD%  macOS：%C0%
echo %CC%    brew install --cask google-cloud-sdk%C0%
echo %CD%  安裝完成後執行：%C0%
echo %CC%    gcloud auth login%C0%
echo.
echo %CW%本精靈將引導您建立專案根目錄的 .env 設定檔。%C0%
echo %CW%既有的 .env 會先備份為 .env.backup.YYYYMMDD-HHMMSS，每次執行各自保留。%C0%
echo.

if exist "%ENV_FILE%" goto :backup_env
echo %CD%未發現既有 .env，將直接由範本建立。%C0%
goto :after_backup
:backup_env
echo %CY%偵測到既有 .env，將改名為帶時間戳的備份檔。%C0%
for /f "usebackq delims=" %%I in (`powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"`) do set "STAMP=%%I"
set "BACKUP_FILE=%ROOT%\.env.backup.%STAMP%"
move /y "%ENV_FILE%" "%BACKUP_FILE%" >nul
echo %CG%已備份為 %BACKUP_FILE%%C0%
:after_backup

copy /y "%EXAMPLE_FILE%" "%ENV_FILE%" >nul
echo %CG%已由 .env.example 建立 %ENV_FILE%%C0%
echo.

echo %CB%%CU%【步驟 1】選擇部署場景%C0%
echo.
echo %CW%請依資料存放位置選擇下列其中一種場景：%C0%
echo.
echo %CB%%CC%  A%C0%  從空白環境開始
echo %CD%     使用本機 Postgres。不連線 Google Cloud Run，亦無須設定 gcloud。%C0%
echo %CD%     適合全新註冊與獨立開發。%C0%
echo.
echo %CB%%CC%  B%C0%  繼承 Google Cloud Run 的資料到本機 Postgres
echo %CD%     將雲端使用者、憑證與工作流程複製到本機。Cloud Run 與 Supabase 不會被改寫。%C0%
echo %CD%     適合本機練習，且不想影響線上資料。%C0%
echo.
echo %CB%%CC%  C%C0%  本機 n8n 直連遠端 Supabase
echo %CD%     與 Cloud Run 共用同一顆資料庫。帳號與流程即為線上那份。%C0%
echo %CD%     兩邊同時執行時，排程與 Webhook 可能重複觸發。%C0%
echo.

:ask_scenario
set "SCENARIO="
call :Prompt "請選擇欲採用的場景 [A/B/C]" "（直接按 Enter 採用預設值 A）："
set /p "SCENARIO="
if not defined SCENARIO set "SCENARIO=A"
if /i "%SCENARIO%"=="A" set "SCENARIO=A" & goto :scenario_ok
if /i "%SCENARIO%"=="B" set "SCENARIO=B" & goto :scenario_ok
if /i "%SCENARIO%"=="C" set "SCENARIO=C" & goto :scenario_ok
echo %CY%無效的選項。請輸入 A、B 或 C。%C0%
goto :ask_scenario
:scenario_ok
echo %CG%已選擇場景 %SCENARIO%。%C0%
echo.

echo %CB%%CU%【步驟 2】是否啟用 ngrok 對外通道%C0%
echo.
echo %CW%n8n 若需接收外部 Webhook（例如 Google OAuth 回呼、對外 callback），%C0%
echo %CW%必須透過 ngrok 建立可從外網存取的 HTTPS 通道。%C0%
echo.
echo %CY%若停用 ngrok，僅能在本機編輯器操作，將無法使用 n8n webhook 對外連線。%C0%
echo %CW%啟用時，稍後將請您提供 Ngrok Auth Token 與固定網域（僅填主機名，請勿加入通訊協定 (https://)）。%C0%
echo.

:ask_ngrok
set "ENABLE_NGROK="
set "NGROK_ANSWER="
call :Prompt "是否啟用 ngrok 整合？[Y/n]" "（直接按 Enter 採用預設值：啟用）："
set /p "NGROK_ANSWER="
if not defined NGROK_ANSWER set "NGROK_ANSWER=Y"
if /i "%NGROK_ANSWER%"=="Y" goto :ngrok_yes
if /i "%NGROK_ANSWER%"=="YES" goto :ngrok_yes
if /i "%NGROK_ANSWER%"=="TRUE" goto :ngrok_yes
if /i "%NGROK_ANSWER%"=="1" goto :ngrok_yes
if /i "%NGROK_ANSWER%"=="是" goto :ngrok_yes
if /i "%NGROK_ANSWER%"=="N" goto :ngrok_no
if /i "%NGROK_ANSWER%"=="NO" goto :ngrok_no
if /i "%NGROK_ANSWER%"=="FALSE" goto :ngrok_no
if /i "%NGROK_ANSWER%"=="0" goto :ngrok_no
if /i "%NGROK_ANSWER%"=="否" goto :ngrok_no
echo %CY%無效的選項。請輸入 Y（啟用）或 N（停用）。%C0%
goto :ask_ngrok
:ngrok_yes
set "ENABLE_NGROK=true"
echo %CG%已啟用 ngrok 整合。%C0%
goto :ngrok_done
:ngrok_no
set "ENABLE_NGROK=false"
echo %CY%已停用 ngrok。本機將無法使用對外 webhook。%C0%
:ngrok_done
echo.

echo %CB%%CU%【步驟 3】填寫場景 %SCENARIO% 所需設定%C0%
echo.
if /i "%SCENARIO%"=="A" echo %CW%場景 A 僅需本機 Postgres 密碼。請勿填寫 Cloud Run 或 Supabase 的帳密。%C0%
if /i "%SCENARIO%"=="B" (
  echo %CW%場景 B 需要本機 Postgres 密碼，以及 Google Cloud Run 的專案、區域與服務名稱。%C0%
  echo %CW%後續請再執行 pull-secrets，以寫入加密金鑰與雲端資料庫連線。%C0%
)
if /i "%SCENARIO%"=="C" (
  echo %CW%場景 C 使用遠端 Supabase，無需本機 Postgres 密碼。%C0%
  echo %CW%請提供 Google Cloud Run 的專案、區域與服務名稱，後續再執行 pull-secrets。%C0%
)
if /i "%ENABLE_NGROK%"=="true" echo %CW%您已選擇啟用 ngrok，稍後將一併詢問 Auth Token 與網域。%C0%
echo.

set "HAS_POSTGRES="
set "HAS_GCP="
set "POSTGRES_PASSWORD="
set "GCP_PROJECT="
set "GCP_REGION="
set "GCP_RUN_SERVICE="
set "NGROK_AUTHTOKEN="
set "NGROK_DOMAIN="
set "STEP3=0"

if /i "%SCENARIO%"=="A" goto :need_postgres
if /i "%SCENARIO%"=="B" goto :need_postgres
goto :after_postgres
:need_postgres
set /a STEP3+=1
call :ReadVisible POSTGRES_PASSWORD "【步驟 3-%STEP3%】請提供本機 Postgres 資料庫密碼（POSTGRES_PASSWORD）" "此密碼僅供本機容器使用，請勿填寫雲端資料庫帳密："
set "HAS_POSTGRES=1"
:after_postgres

if /i "%SCENARIO%"=="B" goto :need_gcp
if /i "%SCENARIO%"=="C" goto :need_gcp
goto :after_gcp
:need_gcp
set /a STEP3+=1
call :ReadVisible GCP_PROJECT "【步驟 3-%STEP3%】請提供 Google Cloud 專案 ID（GCP_PROJECT）："
set /a STEP3+=1
call :ReadVisible GCP_REGION "【步驟 3-%STEP3%】請提供 Google Cloud Run 服務所在區域（GCP_REGION），例如 asia-east1："
set /a STEP3+=1
call :ReadVisible GCP_RUN_SERVICE "【步驟 3-%STEP3%】請提供 Google Cloud Run 服務名稱（GCP_RUN_SERVICE）："
set "HAS_GCP=1"
:after_gcp

if /i not "%ENABLE_NGROK%"=="true" goto :after_ngrok_secrets
set /a STEP3+=1
call :ReadVisible NGROK_AUTHTOKEN "【步驟 3-%STEP3%】請提供 Ngrok Auth Token（NGROK_AUTHTOKEN）" "可於 ngrok 官方網站儀表板取得："
set /a STEP3+=1
:ask_domain
call :ReadVisible NGROK_DOMAIN "【步驟 3-%STEP3%】請提供 Ngrok 固定網域（NGROK_DOMAIN）" "僅填主機名，例如 example.ngrok-free.dev，請勿加入通訊協定 (https://)："
call :ValidateNgrokDomain
if errorlevel 1 goto :ask_domain
:after_ngrok_secrets

set "N8N_SCENARIO=%SCENARIO%"
call :UpsertEnv N8N_SCENARIO
if errorlevel 1 exit /b 1
call :UpsertEnv ENABLE_NGROK
if errorlevel 1 exit /b 1
if defined HAS_POSTGRES (
  call :UpsertEnv POSTGRES_PASSWORD
  if errorlevel 1 exit /b 1
)
if defined HAS_GCP (
  call :UpsertEnv GCP_PROJECT
  if errorlevel 1 exit /b 1
  call :UpsertEnv GCP_REGION
  if errorlevel 1 exit /b 1
  call :UpsertEnv GCP_RUN_SERVICE
  if errorlevel 1 exit /b 1
)
call :UpsertEnv NGROK_AUTHTOKEN
if errorlevel 1 exit /b 1
call :UpsertEnv NGROK_DOMAIN
if errorlevel 1 exit /b 1

echo.
echo %CG%────────────────────────────────────────────────────────────%C0%
echo %CG%  .env 已建立完成。%C0%
echo %CG%────────────────────────────────────────────────────────────%C0%
echo.
echo %CW%寫入摘要（機密值不會顯示）：%C0%
echo %CD%  N8N_SCENARIO=%SCENARIO%%C0%
echo %CD%  ENABLE_NGROK=%ENABLE_NGROK%%C0%
if defined HAS_POSTGRES echo %CD%  POSTGRES_PASSWORD=（已設定）%C0%
if defined HAS_GCP (
  echo %CD%  GCP_PROJECT=%GCP_PROJECT%%C0%
  echo %CD%  GCP_REGION=%GCP_REGION%%C0%
  echo %CD%  GCP_RUN_SERVICE=%GCP_RUN_SERVICE%%C0%
)
if /i "%ENABLE_NGROK%"=="true" (
  echo %CD%  NGROK_AUTHTOKEN=（已設定）%C0%
  echo %CD%  NGROK_DOMAIN=%NGROK_DOMAIN%%C0%
) else (
  echo %CD%  NGROK_AUTHTOKEN / NGROK_DOMAIN=（已留空）%C0%
)
if defined BACKUP_FILE if exist "%BACKUP_FILE%" echo %CD%  先前設定備份：%BACKUP_FILE%%C0%

echo.
echo %CG%設定精靈結束。%C0%
exit /b 0

:help
echo 引導建立本專案根目錄的 .env 設定檔。
echo.
echo 流程：
echo   1. 若已有 .env，先改名為 .env.backup.YYYYMMDD-HHMMSS（不會覆蓋舊備份）
echo   2. 由 .env.example 複製出新的 .env
echo   3. 詢問部署場景與是否啟用 ngrok，並寫入對應變數
echo   4. 依場景以互動方式填入必要機密資訊
echo.
echo 用法：
echo   .\scripts\create-envfile.cmd
exit /b 0

:Prompt
echo %CB%%CM%%~1%C0%
if not "%~2"=="" <nul set /p "=%CB%%CM%%~2%C0% "
goto :eof

:ReadVisible
set "%~1="
:ReadVisibleLoop
call :Prompt "%~2" "%~3"
set /p "%~1="
if not defined %~1 (
  echo %CY%此欄位為必填，請重新輸入。%C0%
  goto :ReadVisibleLoop
)
echo.
goto :eof

:ValidateNgrokDomain
if not defined NGROK_DOMAIN (
  echo %CY%此欄位為必填，請重新輸入。%C0%
  exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=([string]$env:NGROK_DOMAIN).Trim(); if ($d -match '(?i)https?://') { exit 2 }; if ($d -notmatch '^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$') { exit 3 }; exit 0"
if errorlevel 3 (
  echo %CY%網域格式不正確。請填寫至少包含主域名與頂級網域的主機名，例如 example.ngrok-free.dev。%C0%
  exit /b 1
)
if errorlevel 2 (
  echo %CY%請勿加入通訊協定 (https://)，僅填寫主機名稱。%C0%
  exit /b 1
)
if errorlevel 1 (
  echo %CR%網域驗證失敗。%C0% >&2
  exit /b 1
)
exit /b 0

:UpsertEnv
set "UPSERT_KEY=%~1"
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$key=$env:UPSERT_KEY;" ^
  "$sidecar=Join-Path $env:TEMP ('n8n-create-env-' + $key + '.txt');" ^
  "if (Test-Path -LiteralPath $sidecar) { $val=[System.IO.File]::ReadAllText($sidecar); Remove-Item -LiteralPath $sidecar -Force } else { $val=[Environment]::GetEnvironmentVariable($key); if ($null -eq $val) { $val='' } };" ^
  "$val=(($val -replace '[\r\n]+','').Trim());" ^
  "$q=[char]39; $quoted=$q + $val.Replace([string]$q, $q + '\' + $q + $q) + $q;" ^
  "$line=$key + '=' + $quoted;" ^
  "$path=$env:UPSERT_FILE;" ^
  "$lines=@(); if (Test-Path -LiteralPath $path) { $lines=@(Get-Content -LiteralPath $path) };" ^
  "$found=$false; $out=New-Object System.Collections.Generic.List[string];" ^
  "foreach ($existing in $lines) { if (-not $found -and $existing.StartsWith($key+'=') -and -not $existing.StartsWith('#')) { $out.Add($line); $found=$true } else { $out.Add($existing) } };" ^
  "if (-not $found) { $out.Add($line) };" ^
  "$utf8=New-Object System.Text.UTF8Encoding $false;" ^
  "[System.IO.File]::WriteAllText($path, (($out -join [char]10) + [char]10), $utf8)"
if errorlevel 1 (
  echo %CR%寫入 .env 失敗：%UPSERT_KEY%%C0% >&2
  exit /b 1
)
goto :eof
