@echo off
setlocal

if exist "%~dp0Criar_Atalho_Pombo.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Criar_Atalho_Pombo.ps1" >nul 2>nul
)

start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0launcher.ps1"
exit /b
