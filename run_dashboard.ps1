$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$hostName = if ($env:DASHBOARD_HOST) { $env:DASHBOARD_HOST } else { "127.0.0.1" }
$port = if ($env:DASHBOARD_PORT) { $env:DASHBOARD_PORT } else { "8000" }
$venvPython = Join-Path $projectRoot "mq5_v_env\Scripts\python.exe"
$pythonExe = if (Test-Path $venvPython) { $venvPython } else { "python" }

if ($pythonExe -eq "python") {
  $packagesPath = Join-Path $projectRoot ".packages"
  if (Test-Path $packagesPath) {
    $env:PYTHONPATH = $packagesPath
  }
}

$env:PYTHONDONTWRITEBYTECODE = "1"

Set-Location $projectRoot
& $pythonExe manage.py runserver "$hostName`:$port" --noreload
