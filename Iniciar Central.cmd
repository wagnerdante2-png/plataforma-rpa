@echo off
setlocal
cd /d "%~dp0"
title Plataforma RPA - Central Local

if not exist "%~dp0central.ps1" (
  echo.
  echo ============================================================
  echo  CENTRAL RPA - ARQUIVOS NAO EXTRAIDOS
  echo ============================================================
  echo.
  echo O Windows esta executando o launcher de dentro do arquivo ZIP.
  echo Nesse modo, os demais arquivos da plataforma nao ficam disponiveis.
  echo.
  echo 1. Feche esta janela.
  echo 2. No arquivo plataforma-rpa-main.zip, clique em "Extrair tudo".
  echo 3. Abra a pasta extraida plataforma-rpa-main.
  echo 4. Execute novamente "Iniciar Central.cmd".
  echo.
  pause
  exit /b 2
)

if not exist "%~dp0web\index.html" (
  echo.
  echo [ERRO] A pasta web da Central RPA nao foi encontrada.
  echo Extraia novamente o pacote completo antes de executar.
  echo.
  pause
  exit /b 3
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0central.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo A Central RPA foi encerrada com erro.
  pause
)
exit /b %EXITCODE%
