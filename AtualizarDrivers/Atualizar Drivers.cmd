@echo off
setlocal EnableExtensions EnableDelayedExpansion
chcp 65001 >nul
cd /d "%~dp0"
title Atualizar Drivers

set "PS1=%~dp0Atualizar Drivers.ps1"
if not exist "%PS1%" (
  echo ERRO: Nao encontrei "%PS1%"
  exit /b 2
)

rem ============================================================
rem Flags especiais do CMD:
rem   /SomenteDrivers       = executa apenas a atualizacao de drivers
rem   /SemVisualCPP         = nao instala o Visual C++ ao finalizar
rem   /SemControleQualidade = nao abre o Controle de Qualidade ao finalizar
rem   /SemSlideshow         = nao aplica a pasta Wallpaper como apresentacao de slides
rem
rem Essas flags NAO sao repassadas para o .ps1 para evitar erro de parametro.
rem ============================================================
set "SKIP_VISUALCPP=0"
set "SKIP_CONTROLE=0"
set "SKIP_SLIDESHOW=0"
set "PS_ARGS=-NaoPausar"
set "PAUSAR_ERRO=1"

if not "%~1"=="" for %%A in (%*) do (
  if /I "%%~A"=="/SomenteDrivers" (
    set "SKIP_VISUALCPP=1"
    set "SKIP_CONTROLE=1"
  ) else if /I "%%~A"=="/OnlyDrivers" (
    set "SKIP_VISUALCPP=1"
    set "SKIP_CONTROLE=1"
  ) else if /I "%%~A"=="/SemVisualCPP" (
    set "SKIP_VISUALCPP=1"
  ) else if /I "%%~A"=="/SemControleQualidade" (
    set "SKIP_CONTROLE=1"
  ) else if /I "%%~A"=="/SemSlideshow" (
    set "SKIP_SLIDESHOW=1"
  ) else if /I "%%~A"=="/SemPos" (
    set "SKIP_VISUALCPP=1"
    set "SKIP_CONTROLE=1"
    set "SKIP_SLIDESHOW=1"
  ) else if /I "%%~A"=="-NaoPausar" (
    set "PAUSAR_ERRO=0"
  ) else if /I "%%~A"=="/NaoPausar" (
    set "PAUSAR_ERRO=0"
  ) else (
    set "PS_ARGS=!PS_ARGS! %%~A"
  )
)

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo Solicitando permissao de administrador...
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
  exit /b
)

echo ============================================================
echo   ATUALIZAR DRIVERS
echo ============================================================
echo.
call :CONFIGURAR_PLANO_ENERGIA
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PS_ARGS%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo A atualizacao nao foi concluida. Codigo: %RC%.
  echo Se o codigo for 3010, reinicie o Windows para concluir e verificar.
  echo Consulte DriversRepo\_Logs ou AtualizarDrivers_erro.log na pasta do atualizador.
  if "%PAUSAR_ERRO%"=="1" pause
)

if "%SKIP_SLIDESHOW%"=="0" call :APLICAR_SLIDESHOW
if "%SKIP_VISUALCPP%"=="0" call :EXECUTAR_VISUAL_CPP
if "%SKIP_CONTROLE%"=="0" call :ABRIR_CONTROLE_QUALIDADE
exit /b %RC%

:CONFIGURAR_PLANO_ENERGIA
rem Mantem o PC acordado durante a atualizacao de drivers e o Controle de Qualidade.
rem Valor 0 = Nunca para desligar video, suspender ou hibernar.
echo Configurando plano de energia para NUNCA desligar video ou suspender...
powercfg /change monitor-timeout-ac 0 >nul 2>&1
powercfg /change monitor-timeout-dc 0 >nul 2>&1
powercfg /change standby-timeout-ac 0 >nul 2>&1
powercfg /change standby-timeout-dc 0 >nul 2>&1
powercfg /change hibernate-timeout-ac 0 >nul 2>&1
powercfg /change hibernate-timeout-dc 0 >nul 2>&1
powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0 >nul 2>&1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0 >nul 2>&1
powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 >nul 2>&1
powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 >nul 2>&1
powercfg /setactive SCHEME_CURRENT >nul 2>&1
exit /b 0

:APLICAR_SLIDESHOW
rem Aplica a pasta Wallpaper (ja copiada para o disco local) como apresentacao de slides
rem nativa do Windows, trocando a imagem a cada 1 minuto.
set "SLIDESHOW_WALL=C:\Windows\Setup\Scripts\Wallpaper"

