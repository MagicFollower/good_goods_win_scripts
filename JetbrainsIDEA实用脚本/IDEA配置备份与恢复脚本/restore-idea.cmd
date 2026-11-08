@echo off
:: ============================================================
::  IDEA Config Restore - CMD Launcher (ASCII only for CMD)
::  All UI is handled by the PowerShell script.
:: ============================================================
chcp 65001 >nul 2>&1
title IDEA Restore Launcher

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Restore-IDEAConfig.ps1"

:: Check PS1 exists
if not exist "%PS_SCRIPT%" (
    echo [ERROR] PowerShell script not found:
    echo         %PS_SCRIPT%
    echo.
    pause
    exit /b 1
)

:: Check IDEA config exists
set "IDEA_ROAMING=%APPDATA%\JetBrains\IntelliJIdea2025.3"
if not exist "%IDEA_ROAMING%" (
    echo [ERROR] IDEA config directory not found:
    echo         %IDEA_ROAMING%
    echo.
    echo Please make sure IntelliJ IDEA 2025.3 is installed.
    echo.
    pause
    exit /b 1
)

:: Launch PowerShell interactive restore
powershell -ExecutionPolicy Bypass -NoProfile -File "%PS_SCRIPT%" -Interactive

exit /b %ERRORLEVEL%
