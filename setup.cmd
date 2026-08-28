@echo off
rem ============================================================
rem  DeepSeek-Harness setup entry (double-click to run)
rem  Usage examples:
rem    setup.cmd                      create desktop shortcut
rem    setup.cmd -IconPath C:\logo.png
rem    setup.cmd -StopShortcut
rem    setup.cmd -Remove
rem    setup.cmd doctor               same as DeepSeek-Harness.ps1 doctor
rem    setup.cmd doctor -Json         also write machine-readable report
rem  NOTE: keep this file ASCII-only (cmd.exe codepage is not UTF-8)
rem ============================================================
title DeepSeek-Harness Setup

if /i "%~1"=="doctor" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DeepSeek-Harness.ps1" doctor %2 %3 %4
  echo.
  echo Press any key to close...
  pause >nul
  exit /b 0
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1" %*
echo.
echo Press any key to close...
pause >nul
