@echo off
setlocal EnableDelayedExpansion
title LAN Device Scanner Pro

REM ============================================================
REM  LAN Device Scanner Pro  (lan_scanner.cmd + lan_scanner.ps1)
REM ------------------------------------------------------------
REM  Scans the local /24 subnet and identifies every device:
REM    - IP + MAC ............... ARP sweep after parallel ping
REM    - MAC vendor ............. fully OFFLINE lookup of the
REM                               IEEE registry (full vendor
REM                               names) via oui_db.txt, cached
REM                               in oui_cache.txt
REM    - Names .................. NetBIOS, reverse DNS (PTR),
REM                               UPnP/SSDP, mDNS (Chromecast,
REM                               AirPlay, printers, IoT...)
REM    - Type fingerprint ....... TCP port probe (printer /
REM                               camera / NAS / Android / PC),
REM                               HTTP Server header + page title
REM    - Randomized-MAC detection (phones with private MAC)
REM
REM  Requirements : Windows 10/11. Keep lan_scanner.ps1 AND
REM                 oui_db.txt in the same folder as this .cmd.
REM                 100% offline - no internet needed.
REM  Output       : console table + LAN_Scan_Results.txt
REM  Runtime      : about 40 seconds.
REM  Notes        : scan only networks you own or are authorized
REM                 to test. Devices that block ping may be missed.
REM ============================================================

set "CACHE=%~dp0oui_cache.txt"
set "OUDB=%~dp0oui_db.txt"
set "RESULT=%~dp0LAN_Scan_Results.txt"
set "ENGINE=%~dp0lan_scanner.ps1"
set "DISCTXT=%TEMP%\dsh_disc.txt"
set "PROBEOUT=%TEMP%\dsh_probe_"
set "DEVLIST=%TEMP%\dsh_dev.txt"

if not exist "!ENGINE!" (
    echo  [ERROR] lan_scanner.ps1 not found next to this script.
    pause
    exit /b 1
)

echo.
echo  ============================================
echo           LAN Device Scanner Pro
echo  ============================================
echo.

REM ---- Phase 1: detect the local IPv4 address ----------------
set "LOCALIP="
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /I "IPv4"') do (
    if not defined LOCALIP (
        set "cand=%%a"
        set "cand=!cand: =!"
        if not "!cand:~0,4!"=="169." set "LOCALIP=!cand!"
    )
)
if not defined LOCALIP (
    echo  [ERROR] No IPv4 address detected. Check your network connection.
    pause
    exit /b 1
)
echo  Detected local IP : !LOCALIP!

set "PREFIX="
for /f "tokens=1-3 delims=." %%a in ("!LOCALIP!") do set "PREFIX=%%a.%%b.%%c"
set "CUSTOM="
set /p "CUSTOM=Network prefix to scan [!PREFIX!] or press Enter to accept: "
if defined CUSTOM set "PREFIX=!CUSTOM!"

REM ---- curl removed: vendor lookup is 100% offline ------------

echo.
echo  Phase 1/4: Pinging !PREFIX!.1-254 in parallel (about 15s)...
for /l %%i in (1,1,254) do start "" /b ping -n 1 -w 600 !PREFIX!.%%i >nul 2>&1
ping -n 13 127.0.0.1 >nul

set "GW="
for /f "tokens=1,3" %%g in ('route print -4 ^| findstr /C:" 0.0.0.0 "') do (
    if "%%g"=="0.0.0.0" if not defined GW set "GW=%%h"
)

REM ---- Phase 2: collect live devices from the ARP cache ------
echo  Phase 2/4: Collecting live devices + starting discovery...
type nul > "!DEVLIST!"
for /f "tokens=1,2" %%a in ('arp -a ^| findstr /R "^ *[0-9][0-9]*\."') do (
    set "ip=%%a"
    set "mac=%%b"
    if "!mac:~2,1!"=="-" if "!mac:~5,1!"=="-" (
        echo !ip!| findstr /B /C:"!PREFIX!." >nul
        if not errorlevel 1 if /I not "!mac!"=="ff-ff-ff-ff-ff-ff" if /I not "!mac!"=="00-00-00-00-00-00" (
            findstr /B /I /C:"!ip! " "!DEVLIST!" >nul 2>&1
            if errorlevel 1 >>"!DEVLIST!" echo !ip! !mac!
        )
    )
)

REM Make sure this PC itself is listed (NetBIOS may be off, so
REM take the local MAC from ipconfig /all, pattern based).
set "lastmac="
set "SELFMAC="
for /f "tokens=*" %%m in ('ipconfig /all') do (
    set "L=%%m"
    echo !L!| findstr /R /I /C:"[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f][0-9A-Fa-f]" >nul && for %%x in (!L!) do set "lastmac=%%x"
    if not defined SELFMAC echo !L!| findstr /C:"!LOCALIP!" >nul && set "SELFMAC=!lastmac!"
)
if "!SELFMAC!"=="" set "SELFMAC=00-00-00-00-00-00"
findstr /B /I /C:"!LOCALIP! " "!DEVLIST!" >nul 2>&1
if errorlevel 1 >>"!DEVLIST!" echo !LOCALIP! !SELFMAC!

