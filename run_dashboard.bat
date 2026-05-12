@echo off
cd /d C:\Programming\mt5_bot
set PYTHONPATH=C:\Programming\mt5_bot\.packages
set PYTHONDONTWRITEBYTECODE=1
python manage.py runserver 127.0.0.1:8000 --noreload
