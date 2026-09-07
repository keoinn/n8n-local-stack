@echo off
setlocal
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\shutdown-n8n.ps1" %*
exit /b %ERRORLEVEL%
