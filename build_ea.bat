@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_ea.ps1" %*
