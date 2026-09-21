@echo off
setlocal
cd /d "%~dp0"
title Plataforma RPA - Central Local
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0central.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo A Central RPA foi encerrada com erro.
  pause
)
exit /b %EXITCODE%
