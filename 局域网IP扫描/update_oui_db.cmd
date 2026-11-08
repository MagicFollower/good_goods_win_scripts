@echo off
setlocal EnableDelayedExpansion
title OUI Vendor Database Updater

REM ============================================================
REM  OUI Vendor Database Updater  (update_oui_db.cmd)
REM ------------------------------------------------------------
REM  Downloads the latest IEEE MAC vendor registry (Wireshark
REM  "manuf" mirror, updated weekly) and rebuilds oui_db.txt
REM  used by lan_scanner.cmd.
REM
REM  - If oui_db.txt already exists it is renamed to
REM      oui_db.txt.<YYYYMMDD_HHMMSS>.bak
REM    before the new database is installed.
REM  - The lookup cache oui_cache.txt is cleared so the scanner
REM    immediately shows the freshest vendor names.
REM  - If the download or conversion fails, the existing
REM    database is left untouched.
REM
REM  Requirements : Windows 10/11 (curl.exe built in since
REM                 1803; a PowerShell downloader is used as
REM                 fallback) plus internet access.
REM  To change the download source, edit the URL variable below.
REM ============================================================

set "DB=%~dp0oui_db.txt"
set "CACHE=%~dp0oui_cache.txt"
set "URL=https://www.wireshark.org/download/automated/data/manuf"
set "SRC=%TEMP%\dsh_manuf_%RANDOM%.txt"
set "NEWDB=%TEMP%\dsh_oui_new_%RANDOM%.txt"

echo.
echo  ============================================
echo          OUI Vendor Database Updater
echo  ============================================
echo   Database : !DB!
echo   Source   : !URL!
echo.

REM ---- Step 1: download the raw IEEE registry ----------------
echo [1/4] Downloading latest IEEE vendor database (about 3 MB)...
where curl.exe >nul 2>&1
if errorlevel 1 (
    echo        curl.exe not found - using PowerShell downloader...
    powershell -NoProfile -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -Uri '!URL!' -OutFile '!SRC!' -UseBasicParsing -TimeoutSec 180" >nul 2>&1
) else (
    curl -m 180 -sS -L --retry 2 --retry-delay 2 -o "!SRC!" "!URL!" 2>nul
)
set "SIZE=0"
if exist "!SRC!" for %%s in ("!SRC!") do set /a SIZE=%%~zs
if !SIZE! LSS 100000 (
    echo.
    echo  [ERROR] Download failed or file too small - !SIZE! bytes received.
    echo          Check your internet connection. The existing database
    echo          was NOT changed.
    if exist "!SRC!" del /q "!SRC!"
    echo.
    pause
    exit /b 1
)
echo        Downloaded !SIZE! bytes OK.

REM ---- Step 2: convert (engine is embedded at the bottom) ----
echo [2/4] Converting to scanner format (40k+ entries)...
set "OUI_SRC=!SRC!"
set "OUI_DST=!NEWDB!"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText('%~f0'); $ib=$t.IndexOf(('PS'+'_BEGIN_MARKER')); $ie=$t.IndexOf(('PS'+'_END_MARKER')); $s=$t.IndexOf([char]10,$ib)+1; $e=$t.LastIndexOf([char]10,$ie); Invoke-Expression $t.Substring($s,$e-$s)"
if errorlevel 1 (
    echo  [ERROR] Conversion failed. The existing database was NOT changed.
    if exist "!SRC!" del /q "!SRC!"
    if exist "!NEWDB!" del /q "!NEWDB!"
    echo.
    pause
    exit /b 1
)

REM ---- Step 3: back up the old database, install the new -----
echo [3/4] Replacing local database...
set "TS="
for /f %%t in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd_HHmmss"') do set "TS=%%t"
if exist "!DB!" (
    set "BAK=!DB!.!TS!.bak"
    move /y "!DB!" "!BAK!" >nul
    echo        Old database backed up as: !BAK!
) else (
    echo        No existing database found - fresh install.
)
move /y "!NEWDB!" "!DB!" >nul
if not exist "!DB!" (
    echo  [ERROR] Could not install the new database. Restore the
    echo          .bak file manually if needed.
    pause
    exit /b 1
)

REM ---- Step 4: finish up -------------------------------------
if exist "!CACHE!" (
    del /q "!CACHE!"
    echo        Vendor lookup cache cleared: oui_cache.txt
)
for %%s in ("!DB!") do set "DBSIZE=%%~zs"
echo [4/4] Database updated: !DB!  (!DBSIZE! bytes^)
echo.
echo  Done. lan_scanner.cmd will now use the updated vendor names.
echo.
pause
exit /b 0


rem PS_BEGIN_MARKER
$ErrorActionPreference = 'Stop'
try {
  $src = $env:OUI_SRC
  $dst = $env:OUI_DST
  $sb = New-Object System.Text.StringBuilder
  $count = 0
  foreach ($ln in [System.IO.File]::ReadLines($src)) {
    if ($null -eq $ln) { continue }
    if ($ln.Length -eq 0) { continue }
    if ($ln[0] -eq '#') { continue }
    $cols = $ln.Split([char]9)
    if ($cols.Count -lt 2) { continue }
    $pfx = $cols[0].Trim()
    if ($pfx.Length -ne 8) { continue }
    $hex = $true
    foreach ($ci in 0,1,3,4,6,7) {
      $n = [int]$pfx[$ci]
      if (-not (($n -ge 48 -and $n -le 57) -or ($n -ge 65 -and $n -le 70) -or ($n -ge 97 -and $n -le 102))) { $hex = $false; break }
    }
    if (-not $hex) { continue }
    if ($pfx[2] -ne ':') { continue }
    if ($pfx[5] -ne ':') { continue }
    $short = $cols[1].Trim()
    $full = ''
    if ($cols.Count -ge 3) { $full = $cols[2].Trim() }
    if ($full.Length -eq 0) { $full = $short }
    if ($full.Length -eq 0) { continue }
    $full = ($full -replace '[^\x20-\x7E]', '?').Replace('~', '-')
    $short = ($short -replace '[^\x20-\x7E]', '?').Replace('~', '-')
    [void]$sb.Append($pfx.Replace(':', '').ToUpper()).Append('~').Append($full).Append('~').Append($short).Append([char]13).Append([char]10)
    $count = $count + 1
  }
  if ($count -lt 30000) { throw ('Only ' + $count + ' entries parsed - source format may have changed') }
  [System.IO.File]::WriteAllText($dst, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
  Write-Output ('       Parsed ' + $count + ' vendor entries OK.')
  exit 0
} catch {
  Write-Output ('       Conversion error: ' + $_.Exception.Message)
  exit 1
}
rem PS_END_MARKER
