@echo off
REM =====================================================================
REM  Port Query and Kill Tool  v3.0
REM  Drop-in replacement for port_killer.bat v2.1
REM  Save this file as ANSI/ASCII or UTF-8 WITHOUT BOM.
REM
REM  Usage:
REM      port_killer_v3.cmd            interactive mode
REM      port_killer_v3.cmd ^<port^>     port given on command line
REM                                    (killing still asks for confirmation)
REM
REM  Key changes vs v2.1:
REM   [FIX ] match LOCAL port only. v2.1 also matched the remote-address
REM          column, so e.g. querying port 443 listed (and killed) every
REM          browser holding an outbound HTTPS connection
REM   [FIX ] exact port match - Get-NetTCPConnection/Get-UDPEndpoint when
REM          available, else netstat -ano parsed by column with an
REM          end-anchored port (v2.1 used loose findstr text matching);
REM          UDP ports are now covered too
REM   [FIX ] no wmic anywhere (wmic is removed in Windows 11 24H2);
REM          process info via Get-Process/Get-CimInstance with graceful
REM          degradation when access is denied
REM   [FIX ] memory of processes larger than 2 GB no longer overflows
REM   [FIX ] leading-zero ports no longer treated as octal; embedded
REM          spaces in input are rejected instead of silently joined
REM   [SAFE] PIDs are re-queried right before killing (PID-reuse guard)
REM   [SAFE] critical system processes are refused outright;
REM          svchost.exe and name-unknown processes require typing the
REM          PID to confirm; warns that taskkill /T kills child trees
REM   [SAFE] verifies the port is actually released after killing
REM   [UX  ] invalid input loops back instead of exiting;
REM          console codepage restored on exit; meaningful exit codes:
REM          0 = quit/cancel  1 = error  2 = port freed  3 = still in use
REM
REM  Requires: PowerShell 3+ (Windows 8+ / Server 2012+)
REM =====================================================================
setlocal EnableExtensions EnableDelayedExpansion

rem ---- remember console codepage so it can be restored on exit --------
rem Interactive console only: with redirected stdin (scripted use),
rem chcp 65001 would consume ALL piped input and break every later
rem set /p, so the codepage switch is skipped entirely there.
set "OLDCP="
powershell -NoProfile -Command "if([Console]::IsInputRedirected){exit 0}else{exit 1}" >nul 2>&1
if errorlevel 1 (
    for /f "usebackq tokens=2 delims=:" %%c in (`chcp ^<nul 2^>nul`) do set "OLDCP=%%c"
    chcp 65001 >nul 2>&1
)
title Port Query and Kill Tool v3.0

set "TMPPRE=%TEMP%\pktv3_%RANDOM%"
set "PIDFILE=%TMPPRE%_pids.tmp"
set "NAMEFILE=%TMPPRE%_names.tmp"
set "DETAILFILE=%TMPPRE%_detail.tmp"
set "EC=0"

rem ---- elevation hint ---------------------------------------------------
net session >nul 2>&1
if errorlevel 1 (
    echo [TIP] Not elevated: some processes may show no details and may
    echo       refuse to be killed. Re-run as Administrator if needed.
    echo.
)

echo ================================================================
echo              Port Query and Kill Tool  v3.0
echo ================================================================
echo.

set "HAVEARG="
set "ARGMODE="
if not "%~1"=="" (
    set "HAVEARG=1"
    set "ARGMODE=1"
    set "PORT=%~1"
    call :VALIDATE_PORT
    if not "!PORTOK!"=="1" (
        echo [ERROR] Invalid port number: "%~1"
        echo Usage: %~nx0 [port 1-65535]
        set "EC=1"
        goto END
    )
)

:ASK_PORT
if not defined HAVEARG (
    set "PORT="
    set /p "PORT=Enter port number (1-65535, press Enter to quit): "
    if not defined PORT (
        echo [INFO] Bye.
        goto END
    )
    call :VALIDATE_PORT
    if not "!PORTOK!"=="1" (
        echo [ERROR] Invalid port number, please try again.
        goto ASK_PORT
    )
)
set "HAVEARG="

