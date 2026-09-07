@echo off
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\shutdown-n8n.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
echo 按下任意鍵關閉視窗
pause >nul
exit /b %EXITCODE%
