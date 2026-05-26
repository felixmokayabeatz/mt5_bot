@echo off
set PROJECT_ROOT=%~dp0
if "%DASHBOARD_HOST%"=="" set DASHBOARD_HOST=127.0.0.1
if "%DASHBOARD_PORT%"=="" set DASHBOARD_PORT=8000
cd /d "%PROJECT_ROOT%"
set PYTHON_EXE=%PROJECT_ROOT%mq5_v_env\Scripts\python.exe
if not exist "%PYTHON_EXE%" (
  set PYTHON_EXE=python
  if exist "%PROJECT_ROOT%.packages" set PYTHONPATH=%PROJECT_ROOT%.packages
)
set PYTHONDONTWRITEBYTECODE=1
"%PYTHON_EXE%" manage.py runserver %DASHBOARD_HOST%:%DASHBOARD_PORT% --noreload
