@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\n8n-tools.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
echo 按下任意鍵關閉視窗
pause >nul
exit /b %EXITCODE%
