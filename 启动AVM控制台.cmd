@echo off
chcp 65001 >nul
title AVM Console - DeepSeek V4.1 Flash
cd /d "%~dp0"

set "PY=C:\Users\Lenovo\AppData\Local\Programs\Python\Python312\python.exe"
if not exist "%PY%" goto no_python
if not exist ".env" goto no_env
if not exist "web\dist\index.html" goto no_dist

set PYTHONIOENCODING=utf-8

rem Delete last run's token first. If this run fails to write a new one, the file
rem simply won't exist - so you go read the terminal instead of retrying with a
rem stale token that can never work.
if exist "images\local\out\console.token" del /q "images\local\out\console.token"

echo ============================================================
echo   AVM Console starting
echo.
echo   URL    : http://127.0.0.1:8700
echo            Loopback only. Unaffected by LAN IP changes.
echo   Token  : the "panel credential" line printed below,
echo            also written to images\local\out\console.token
echo            A NEW token is generated on every start.
echo.
echo   To stop: click Shutdown in the web UI (writes a snapshot).
echo   Closing this window = force kill, session is lost.
echo ============================================================
echo.

rem Give the server a few seconds, then open the browser at the right address.
rem ping is used instead of timeout: timeout fails in a start-ed window with no
rem console (input redirection unsupported) and returns immediately.
start "" /min cmd /c "ping -n 6 127.0.0.1 >nul & start http://127.0.0.1:8700"

"%PY%" -m avm.console images\local\deepseek.json --port 8700

echo.
echo Service exited.
pause
exit /b 0

:no_python
echo [ERROR] Python not found: %PY%
echo         Edit the PY variable at the top of this file.
pause
exit /b 1

:no_env
echo [ERROR] .env missing. It must contain OPENAI_API_KEY and OPENAI_BASE_URL.
pause
exit /b 1

:no_dist
echo [ERROR] Frontend not built. Run:
echo         cd web ^&^& npm install ^&^& npm run build
pause
exit /b 1
