$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostName = if ($env:DASHBOARD_HOST) { $env:DASHBOARD_HOST } else { "127.0.0.1" }
$port = if ($env:DASHBOARD_PORT) { $env:DASHBOARD_PORT } else { "8000" }
$env:PYTHONPATH = Join-Path $projectRoot ".packages"
$env:PYTHONDONTWRITEBYTECODE = "1"

Set-Location $projectRoot
python manage.py runserver "$hostName`:$port" --noreload
