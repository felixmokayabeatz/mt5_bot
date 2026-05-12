$env:PYTHONPATH = "C:\Programming\mt5_bot\.packages"
$env:PYTHONDONTWRITEBYTECODE = "1"

python manage.py runserver 127.0.0.1:8000 --noreload