REM ---- Launch discovery + per-device probes in parallel ------
del /q "!DISCTXT!" 2>nul
del /q "!PROBEOUT!*.txt" 2>nul
set /a NDEV=0
for /f "usebackq" %%a in ("!DEVLIST!") do set /a NDEV+=1
start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "!ENGINE!" -Mode discover -Out "!DISCTXT!" >nul 2>&1
for /f "usebackq tokens=1" %%a in ("!DEVLIST!") do (
    for /f "tokens=4 delims=." %%o in ("%%a") do (
        start "" /b powershell -NoProfile -ExecutionPolicy Bypass -File "!ENGINE!" -Mode probe -Ip %%a -Out "!PROBEOUT!%%o.txt" >nul 2>&1
    )
)

echo  Phase 3/4: Probing ports, NetBIOS, DNS, HTTP on !NDEV! devices...
set /a tries=0
:waitprobe
set /a tries+=1
ping -n 3 127.0.0.1 >nul
set "missing="
for /f "usebackq tokens=1" %%a in ("!DEVLIST!") do (
    for /f "tokens=4 delims=." %%o in ("%%a") do (
        if not exist "!PROBEOUT!%%o.txt" set "missing=1"
        findstr /C:"DONE" "!PROBEOUT!%%o.txt" >nul 2>&1
        if errorlevel 1 set "missing=1"
    )
)
if defined missing if !tries! LSS 12 goto waitprobe

REM ---- Phase 4: resolve details and print the table ----------
echo  Phase 4/4: Resolving details (first run may query vendor DB)...
> "!RESULT!" (
    echo LAN Scan Results - %date% %time%
    echo ==================================================
)
set /a FOUND=0
for /f "usebackq tokens=1,2" %%a in ("!DEVLIST!") do (
    set "ip=%%a"
    set "mac=%%b"
    set /a FOUND+=1
    for /f "tokens=4 delims=." %%o in ("%%a") do set "oct=%%o"
    call :process
)

echo.
if !FOUND! EQU 0 (
    echo  No devices found. Are you connected to the !PREFIX!.x network?
) else (
    >> "!RESULT!" echo.
    >> "!RESULT!" echo Total devices found: !FOUND!
    echo  Total devices found: !FOUND!
    echo  Full results saved to: !RESULT!
)
echo.
if exist "!DISCTXT!" del /q "!DISCTXT!"
if exist "!DEVLIST!" del /q "!DEVLIST!"
del /q "!PROBEOUT!*.txt" 2>nul
pause
exit /b 0


:process
REM In: ip, mac, oct. Gathers all info for one device, prints a
REM table row and appends it to the result file.
set "ports="
set "NAME="
set "DNSNAME="
set "SRV="
set "TITLE="
set "PROBEFILE=!PROBEOUT!%oct%.txt"
if exist "!PROBEFILE!" for /f "usebackq tokens=1,* delims==" %%a in ("!PROBEFILE!") do (
    if "%%a"=="PORTS" set "ports= %%b "
    if "%%a"=="NB" set "NAME=%%b"
    if "%%a"=="DNS" set "DNSNAME=%%b"
    if "%%a"=="SRV" set "SRV=%%b"
    if "%%a"=="TITLE" set "TITLE=%%b"
)

REM Discovery results (SSDP friendly names, mDNS instance names)
set "SSDPNAME="
set "SSDPMFR="
set "SSDPMODEL="
set "MDNSNAME="
if exist "!DISCTXT!" for /f "usebackq tokens=1-5 delims=~" %%i in ("!DISCTXT!") do (
    if /I "%%i"=="SSDP" if /I "%%j"=="%ip%" (
        set "SSDPNAME=%%k"
        set "SSDPMFR=%%l"
        set "SSDPMODEL=%%m"
    )
    if /I "%%i"=="MDNS" if /I "%%j"=="%ip%" if not defined MDNSNAME set "MDNSNAME=%%k"
)

