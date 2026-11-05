@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0login-openbao-ui.ps1" %*