echo.
echo ----------------------------------------------------------------
echo   Querying port !PORT! ...
echo ----------------------------------------------------------------

call :QUERY_PIDS
if not exist "%PIDFILE%" (
    echo.
    echo [INFO] No process is using port !PORT!.
    echo        There may be lingering TIME_WAIT/CLOSE_WAIT sockets,
    echo        but those have no owner process and need no killing.
    if defined ARGMODE goto END
    goto ASK_PORT
)

type "%DETAILFILE%"
del "%DETAILFILE%" 2>nul

:MENU
echo.
echo   [1] Kill the process(es) using port !PORT!
echo   [2] Query another port
echo   [3] Exit
set "CHOICE="
set /p "CHOICE=Select (1/2/3): "
if not defined CHOICE (
    echo [INFO] Bye.
    goto END
)
if defined CHOICE set CHOICE=!CHOICE:"=!
if "!CHOICE!"=="1" goto KILL
if "!CHOICE!"=="2" goto ASK_PORT
if "!CHOICE!"=="3" goto END
echo [ERROR] Invalid option.
goto MENU

:KILL
echo.
echo Re-checking port !PORT! before killing ...
call :QUERY_PIDS
if not exist "%PIDFILE%" (
    echo [INFO] Port !PORT! is no longer in use. Nothing to kill.
    del "%DETAILFILE%" 2>nul
    goto MENU
)
del "%DETAILFILE%" 2>nul

set "CNT=0"
for /f "usebackq delims=" %%L in ("%NAMEFILE%") do (
    set /a CNT+=1
    for /f "tokens=1,2 delims==" %%a in ("%%L") do (
        set "KP[!CNT!]=%%a"
        set "KN[!CNT!]=%%b"
    )
)

rem ---- classify: critical(refuse) / svchost-or-unknown(confirm) / rest --
set "PEND= "
set "NEEDCONFIRM= "
set "BLOCKED= "
for /L %%i in (1,1,!CNT!) do (
    set "B="
    if /i "!KN[%%i]!"=="Idle"     set "B=1"
    if /i "!KN[%%i]!"=="System"   set "B=1"
    if /i "!KN[%%i]!"=="Registry" set "B=1"
    if /i "!KN[%%i]!"=="smss"     set "B=1"
    if /i "!KN[%%i]!"=="csrss"    set "B=1"
    if /i "!KN[%%i]!"=="wininit"  set "B=1"
    if /i "!KN[%%i]!"=="winlogon" set "B=1"
    if /i "!KN[%%i]!"=="services" set "B=1"
    if /i "!KN[%%i]!"=="lsass"    set "B=1"
    if "!B!"=="1" (
        set "BLOCKED=!BLOCKED!!KP[%%i]! "
    ) else if /i "!KN[%%i]!"=="svchost" (
        set "NEEDCONFIRM=!NEEDCONFIRM!!KP[%%i]! "
    ) else if /i "!KN[%%i]!"=="Unknown" (
        set "NEEDCONFIRM=!NEEDCONFIRM!!KP[%%i]! "
    ) else (
        set "PEND=!PEND!!KP[%%i]! "
    )
)

if "!BLOCKED!" NEQ " " (
    echo.
    echo [REFUSED] Critical system process^(es^), will NOT be killed:!BLOCKED!
    echo           Killing them can crash Windows. If port !PORT! is held
    echo           by PID 4 ^(System^), the real listener is usually HTTP.sys
    echo           or a port proxy. Inspect with:
    echo             netsh http show servicestate
    echo             netsh interface portproxy show all
)
for %%p in (!NEEDCONFIRM!) do (
    echo.
    set "T="
    set /p "T=PID %%p is svchost or name-unknown. Type the PID to confirm killing it (anything else skips): "
    if defined T set T=!T:"=!
    if /i "!T!"=="%%p" (set "PEND=!PEND!%%p ") else echo   [SKIP] PID %%p skipped.
)

