@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pull-secrets.ps1" %*
