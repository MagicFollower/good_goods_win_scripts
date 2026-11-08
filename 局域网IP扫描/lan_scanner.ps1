param(
    [Parameter(Mandatory=$true)][string]$Mode,
    [string]$Ip = '',
    [string]$Out = ''
)
# LAN Device Scanner Pro - PowerShell engine
#   Mode "discover": SSDP + mDNS discovery, writes DISCP/MDNS lines
#   Mode "probe"   : per-device probe (ports, NetBIOS, DNS, HTTP)
$ErrorActionPreference = 'SilentlyContinue'
$lines = @()

if ($Mode -eq 'discover') {

    # ---- SSDP (UPnP) discovery ----
    $udp = New-Object Net.Sockets.UdpClient
    $udp.EnableBroadcast = $true
    $ep = New-Object Net.IPEndPoint([Net.IPAddress]::Parse('239.255.255.250'), 1900)
    $m = "M-SEARCH * HTTP/1.1`r`nHOST: 239.255.255.250:1900`r`nMAN: `"ssdp:discover`"`r`nMX: 3`r`nST: ssdp:all`r`n`r`n"
    $b = [Text.Encoding]::ASCII.GetBytes($m)
    $null = $udp.Send($b, $b.Length, $ep)
    Start-Sleep -Milliseconds 300
    $null = $udp.Send($b, $b.Length, $ep)
    $udp.Client.ReceiveTimeout = 1500
    $seen = @{}
    $dl = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $dl) {
        try { $r = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $d = $udp.Receive([ref]$r) } catch { continue }
        $ip = $r.Address.ToString()
        if ($seen.ContainsKey($ip)) { continue }
        $t = [Text.Encoding]::ASCII.GetString($d)
        $loc = ''
        foreach ($ln in $t.Split([char]10)) {
            $u = $ln.Trim().ToUpper()
            if ($u.StartsWith('LOCATION:') -and $ln.Trim().Length -gt 10) { $loc = $ln.Trim().Substring(10).Trim() }
        }
        $seen[$ip] = $loc
    }
    $udp.Close()
    foreach ($k in $seen.Keys) {
        $nm = ''; $mf = ''; $md = ''
        $loc = $seen[$k]
        if ($loc -like 'http*') {
            try {
                $x = [xml](Invoke-WebRequest -Uri $loc -TimeoutSec 3 -UseBasicParsing).Content
                $nm = [string]$x.root.device.friendlyName
                $mf = [string]$x.root.device.manufacturer
                $md = [string]$x.root.device.modelName
            } catch {}
        }
        $lines += ('SSDP~' + $k + '~' + $nm + '~' + $mf + '~' + $md)
    }

    # ---- mDNS discovery (Chromecast, AirPlay, printers, IoT) ----
    $u2 = New-Object Net.Sockets.UdpClient
    $u2.JoinMulticastGroup([Net.IPAddress]::Parse('224.0.0.251'))
    $mep = New-Object Net.IPEndPoint([Net.IPAddress]::Parse('224.0.0.251'), 5353)
    $qt = @('_googlecast._tcp.local','_airplay._tcp.local','_raop._tcp.local','_printer._tcp.local','_ipp._tcp.local','_smb._tcp.local','_spotify-connect._tcp.local','_hap._tcp.local','_androidtvremote2._tcp.local','_nx._tcp.local')
    $ms = New-Object System.IO.MemoryStream
    $w = New-Object System.IO.BinaryWriter($ms)
    $w.Write([UInt16]0); $w.Write([UInt16]0); $w.Write([UInt16]$qt.Count); $w.Write([UInt16]0); $w.Write([UInt16]0); $w.Write([UInt16]0)
    foreach ($n in $qt) {
        foreach ($lbl in $n.Split('.')) {
            if ($lbl) { $bb = [Text.Encoding]::ASCII.GetBytes($lbl); $w.Write([Byte]$bb.Length); $w.Write($bb) }
        }
        $w.Write([Byte]0); $w.Write([UInt16]12); $w.Write([UInt16]1)
    }
    $w.Flush()
    $pkt = $ms.ToArray()
    $null = $u2.Send($pkt, $pkt.Length, $mep)
    Start-Sleep -Milliseconds 400
    $null = $u2.Send($pkt, $pkt.Length, $mep)
    $u2.Client.ReceiveTimeout = 1000

    function RdName($buf, [ref]$pos) {
        $parts = @(); $jump = -1; $p = $pos.Value; $g = 0
        while ($true) {
            if ($p -ge $buf.Length -or $g -gt 40) { break }
            $len = $buf[$p]
            if ($len -eq 0) { $p++; break }
            if (($len -band 0xC0) -eq 0xC0) {
                if ($jump -lt 0) { $jump = $p + 2 }
                $p = (($len -band 0x3F) -shl 8) -bor $buf[$p + 1]
                $g++; continue
            }
            $p++
            $parts += ([Text.Encoding]::ASCII.GetString($buf, $p, $len))
            $p += $len
        }
        if ($jump -ge 0) { $pos.Value = $jump } else { $pos.Value = $p }
        return ($parts -join '.')
    }

    $mips = @{}
    $dl2 = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $dl2) {
        try { $rr = New-Object Net.IPEndPoint([Net.IPAddress]::Any, 0); $dd = $u2.Receive([ref]$rr) } catch { continue }
        $pos = 12
        $qd = ($dd[6] -shl 8) -bor $dd[7]
        $an = ($dd[8] -shl 8) -bor $dd[9]
        for ($i = 0; $i -lt $qd; $i++) { $null = RdName $dd ([ref]$pos); $pos += 4 }
        for ($i = 0; $i -lt ($an + $qd); $i++) {
            $nm2 = RdName $dd ([ref]$pos)
            if ($pos + 10 -gt $dd.Length) { break }
            $typ = ($dd[$pos] -shl 8) -bor $dd[$pos + 1]
            $rdl = ($dd[$pos + 8] -shl 8) -bor $dd[$pos + 9]
            $pos += 10
            if ($typ -eq 1 -and $rdl -eq 4) {
                $mip = '{0}.{1}.{2}.{3}' -f $dd[$pos], $dd[$pos+1], $dd[$pos+2], $dd[$pos+3]
                if (-not $mips.ContainsKey($mip)) { $mips[$mip] = $nm2 }
                $pos += $rdl
            } else { $pos += $rdl }
            if ($pos -ge $dd.Length) { break }
        }
    }
    $u2.Close()
    foreach ($k2 in $mips.Keys) { $lines += ('MDNS~' + $k2 + '~' + $mips[$k2] + '~~') }

} elseif ($Mode -eq 'probe') {

    $open = @()
    foreach ($p in @(22,80,443,445,554,3389,5000,5357,5555,8009,8080,8443,9100,32400)) {
        $c = New-Object Net.Sockets.TcpClient
        try {
            $a = $c.BeginConnect($Ip, $p, $null, $null)
            if ($a.AsyncWaitHandle.WaitOne(250) -and $c.Connected) { $open += $p }
        } catch {}
        try { $c.Close() } catch {}
    }

    $nb = ''
    $t = (nbtstat -A $Ip 2>&1 | Out-String)
    foreach ($ln in $t.Split([char]10)) {
        if (($ln -match 'UNIQUE') -and (-not $nb)) { $nb = ($ln.Trim() -split '\s+')[0] }
    }

    $dns = ''
    try { $h = [System.Net.Dns]::GetHostEntry($Ip); if ($h.HostName) { $dns = $h.HostName.Split('.')[0] } } catch {}

    $srv = ''; $title = ''
    $hp = @(80,8080,5000,5357) | Where-Object { $open -contains $_ }
    $hs = @(443,8443) | Where-Object { $open -contains $_ }
    $url = $null
    if ($hp.Count -gt 0) {
        $url = 'http://' + $Ip + ':' + $hp[0] + '/'
    } elseif ($hs.Count -gt 0) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
        $url = 'https://' + $Ip + ':' + $hs[0] + '/'
    }
    if ($url) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            $req.Timeout = 3000; $req.ReadWriteTimeout = 3000; $req.UserAgent = 'Mozilla/5.0'
            $resp = $req.GetResponse()
            $srv = $resp.Headers['Server']
            $sr = New-Object IO.StreamReader($resp.GetResponseStream())
            $html = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
        } catch {
            try { if ($_.Exception.Response) { $srv = $_.Exception.Response.Headers['Server'] } } catch {}
        }
    }
    if ($html) {
        $i = $html.IndexOf('<title')
        if ($i -ge 0) {
            $j = $html.IndexOf('>', $i)
            $k = $html.IndexOf('</title', $j)
            if (($j -ge 0) -and ($k -gt $j)) { $title = $html.Substring($j + 1, $k - $j - 1).Trim() }
        }
    }

    $lines += ('PORTS=' + ($open -join ' '))
    $lines += ('NB=' + $nb)
    $lines += ('DNS=' + $dns)
    $lines += ('SRV=' + $srv)
    $lines += ('TITLE=' + $title)
    $lines += 'DONE'
}

if ($Out) { Set-Content -Path $Out -Value $lines -Encoding Default }
