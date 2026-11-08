@echo off
setlocal
title Repair IDEA Services Panel

REM ============================================================
REM  Repair IDEA Services (Run Dashboard) panel for:
REM    D:\Code\Marketing
REM  Usage: double-click this file and follow the prompts.
REM  Flow: process check -^> DryRun preview -^> apply -^> done
REM ============================================================

echo(
echo ============================================================
echo   Repair IDEA Services panel ^(Run Dashboard^)
echo   Workspace: D:\Code\Marketing
echo ============================================================
echo(

REM --- IDEA must be closed, otherwise IDEA overwrites the fix ---
tasklist /FI "IMAGENAME eq idea64.exe" 2>nul | find /I "idea64.exe" >nul
if not errorlevel 1 (
    echo [ABORT] IntelliJ IDEA is still running.
    echo         Close ALL IDEA windows first, then run this script again.
    echo(
    pause
    exit /b 1
)
echo [OK] IDEA is not running.
echo(

REM --- Always preview first ---
choice /C YN /N /M "Run DRYRUN preview first (recommended)? [Y/N] "
if errorlevel 2 goto apply

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-IdeaServices.ps1" -Workspace "D:\Code\Marketing" -DryRun
if errorlevel 1 (
    echo [WARN] DryRun failed - review the messages above, nothing was changed.
    goto end
)
echo(
choice /C YN /N /M "Apply the changes now? [Y/N] "
if errorlevel 2 goto end

:apply
echo(
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-IdeaServices.ps1" -Workspace "D:\Code\Marketing"
if errorlevel 1 echo [WARN] The repair script reported an error - review the messages above.

:end
echo(
echo Finished. You can close this window.
pause
endlocal