if "!PEND!"==" " (
    echo.
    echo [INFO] No eligible process left to kill.
    goto MENU
)

echo.
echo ----------------------------------------------------------------
echo   WARNING: taskkill /F /T will FORCE-terminate:
for %%p in (!PEND!) do echo      PID %%p
echo   ... including ALL of their child processes.
echo ----------------------------------------------------------------
set "CONFIRM="
set /p "CONFIRM=Proceed? (Y/N): "
if not defined CONFIRM (
    echo [INFO] Cancelled.
    goto MENU
)
if defined CONFIRM set CONFIRM=!CONFIRM:"=!
if /i not "!CONFIRM!"=="Y" (
    echo [INFO] Cancelled.
    goto MENU
)

echo.
for %%p in (!PEND!) do (
    taskkill /PID %%p /F /T >nul 2>&1
    if errorlevel 1 (
        echo   [FAIL] Could not kill PID %%p ^(access denied? try Admin^)
    ) else (
        echo   [OK]   PID %%p terminated.
    )
)

rem ---- verify the port is actually released ----------------------------
ping -n 2 127.0.0.1 >nul
call :QUERY_PIDS
del "%DETAILFILE%" 2>nul
echo.
if not exist "%PIDFILE%" (
    echo [DONE] Port !PORT! has been released.
    set "EC=2"
) else (
    echo [WARN] Port !PORT! is still in use by:
    for /f "usebackq delims=" %%p in ("%PIDFILE%") do echo        PID %%p
    set "EC=3"
)
if defined ARGMODE goto END
goto ASK_PORT

:END
del "%PIDFILE%" "%NAMEFILE%" "%DETAILFILE%" "%TEMP%\pkquery_v2.ps1" 2>nul
if defined OLDCP chcp !OLDCP!>nul 2>&1
if not defined ARGMODE pause
endlocal & exit /b %EC%

REM =====================================================================
REM  Subroutines
REM =====================================================================

REM Validate global PORT: digits only, 1-65535. Leading zeros stripped.
REM Sets PORTOK=1 and normalizes PORT on success.
:VALIDATE_PORT
set "PORTOK=1"
for /f "delims=0123456789" %%x in ("!PORT!") do set "PORTOK=0"
if not "!PORT:~5,1!"=="" set "PORTOK=0"
if "!PORTOK!"=="0" goto :eof
for /f "tokens=* delims=0" %%z in ("!PORT!") do set "PORT=%%z"
if not defined PORT (
    set "PORTOK=0"
    goto :eof
)
if !PORT! LSS 1 set "PORTOK=0"
if !PORT! GTR 65535 set "PORTOK=0"
goto :eof

REM Query LOCAL port exactly. Builds a helper ps1 once in TEMP, runs it.
REM Produces (only when at least one owning PID exists):
REM   PIDFILE    one owning PID per line      (absent = port free)
REM   NAMEFILE   PID=ProcessName lines
REM   DETAILFILE formatted report, shown later via `type`
REM Preference: Get-NetTCPConnection/Get-UDPEndpoint; falls back to
REM netstat -ano with column-exact, end-anchored port matching.
:QUERY_PIDS
del "%PIDFILE%" "%NAMEFILE%" "%DETAILFILE%" 2>nul
set "PSSCRIPT=%TEMP%\pkquery_v2.ps1"
if not exist "%PSSCRIPT%" call :BUILD_PS
set "PKPORT=!PORT!"
set "PKPIDFILE=%PIDFILE%"
set "PKNAMEFILE=%NAMEFILE%"
set "PKDETAILFILE=%DETAILFILE%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$port=$env:PKPORT; Invoke-Expression (Get-Content -LiteralPath ($env:TEMP + '\pkquery_v2.ps1') -Raw)"
goto :eof

