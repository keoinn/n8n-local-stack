@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\shutdown-n8n.ps1" %*
exit /b %ERRORLEVEL%
