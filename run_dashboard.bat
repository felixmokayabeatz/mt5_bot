@echo off
set PROJECT_ROOT=%~dp0
cd /d "%PROJECT_ROOT%"
set PYTHONPATH=%PROJECT_ROOT%.packages
set PYTHONDONTWRITEBYTECODE=1
python manage.py runserver 127.0.0.1:8000 --noreload