REM Uppercase MAC, extract OUI prefix, randomized-MAC heuristic.
set "mac=!mac:a=A!"
set "mac=!mac:b=B!"
set "mac=!mac:c=C!"
set "mac=!mac:d=D!"
set "mac=!mac:e=E!"
set "mac=!mac:f=F!"
set "OUI=!mac:~0,8!"
set "RAND="
set "nib=!mac:~1,1!"
echo(!nib!| findstr /R /I /X "[2367ABEF]" >nul && set "RAND=1"

REM Vendor: cache file - offline IEEE database (full names)
set "VENDOR="
if defined RAND (set "VENDOR=(randomized MAC)") else call :getvendor

REM Open-port flags for type inference
set "P9100=" & set "P554=" & set "P5555=" & set "P8009=" & set "P32400="
set "P5000=" & set "P3389=" & set "P445=" & set "P5357=" & set "P22="
if defined ports call :portflags

REM Device type inference (most specific signal wins)
set "DETAILS="
if defined SSDPNAME (set "DETAILS=UPnP device: !SSDPNAME! / !SSDPMFR! !SSDPMODEL!" & goto det)
if defined P9100 (set "DETAILS=Printer (JetDirect 9100)" & goto det)
if defined P554 (set "DETAILS=IP camera / NVR (RTSP)" & goto det)
if defined P5555 (set "DETAILS=Android device (ADB open)" & goto det)
if defined P8009 (set "DETAILS=Chromecast / Android TV" & goto det)
if defined P32400 (set "DETAILS=Media server (Plex)" & goto det)
if defined P5000 (set "DETAILS=NAS / web service (port 5000)" & goto det)
if defined P3389 (set "DETAILS=Windows PC (RDP)" & goto det)
if defined P445 (set "DETAILS=Windows / Samba host (SMB)" & goto det)
if defined P5357 (set "DETAILS=Windows device (WSD)" & goto det)
if defined P22 (set "DETAILS=Linux / SSH host" & goto det)
if defined TITLE (set "DETAILS=Web UI: !TITLE! (Server: !SRV!)" & goto det)
if defined SRV (set "DETAILS=Web server: !SRV!" & goto det)
set "portsT=!ports: =!"
if defined portsT (set "DETAILS=Device (open ports:!ports:~1,-1!)" & goto det)
if defined MDNSNAME (set "DETAILS=mDNS service: !MDNSNAME!" & goto det)
if defined RAND (set "DETAILS=Mobile / IoT device (randomized MAC)" & goto det)
if defined VENDOR if not "!VENDOR!"=="unknown" (set "DETAILS=Device (no common ports open, see vendor)" & goto det)
set "DETAILS=Unknown device"
:det

REM Pick the best available name: SSDP - mDNS - NetBIOS - DNS
set "BESTNAME="
if defined SSDPNAME set "BESTNAME=!SSDPNAME!"
if not defined BESTNAME if defined MDNSNAME set "BESTNAME=!MDNSNAME!"
if not defined BESTNAME if defined NAME set "BESTNAME=!NAME!"
if not defined BESTNAME if defined DNSNAME set "BESTNAME=!DNSNAME!"
if not defined BESTNAME if /I "!ip!"=="!LOCALIP!" set "BESTNAME=%COMPUTERNAME%"
if defined BESTNAME set "DETAILS=!BESTNAME! - !DETAILS!"

set "TAG="
if /I "!ip!"=="!GW!" set "TAG=(default gateway)"
if /I "!ip!"=="!LOCALIP!" set "DETAILS=This PC (%COMPUTERNAME%)"

REM ---- Per-device card: one line per field, nothing truncated -
set "LINE1=  [!FOUND!] !ip!"
if defined TAG set "LINE1=  [!FOUND!] !ip! !TAG!"
set "LINE2=      MAC     : !mac!"
set "LINE3=      Vendor  : !VENDOR!"
set "LINE4=      Type    : !DETAILS!"
if defined BESTNAME set "LINE5=      Name    : !BESTNAME!"
echo.
echo !LINE1!
echo !LINE2!
echo !LINE3!
echo !LINE4!
if defined BESTNAME echo !LINE5!
>> "!RESULT!" echo.
>> "!RESULT!" echo !LINE1!
>> "!RESULT!" echo !LINE2!
>> "!RESULT!" echo !LINE3!
>> "!RESULT!" echo !LINE4!
if defined BESTNAME >> "!RESULT!" echo !LINE5!
goto :eof


:portflags
if not "!ports: 22 =!"=="!ports!" set "P22=1"
if not "!ports: 445 =!"=="!ports!" set "P445=1"
if not "!ports: 554 =!"=="!ports!" set "P554=1"
if not "!ports: 3389 =!"=="!ports!" set "P3389=1"
if not "!ports: 5000 =!"=="!ports!" set "P5000=1"
if not "!ports: 5357 =!"=="!ports!" set "P5357=1"
if not "!ports: 5555 =!"=="!ports!" set "P5555=1"
if not "!ports: 8009 =!"=="!ports!" set "P8009=1"
if not "!ports: 9100 =!"=="!ports!" set "P9100=1"
if not "!ports: 32400 =!"=="!ports!" set "P32400=1"
goto :eof


:getvendor
REM In: OUI (AA-BB-CC). Out: VENDOR (full IEEE registry name).
REM Fully offline: cache file first, then bundled oui_db.txt.
REM The database is keyed by the dashless OUI (AABBCC).
set "OUIK=!OUI:-=!"
set "VENDOR="
if exist "%CACHE%" for /f "usebackq tokens=1,2 delims=~" %%a in ("%CACHE%") do if /I "%%a"=="!OUIK!" set "VENDOR=%%b"
if defined VENDOR goto :eof
if exist "%OUDB%" for /f "usebackq tokens=1,2 delims=~" %%a in ("%OUDB%") do if /I "%%a"=="!OUIK!" (
    set "VENDOR=%%b"
    >>"%CACHE%" echo !OUIK!~!VENDOR!
)
if defined VENDOR goto :eof
set "VENDOR=unknown"
goto :eof