:BUILD_PS
break > "%PSSCRIPT%"
>>"%PSSCRIPT%" echo $ErrorActionPreference = 'SilentlyContinue'
>>"%PSSCRIPT%" echo $port = [int]$env:PKPORT
>>"%PSSCRIPT%" echo $conns = @()
>>"%PSSCRIPT%" echo $tcp = $null; $udp = $null
>>"%PSSCRIPT%" echo try { $tcp = Get-NetTCPConnection -LocalPort $port -ErrorAction Stop } catch {}
>>"%PSSCRIPT%" echo try { $udp = Get-UDPEndpoint -LocalPort $port -ErrorAction Stop } catch {}
>>"%PSSCRIPT%" echo if ($tcp) { foreach ($c in $tcp) { $conns += [pscustomobject]@{Proto='TCP';Local=('{0}:{1}' -f $c.LocalAddress,$c.LocalPort);Remote=('{0}:{1}' -f $c.RemoteAddress,$c.RemotePort);State=$c.State;PID=[int]$c.OwningProcess} } }
>>"%PSSCRIPT%" echo if ($udp) { foreach ($c in $udp) { $conns += [pscustomobject]@{Proto='UDP';Local=('{0}:{1}' -f $c.LocalAddress,$c.LocalPort);Remote='*:*';State='-';PID=[int]$c.OwningProcess} } }
>>"%PSSCRIPT%" echo if (@($conns).Count -eq 0) {
>>"%PSSCRIPT%" echo     foreach ($line in (netstat -ano -p tcp)) {
>>"%PSSCRIPT%" echo         $t = $line -split '\s+' ^| Where-Object { $_ }
>>"%PSSCRIPT%" echo         if ($t.Count -ge 5 -and $t[0] -eq 'TCP' -and $t[1] -match ':([0-9]+)$' -and $Matches[1] -eq [string]$port) {
>>"%PSSCRIPT%" echo             $conns += [pscustomobject]@{Proto='TCP';Local=$t[1];Remote=$t[2];State=$t[3];PID=[int]$t[4]}
>>"%PSSCRIPT%" echo         }
>>"%PSSCRIPT%" echo     }
>>"%PSSCRIPT%" echo     foreach ($line in (netstat -ano -p udp)) {
>>"%PSSCRIPT%" echo         $t = $line -split '\s+' ^| Where-Object { $_ }
>>"%PSSCRIPT%" echo         if ($t.Count -ge 4 -and $t[0] -eq 'UDP' -and $t[1] -match ':([0-9]+)$' -and $Matches[1] -eq [string]$port) {
>>"%PSSCRIPT%" echo             $conns += [pscustomobject]@{Proto='UDP';Local=$t[1];Remote='*:*';State='-';PID=[int]$t[3]}
>>"%PSSCRIPT%" echo         }
>>"%PSSCRIPT%" echo     }
>>"%PSSCRIPT%" echo }
>>"%PSSCRIPT%" echo $ids = @($conns ^| ForEach-Object { [int]$_.PID } ^| Where-Object { $_ -gt 0 } ^| Sort-Object -Unique)
>>"%PSSCRIPT%" echo function ProcName([int]$i) {
>>"%PSSCRIPT%" echo     $p = Get-Process -Id $i -ErrorAction SilentlyContinue
>>"%PSSCRIPT%" echo     if ($p) { return $p.ProcessName }
>>"%PSSCRIPT%" echo     $c = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $i) -ErrorAction SilentlyContinue
>>"%PSSCRIPT%" echo     if ($c) { return [IO.Path]::GetFileNameWithoutExtension($c.Name) }
>>"%PSSCRIPT%" echo     return 'Unknown'
>>"%PSSCRIPT%" echo }
>>"%PSSCRIPT%" echo $sb = New-Object System.Text.StringBuilder
>>"%PSSCRIPT%" echo [void]$sb.AppendLine('[1] Connections with local port ' + $port)
>>"%PSSCRIPT%" echo if ($conns.Count -eq 0) { [void]$sb.AppendLine('  (none)') }
>>"%PSSCRIPT%" echo else { [void]$sb.AppendLine(($conns ^| Sort-Object Proto,State,Local ^| Format-Table Proto,Local,Remote,State,PID -AutoSize ^| Out-String -Width 200).TrimEnd()) }
>>"%PSSCRIPT%" echo [void]$sb.AppendLine('')
>>"%PSSCRIPT%" echo [void]$sb.AppendLine('[2] Owning processes')
>>"%PSSCRIPT%" echo foreach ($i in $ids) {
>>"%PSSCRIPT%" echo     $name = ProcName $i
>>"%PSSCRIPT%" echo     $ci = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $i) -ErrorAction SilentlyContinue
>>"%PSSCRIPT%" echo     $pr = Get-Process -Id $i -ErrorAction SilentlyContinue
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('')
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('  ---- PID ' + $i + ' ----')
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('    Name         : ' + $name)
>>"%PSSCRIPT%" echo     if ($ci) { [void]$sb.AppendLine('    Parent PID   : ' + $ci.ParentProcessId); [void]$sb.AppendLine('    Command line : ' + $(if ($ci.CommandLine){$ci.CommandLine}else{'N/A'})) } else { [void]$sb.AppendLine('    Parent PID   : N/A (info denied)'); [void]$sb.AppendLine('    Command line : N/A (info denied)') }
>>"%PSSCRIPT%" echo     $own = ''
>>"%PSSCRIPT%" echo     if ($ci) { $o = Invoke-CimMethod -InputObject $ci -MethodName GetOwner -ErrorAction SilentlyContinue; if ($o -and $o.User) { $own = $o.Domain + '\' + $o.User } }
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('    User         : ' + $(if ($own){$own}else{'N/A'}))
>>"%PSSCRIPT%" echo     $st = 'N/A'
>>"%PSSCRIPT%" echo     if ($pr) { try { $st = $pr.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { $st = 'N/A (denied)' } }
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('    Start time   : ' + $st)
>>"%PSSCRIPT%" echo     $mem = 'N/A'
>>"%PSSCRIPT%" echo     if ($pr) { $mem = ('{0:N1} MB' -f ($pr.WorkingSet64 / 1MB)) }
>>"%PSSCRIPT%" echo     elseif ($ci -and $ci.WorkingSetSize) { $mem = ('{0:N1} MB' -f ([double]$ci.WorkingSetSize / 1MB)) }
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('    Memory       : ' + $mem)
>>"%PSSCRIPT%" echo     $path = 'N/A'
>>"%PSSCRIPT%" echo     if ($pr -and $pr.Path) { $path = $pr.Path } elseif ($ci -and $ci.ExecutablePath) { $path = $ci.ExecutablePath }
>>"%PSSCRIPT%" echo     [void]$sb.AppendLine('    Path         : ' + $path)
>>"%PSSCRIPT%" echo     $svc = Get-CimInstance Win32_Service -Filter ('ProcessId=' + $i) -ErrorAction SilentlyContinue
>>"%PSSCRIPT%" echo     if ($svc) { [void]$sb.AppendLine('    Services     :'); foreach ($s in $svc) { [void]$sb.AppendLine('      ' + $s.Name + '  [' + $s.State + ']  ' + $s.DisplayName) } }
>>"%PSSCRIPT%" echo     else { [void]$sb.AppendLine('    Services     : none') }
>>"%PSSCRIPT%" echo }
>>"%PSSCRIPT%" echo if ($ids.Count -gt 0) {
>>"%PSSCRIPT%" echo     Set-Content -LiteralPath $env:PKPIDFILE -Value ($ids ^| ForEach-Object { $_.ToString() }) -Encoding ascii
>>"%PSSCRIPT%" echo     $nl = @(); foreach ($i in $ids) { $nl += ($i.ToString() + '=' + (ProcName $i)) }
>>"%PSSCRIPT%" echo     Set-Content -LiteralPath $env:PKNAMEFILE -Value $nl -Encoding ascii
>>"%PSSCRIPT%" echo }
>>"%PSSCRIPT%" echo [IO.File]::WriteAllText($env:PKDETAILFILE, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
goto :eof
