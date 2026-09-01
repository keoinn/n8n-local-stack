@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-local-n8n.ps1" %*
exit /b %ERRORLEVEL%
