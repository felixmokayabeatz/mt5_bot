[CmdletBinding()]
param(
  [string]$Source = "",
  [string]$ExpertsDir = "",
  [string]$TerminalDataDir = "",
  [string]$MetaEditor = "",
  [string]$TargetSubdir = "RecoveryShield",
  [switch]$NoCompile,
  [switch]$Watch,
  [int]$DebounceMs = 700,
  [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $PSScriptRoot

function Show-Usage {
  Write-Host "Build and sync the MT5 EA without touching the dashboard."
  Write-Host ""
  Write-Host "Usage:"
  Write-Host "  .\build_ea.ps1"
  Write-Host "  .\build_ea.ps1 -Watch"
  Write-Host "  .\build_ea.ps1 -NoCompile"
  Write-Host "  .\build_ea.ps1 -ExpertsDir `"C:\Users\you\AppData\Roaming\MetaQuotes\Terminal\<id>\MQL5\Experts`""
  Write-Host ""
  Write-Host "Optional environment variables:"
  Write-Host "  MT5_EXPERTS_DIR   Full path to MQL5\Experts"
  Write-Host "  MT5_DATA_DIR      Full path to the MT5 terminal data folder"
  Write-Host "  METAEDITOR_EXE    Full path to metaeditor64.exe"
}

function Resolve-FullPath([string]$PathValue) {
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return [System.IO.Path]::GetFullPath($PathValue)
  }

  return [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $PathValue))
}

function Resolve-ExistingFile([string]$PathValue, [string]$Label) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    return $null
  }

  $fullPath = Resolve-FullPath $PathValue
  if (!(Test-Path -LiteralPath $fullPath -PathType Leaf)) {
    throw "$Label was not found: $fullPath"
  }

  return $fullPath
}

function Find-MetaEditor([string]$PreferredPath) {
  $envPath = $env:METAEDITOR_EXE
  foreach ($candidate in @($PreferredPath, $envPath)) {
    if (![string]::IsNullOrWhiteSpace($candidate)) {
      return Resolve-ExistingFile $candidate "MetaEditor"
    }
  }

  foreach ($commandName in @("metaeditor64.exe", "metaeditor.exe")) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($command) {
      return $command.Source
    }
  }

  $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}) |
    Where-Object { ![string]::IsNullOrWhiteSpace($_) -and (Test-Path -LiteralPath $_) }

  foreach ($root in $roots) {
    $installDirs = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match "MetaTrader|MT5" }

    foreach ($installDir in $installDirs) {
      foreach ($fileName in @("metaeditor64.exe", "metaeditor.exe")) {
        $candidate = Join-Path $installDir.FullName $fileName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          return $candidate
        }
      }
    }
  }

  return $null
}

function Find-ExpertsDir([string]$PreferredExpertsDir, [string]$PreferredTerminalDataDir) {
  $expertsCandidates = @($PreferredExpertsDir, $env:MT5_EXPERTS_DIR) |
    Where-Object { ![string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $expertsCandidates) {
    return (Resolve-FullPath $candidate)
  }

  $terminalDataCandidates = @($PreferredTerminalDataDir, $env:MT5_DATA_DIR) |
    Where-Object { ![string]::IsNullOrWhiteSpace($_) }

  foreach ($candidate in $terminalDataCandidates) {
    $fullPath = Resolve-FullPath $candidate
    if (!(Test-Path -LiteralPath $fullPath -PathType Container)) {
      throw "MT5 terminal data folder was not found: $fullPath"
    }

    return (Join-Path $fullPath "MQL5\Experts")
  }

  if ([string]::IsNullOrWhiteSpace($env:APPDATA)) {
    return $null
  }

  $terminalRoot = Join-Path $env:APPDATA "MetaQuotes\Terminal"
  if (!(Test-Path -LiteralPath $terminalRoot -PathType Container)) {
    return $null
  }

  $autoCandidates = @(Get-ChildItem -LiteralPath $terminalRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne "Common" } |
    ForEach-Object {
      $expertsPath = Join-Path $_.FullName "MQL5\Experts"
      if (Test-Path -LiteralPath $expertsPath -PathType Container) {
        [PSCustomObject]@{
          Path = $expertsPath
          LastWriteTimeUtc = $_.LastWriteTimeUtc
        }
      }
    } |
    Sort-Object LastWriteTimeUtc -Descending)

  if ($autoCandidates.Count -gt 0) {
    return $autoCandidates[0].Path
  }

  return $null
}

function Copy-EaSource([string]$SourcePath, [string]$TargetDirectory) {
  New-Item -ItemType Directory -Path $TargetDirectory -Force | Out-Null

  $targetSource = Join-Path $TargetDirectory (Split-Path -Leaf $SourcePath)
  $shouldCopy = $true

  if (Test-Path -LiteralPath $targetSource -PathType Leaf) {
    $sourceHash = (Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash
    $targetHash = (Get-FileHash -LiteralPath $targetSource -Algorithm SHA256).Hash
    $shouldCopy = ($sourceHash -ne $targetHash)
  }

  if ($shouldCopy) {
    if (Test-Path -LiteralPath $targetSource -PathType Leaf) {
      Copy-Item -LiteralPath $targetSource -Destination "$targetSource.bak" -Force
    }

    Copy-Item -LiteralPath $SourcePath -Destination $targetSource -Force
    Write-Host "Synced EA source: $targetSource"
  } else {
    Write-Host "EA source already up to date: $targetSource"
  }

  return $targetSource
}

function Read-CompileLog([string]$LogPath) {
  if (!(Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    return ""
  }

  return (Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue)
}

function Get-CompileErrorCount([string]$LogText) {
  if ([string]::IsNullOrWhiteSpace($LogText)) {
    return $null
  }

  $ignoreCase = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $multilineIgnoreCase = $ignoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
  $resultMatch = [regex]::Match($LogText, "Result:\s+(\d+)\s+errors?", $ignoreCase)
  if ($resultMatch.Success) {
    return [int]$resultMatch.Groups[1].Value
  }

  $errorMatches = [regex]::Matches($LogText, "^\s*.*\s+:\s+error\s+", $multilineIgnoreCase)
  return $errorMatches.Count
}

function Invoke-MetaEditorCompile([string]$MetaEditorPath, [string]$TargetSource) {
  if ([string]::IsNullOrWhiteSpace($MetaEditorPath)) {
    throw "MetaEditor was not found. Set METAEDITOR_EXE or pass -MetaEditor."
  }

  $logDir = Join-Path $ProjectRoot ".tmp\metaeditor"
  New-Item -ItemType Directory -Path $logDir -Force | Out-Null

  $logPath = Join-Path $logDir (([System.IO.Path]::GetFileNameWithoutExtension($TargetSource)) + ".compile.log")
  Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue

  $arguments = @(
    "/compile:`"$TargetSource`"",
    "/log:`"$logPath`""
  )

  Write-Host "Compiling with MetaEditor: $MetaEditorPath"
  $process = Start-Process -FilePath $MetaEditorPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
  $logText = Read-CompileLog $logPath
  $compiledPath = [System.IO.Path]::ChangeExtension($TargetSource, ".ex5")
  $errorCount = Get-CompileErrorCount $logText

  if ($null -ne $errorCount -and $errorCount -gt 0) {
    if ($logText) {
      Write-Host $logText
    }

    throw "MetaEditor reported $errorCount compile error(s). Log: $logPath"
  }

  if (!(Test-Path -LiteralPath $compiledPath -PathType Leaf)) {
    if ($logText) {
      Write-Host $logText
    }

    throw "Compile finished but no EX5 was found: $compiledPath"
  }

  if ($process.ExitCode -ne 0) {
    Write-Host "MetaEditor returned exit code $($process.ExitCode), but the log has no errors and the EX5 exists."
  }

  Write-Host "Compiled EA: $compiledPath"
  Write-Host "Compile log: $logPath"
}

function Invoke-EaBuild {
  $sourcePath = $Source
  if ([string]::IsNullOrWhiteSpace($sourcePath)) {
    $sourcePath = Join-Path $ProjectRoot "volatilty.mq5"
  }

  $sourcePath = Resolve-ExistingFile $sourcePath "EA source"
  $expertsRoot = Find-ExpertsDir $ExpertsDir $TerminalDataDir
  if ([string]::IsNullOrWhiteSpace($expertsRoot)) {
    throw "Could not find MT5 MQL5\Experts. Set MT5_EXPERTS_DIR or pass -ExpertsDir."
  }

  $targetDir = Join-Path $expertsRoot $TargetSubdir
  $targetSource = Copy-EaSource $sourcePath $targetDir

  if ($NoCompile) {
    Write-Host "Skipped compile because -NoCompile was used."
    return
  }

  $metaEditorPath = Find-MetaEditor $MetaEditor
  Invoke-MetaEditorCompile $metaEditorPath $targetSource
}

if ($Help) {
  Show-Usage
  exit 0
}

do {
  try {
    Invoke-EaBuild
  } catch {
    Write-Error $_
    if (!$Watch) {
      exit 1
    }
  }

  if (!$Watch) {
    break
  }

  $watchSource = $Source
  if ([string]::IsNullOrWhiteSpace($watchSource)) {
    $watchSource = Join-Path $ProjectRoot "volatilty.mq5"
  }

  $watchSource = Resolve-ExistingFile $watchSource "EA source"
  $lastWrite = (Get-Item -LiteralPath $watchSource).LastWriteTimeUtc
  Write-Host "Watching $watchSource for changes. Press Ctrl+C to stop."

  do {
    Start-Sleep -Milliseconds 500
    $currentWrite = (Get-Item -LiteralPath $watchSource).LastWriteTimeUtc
  } while ($currentWrite -eq $lastWrite)

  Start-Sleep -Milliseconds $DebounceMs
} while ($true)
