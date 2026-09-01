@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0create-envfile.ps1" %*
exit /b %ERRORLEVEL%
