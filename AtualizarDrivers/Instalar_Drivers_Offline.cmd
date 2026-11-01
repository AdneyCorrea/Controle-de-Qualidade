@echo off
setlocal EnableExtensions

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'cmd.exe' -ArgumentList '/k ""%~f0""' -Verb RunAs"
    exit /b
)


title Instalacao automatica de drivers
color 0A

set "LOG=C:\Windows\Temp\InstalarDriversPrimeiroLogon.log"
if not exist "C:\Windows\Temp" mkdir "C:\Windows\Temp" >nul 2>&1

echo =========================================================
echo      INSTALACAO AUTOMATICA DE DRIVERS - INICIO
echo =========================================================
echo.

echo =========================================================>>"%LOG%"
echo [%date% %time%] CMD iniciado>>"%LOG%"

echo [1/5] Diretorio atual: %~dp0
echo [1/5] Diretorio atual: %~dp0>>"%LOG%"

cd /d "%~dp0"

if not exist "%~dp0Instalar_Drivers_Offline.ps1" (
    echo [ERRO] Arquivo Instalar_Drivers_Offline.ps1 nao encontrado.
    echo [ERRO] Arquivo Instalar_Drivers_Offline.ps1 nao encontrado.>>"%LOG%"
    echo.
    echo A janela ficara aberta para conferencia.
    goto :END
)

echo [2/5] PowerShell encontrado. Iniciando script...
echo [2/5] Iniciando PowerShell...>>"%LOG%"
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar_Drivers_Offline.ps1" >>"%LOG%" 2>>&1

set "RC=%ERRORLEVEL%"

echo.
echo [3/5] Script PowerShell finalizado com codigo: %RC%
echo [3/5] PowerShell finalizado com codigo: %RC%>>"%LOG%"

if "%RC%"=="0" (
    echo [4/5] Instalacao de drivers concluida com sucesso.
    echo [4/5] Instalacao de drivers concluida com sucesso.>>"%LOG%"
) else (
    echo [4/5] Instalacao de drivers finalizou com erro.
    echo [4/5] Instalacao de drivers finalizou com erro.>>"%LOG%"
)

echo.
echo [5/5] Log salvo em:
echo %LOG%
echo [5/5] Log salvo em: %LOG%>>"%LOG%"

:END
echo.
echo =========================================================
echo      FIM DO PROCESSO
echo =========================================================
echo.
echo Esta janela permanecera aberta para conferencia.
echo Feche manualmente quando terminar.