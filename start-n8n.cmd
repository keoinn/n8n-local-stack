@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"

echo.

where git >nul 2>&1
if errorlevel 1 goto NO_GIT

git rev-parse --is-inside-work-tree >nul 2>&1
if errorlevel 1 goto NO_GIT

echo 正在還原並更新專案 ...
git checkout -q .
if errorlevel 1 (
    echo 更新失敗，將以目前的程式碼繼續啟動。
    echo.
    goto RUN
)
git pull
if errorlevel 1 (
    echo 更新失敗，將以目前的程式碼繼續啟動。
    echo.
    goto RUN
)
echo 專案已更新。
echo.
goto RUN

:NO_GIT
echo 目前無法自動更新程式碼。
echo 若要更新，請先安裝 git 原始碼控制工具：
echo   https://git-scm.com/
echo.

:RUN
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-n8n.ps1" %*
set "EXITCODE=%ERRORLEVEL%"
echo.
echo 按下任意鍵關閉視窗
pause >nul
exit /b %EXITCODE%
