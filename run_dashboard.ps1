$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$env:PYTHONPATH = Join-Path $projectRoot ".packages"
$env:PYTHONDONTWRITEBYTECODE = "1"

Set-Location $projectRoot
python manage.py runserver 127.0.0.1:8000 --noreload
