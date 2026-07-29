@echo off
setlocal EnableDelayedExpansion
title MT5 Recovery Shield

REM ---------------------------------------------------------------
REM One-file launcher for the Recovery Shield dashboard.
REM
REM   start.bat          Start the dashboard and open it in a browser
REM   start.bat build    Compile the EA into MT5 first, then start
REM   start.bat lan      Bind 0.0.0.0 so other machines can connect
REM ---------------------------------------------------------------

set "PROJECT_ROOT=%~dp0"
cd /d "%PROJECT_ROOT%"

set "MODE=%~1"

if "%DASHBOARD_HOST%"=="" set "DASHBOARD_HOST=127.0.0.1"
if "%DASHBOARD_PORT%"=="" set "DASHBOARD_PORT=8000"
if /i "%MODE%"=="lan" set "DASHBOARD_HOST=0.0.0.0"

set "PYTHONDONTWRITEBYTECODE=1"
set "PYTHONUNBUFFERED=1"

set "VENV_DIR=%PROJECT_ROOT%mq5_v_env"
set "PYTHON_EXE=%VENV_DIR%\Scripts\python.exe"

REM ---- 1. Python environment -------------------------------------
if not exist "!PYTHON_EXE!" (
  echo [start] No virtual environment found. Creating mq5_v_env ...
  py -3 -m venv "%VENV_DIR%" 2>nul
  if not exist "!PYTHON_EXE!" python -m venv "%VENV_DIR%" 2>nul
)

if not exist "!PYTHON_EXE!" (
  echo [start] Could not create a virtual environment, using system python.
  set "PYTHON_EXE=python"
  if exist "%PROJECT_ROOT%.packages" set "PYTHONPATH=%PROJECT_ROOT%.packages"
) else (
  "!PYTHON_EXE!" -c "import django" 1>nul 2>nul
  if errorlevel 1 (
    echo [start] Installing requirements, this only happens once ...
    "!PYTHON_EXE!" -m pip install --disable-pip-version-check --quiet --upgrade pip
    "!PYTHON_EXE!" -m pip install --disable-pip-version-check --quiet -r "%PROJECT_ROOT%requirements.txt"
    if errorlevel 1 (
      echo [start] Requirement install failed. Check your internet connection.
      pause
      exit /b 1
    )
  )
)

REM ---- 2. Optional EA build --------------------------------------
if /i "%MODE%"=="build" (
  echo [start] Building the EA into MetaTrader ...
  powershell -NoProfile -ExecutionPolicy Bypass -File "%PROJECT_ROOT%scripts\build_ea.ps1"
  if errorlevel 1 (
    echo [start] EA build failed. Starting the dashboard anyway.
  )
)

REM ---- 3. Database ------------------------------------------------
"!PYTHON_EXE!" manage.py migrate --noinput 1>nul 2>nul
if errorlevel 1 (
  echo [start] Migrations failed. Showing the error:
  "!PYTHON_EXE!" manage.py migrate --noinput
  pause
  exit /b 1
)

REM ---- 4. Open the browser once the server answers ----------------
set "BROWSER_HOST=%DASHBOARD_HOST%"
if "%DASHBOARD_HOST%"=="0.0.0.0" set "BROWSER_HOST=127.0.0.1"
set "DASHBOARD_URL=http://!BROWSER_HOST!:%DASHBOARD_PORT%/"

start "" /min powershell -NoProfile -Command ^
  "for ($i=0; $i -lt 40; $i++) { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 '!DASHBOARD_URL!' ^| Out-Null; break } catch { Start-Sleep -Milliseconds 250 } }; Start-Process '!DASHBOARD_URL!'"

echo.
echo   Recovery Shield dashboard
echo   ------------------------------------------------
echo   URL       !DASHBOARD_URL!
echo   Shared    %%APPDATA%%\MetaQuotes\Terminal\Common\Files
echo   Stop      Ctrl+C
echo.

REM ---- 5. Run the server -----------------------------------------
"!PYTHON_EXE!" manage.py runserver %DASHBOARD_HOST%:%DASHBOARD_PORT% --noreload

endlocal
