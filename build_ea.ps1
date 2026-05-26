$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $projectRoot "scripts\build_ea.ps1"

& $scriptPath @args