rem 1) Preferencia: o executavel independente (nao depende de ExecutionPolicy).
set "SLIDESHOW_EXE="
for %%E in (
  "%~dp0..\Wallpaper\AplicarSlideshow.exe"
  "%~dp0AplicarSlideshow.exe"
  "C:\Windows\Setup\Scripts\AplicarSlideshow.exe"
) do (
  if not defined SLIDESHOW_EXE if exist "%%~E" set "SLIDESHOW_EXE=%%~E"
)
if defined SLIDESHOW_EXE (
  echo.
  echo Aplicando apresentacao de slides - papel de parede, troca a cada 1 minuto...
  "%SLIDESHOW_EXE%" -Pasta "%SLIDESHOW_WALL%" -Destino "%SLIDESHOW_WALL%" -Intervalo 60000 -SemPausa
  if not errorlevel 1 exit /b 0
  echo AVISO: executavel do slideshow falhou. Tentando PowerShell.
)

rem 2) Fallback: o script PowerShell.
set "SLIDESHOW_PS1="
for %%S in (
  "%~dp0..\Wallpaper\AplicarSlideshow.ps1"
  "%~dp0AplicarSlideshow.ps1"
  "C:\Windows\Setup\Scripts\AplicarSlideshow.ps1"
) do (
  if not defined SLIDESHOW_PS1 if exist "%%~S" set "SLIDESHOW_PS1=%%~S"
)
if not defined SLIDESHOW_PS1 (
  echo AVISO: AplicarSlideshow.exe/ps1 nao encontrado. Slideshow nao aplicado.
  exit /b 0
)
echo.
echo Aplicando apresentacao de slides - papel de parede, troca a cada 1 minuto...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SLIDESHOW_PS1%" -Pasta "%SLIDESHOW_WALL%" -Destino "%SLIDESHOW_WALL%" -IntervaloMs 60000
exit /b 0

:EXECUTAR_VISUAL_CPP
set "VC_EXE="
for %%V in (
  "%~dp0..\Utilitarios\[AquaX]Visual C++.exe"
  "%~dp0[AquaX]Visual C++.exe"
  "%~dp0Visual C++.exe"
  "%~dp0AquaX Visual C++.exe"
  "%~dp0..\[AquaX]Visual C++.exe"
  "C:\Windows\Setup\Scripts\[AquaX]Visual C++.exe"
) do (
  if not defined VC_EXE if exist "%%~V" set "VC_EXE=%%~V"
)
if not defined VC_EXE (
  echo AVISO: instalador Visual C++ nao encontrado.
  exit /b 0
)
echo.
echo Instalando Visual C++...
for %%P in ("%VC_EXE%") do start "" /wait /D "%%~dpP" "%%~fP" /quiet /norestart
set "VC_RC=%ERRORLEVEL%"
echo Visual C++ finalizou com codigo %VC_RC%.
exit /b 0

:ABRIR_CONTROLE_QUALIDADE
set "CQ_EXE="
for %%Q in (
  "%~dp0..\Controle de Qualidade\Controle de Qualidade.exe"
  "%~dp0Controle de Qualidade\Controle de Qualidade.exe"
  "%~dp0..\Controle de Qualidade\Controle de Qualidade.exe"
  "C:\Windows\Setup\Scripts\Controle de Qualidade\Controle de Qualidade.exe"
) do (
  if not defined CQ_EXE if exist "%%~Q" set "CQ_EXE=%%~Q"
)
if not defined CQ_EXE (
  echo AVISO: Controle de Qualidade nao encontrado.
  exit /b 0
)
echo.
echo Abrindo Controle de Qualidade...
call :FECHAR_TELA_INICIAL_WINDOWS
for %%P in ("%CQ_EXE%") do start "" /D "%%~dpP" "%%~fP"
call :FECHAR_TELA_INICIAL_WINDOWS
exit /b 0

:FECHAR_TELA_INICIAL_WINDOWS
rem Fecha o menu Iniciar/Pesquisa do Windows 11 quando ele abre sozinho no primeiro logon e fica sobre o Controle de Qualidade.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "1..6 | ForEach-Object { try { Get-Process -Name StartMenuExperienceHost,SearchHost -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}; Start-Sleep -Milliseconds 500 }" >nul 2>&1
exit /b 0
