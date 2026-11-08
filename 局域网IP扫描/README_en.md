# LAN Device Scanner Pro

A 100% offline LAN device discovery toolkit for Windows. Double-click one
`.cmd` file and get every device on your local `/24` network with its IP,
MAC address, **full IEEE vendor name**, device type and — when the device
advertises one — its host name.

All user-facing output is in English. No installation, no admin rights,
no internet connection required for scanning.

---

## Contents

- [Files in this toolkit](#files-in-this-toolkit)
- [Quick start](#quick-start)
- [What you get](#what-you-get)
- [How it works](#how-it-works)
- [Identification layers](#identification-layers)
- [Sample output](#sample-output)
- [Updating the vendor database](#updating-the-vendor-database)
- [Requirements](#requirements)
- [Output files](#output-files)
- [FAQ / Troubleshooting](#faq--troubleshooting)
- [Responsible use](#responsible-use)
- [Technical notes](#technical-notes)

---

## Files in this toolkit

| File | Size | Purpose |
|---|---|---|
| `lan_scanner.cmd` | ~12 KB | Main scanner. **Double-click to run.** |
| `lan_scanner.ps1` | ~7.5 KB | Probe engine (ports / NetBIOS / DNS / HTTP / SSDP / mDNS). Must sit next to the `.cmd`. |
| `oui_db.txt` | ~1.7 MB | Offline vendor database: 40,207 OUI prefixes with full IEEE registry names. |
| `update_oui_db.cmd` | ~6 KB | Vendor database updater. **Double-click to update** `oui_db.txt`. |
| `oui_cache.txt` | (created) | Lookup cache written by the scanner; speeds up later runs. Safe to delete. |
| `LAN_Scan_Results.txt` | (created) | Scan report, same card format as the console output. |

> **Keep `lan_scanner.cmd`, `lan_scanner.ps1` and `oui_db.txt` together in
> the same folder.** That is the only layout requirement.

---

## Quick start

1. Put the four toolkit files in one folder.
2. Connect your PC to the LAN you want to inspect (Wi-Fi or Ethernet).
3. Double-click **`lan_scanner.cmd`**.
4. Press **Enter** to accept the detected network prefix, or type another
   one (e.g. `10.0.1`) and press Enter.
5. Wait about 40 seconds. Results appear as device cards and are saved to
   `LAN_Scan_Results.txt`.

To refresh the vendor database later (about once or twice a year is
plenty), double-click **`update_oui_db.cmd`** — see
[Updating the vendor database](#updating-the-vendor-database).

---

## What you get

For every live device found on the subnet, one card:

```
  [1] 192.168.3.1 (default gateway)
      MAC     : 74-30-AF-98-73-70
      Vendor  : Fiberhome Telecommunication Technologies Co.,LTD
      Type    : Device (open ports:80 443)

  [2] 192.168.3.90
      MAC     : DC-62-94-1F-CC-70
      Vendor  : Guangzhou Lango Electronics Technology Co.,Ltd.
      Type    : IP camera / NVR (RTSP)

  [9] 192.168.3.103
      MAC     : F4-A4-75-3E-48-51
      Vendor  : Intel Corporate
      Type    : This PC (X)
      Name    : X
```

- The `Name` line appears only when a real host name was resolved
  (SSDP / mDNS / NetBIOS / reverse DNS).
- Vendor names are the complete legal names from the IEEE registry —
  never truncated, one per line.

---

## How it works

Four phases, all built on Windows built-in tools
(`ping`, `arp`, `route`, `nbtstat`, `ipconfig`) plus one bundled
PowerShell engine:

| Phase | What happens | Time |
|---|---|---|
| 1 | Auto-detects the local IPv4 address and `/24` prefix; pings all 254 addresses in parallel to fill the ARP cache | ~15 s |
| 2 | Reads the ARP cache; collects live IP + MAC pairs (filters broadcast and invalid MACs); makes sure this PC is listed | ~1 s |
| 3 | In parallel per device: SSDP + mDNS discovery (network-wide) and a per-device probe — 14 TCP ports, NetBIOS name, reverse DNS, HTTP `Server` header + page `<title>` | ~10-25 s |
| 4 | Looks up the vendor for each MAC (cache → offline database), infers the device type from all signals, prints the cards | ~1-2 s |

### Port → device type mapping

| Open port | Inferred type |
|---|---|
| 9100 | Printer (JetDirect) |
| 554 | IP camera / NVR (RTSP) |
| 5555 | Android device (ADB) |
| 8009 | Chromecast / Android TV |
| 32400 | Media server (Plex) |
| 5000 | NAS / web service (Synology-style) |
| 3389 | Windows PC (RDP) |
| 445 | Windows / Samba host (SMB) |
| 5357 | Windows device (WSD) |
| 22 | Linux / SSH host |
| 80/443/8080/… | Web UI fingerprint (HTTP title + server header) |

The most specific signal wins; everything else falls back to
`Device (open ports:…)`.

---

## Identification layers

1. **MAC vendor (offline)** — the OUI prefix (`AA-BB-CC`) is looked up in
   `oui_db.txt`, which contains the full IEEE registry names for 40,207
   24-bit prefixes. Recent lookups are cached in `oui_cache.txt`.
   No internet is used, ever.
2. **Randomized MAC detection** — if the second hex digit of the first
   octet is `2/3/6/7/A/B/E/F`, the MAC is likely a phone's "private
   Wi-Fi address"; the card shows `(randomized MAC)` and the device is
   typed as mobile/IoT.
3. **TCP port fingerprinting** — 14 well-known ports
   (22, 80, 443, 445, 554, 3389, 5000, 5357, 5555, 8009, 8080, 8443,
   9100, 32400) are probed with a 250 ms timeout each, in parallel.
4. **Name resolution** — tried in order, first hit wins:
   SSDP friendly name → mDNS instance name → NetBIOS (`nbtstat`)
   → reverse DNS (PTR) → `%COMPUTERNAME%` for this PC itself.
5. **Discovery protocols** — an SSDP `M-SEARCH` (UPnP: routers, TVs,
   NAS, printers) and an mDNS query burst (Chromecast, AirPlay,
   printers, HomeKit, Android TV) run while the port probes execute.
   Their answers supply friendly names and model strings.

---

## Sample output

```
 ============================================
          LAN Device Scanner Pro
 ============================================

 Detected local IP : 192.168.3.103
Network prefix to scan [192.168.3] or press Enter to accept:
 Phase 1/4: Pinging 192.168.3.1-254 in parallel (about 15s)...
 Phase 2/4: Collecting live devices + starting discovery...
 Phase 3/4: Probing ports, NetBIOS, DNS, HTTP on 9 devices...
 Phase 4/4: Resolving details (first run may query vendor DB)...

  [1] 192.168.3.1 (default gateway)
      MAC     : 74-30-AF-98-73-70
      Vendor  : Fiberhome Telecommunication Technologies Co.,LTD
      Type    : Device (open ports:80 443)
  ...

 Total devices found: 9
 Full results saved to: C:\tools\LAN_Scan_Results.txt
```

---

## Updating the vendor database

Double-click **`update_oui_db.cmd`**. It:

1. Downloads the latest IEEE registry (Wireshark's weekly `manuf` mirror,
   ~3 MB) using `curl.exe` or a PowerShell fallback.
2. Converts it to the scanner format (~40k entries) and validates the
   result — if the source format ever changes, the update aborts.
3. **Backs up the old database** as
   `oui_db.txt.YYYYMMDD_HHMMSS.bak` before installing the new one.
   Repeated updates stack separate timestamped backups; nothing is
   overwritten silently.
4. Clears `oui_cache.txt` so the scanner immediately uses fresh names.

Safety properties:

- Any failure (download too small, parse count too low, install error)
  leaves the existing database untouched and exits non-zero.
- The download URL is a single `URL=` variable at the top of the script;
  point it at an internal mirror if this PC has no internet.

---

## Requirements

- Windows 10 (1803+) or Windows 11 — uses the built-in `curl.exe`,
  Windows PowerShell 5.1 and standard networking tools.
- **No administrator rights** required.
- **Scanner**: fully offline. Firewalls may prompt once for the pings /
  probes; allowing them improves detection.
- **Updater**: needs internet access (only when you choose to run it).
- Network scope: `/24` subnets (the default for home and office LANs).

---

## Output files

| File | Written by | Contents |
|---|---|---|
| `LAN_Scan_Results.txt` | scanner | Full report in the same card format, with a timestamp header and device total. |
| `oui_cache.txt` | scanner | `OUI~Vendor` lines for MACs actually seen. Deleted and rebuilt by the updater. |
| `oui_db.txt.*.bak` | updater | Timestamped backups of previous vendor databases. Delete old ones at will. |

All output files are written next to the scripts.

---

## FAQ / Troubleshooting

**Why do some devices show `unknown` as vendor?**
The MAC's OUI prefix is not in the database (rare — it covers 40k+
prefixes) or the MAC is randomized. Update the database, or check the
prefix manually against the IEEE registry.

**Why do most devices have no `Name` line?**
Host names only appear if the device answers NetBIOS, mDNS, SSDP or
reverse DNS. Phones and many IoT gadgets answer none of these — the
vendor + type columns are the reliable identification for them.

**Why did a device disappear between runs?**
Devices that do not answer `ping` and were idle during the ARP sweep
(long sleep intervals, power-saving Wi-Fi) are invisible to ARP-based
discovery. Re-run the scan, or ping the device first.

**The scan shows only my own PC.**
You are probably on a different subnet than expected (guest Wi-Fi,
VPN adapter). Enter the correct prefix when prompted, or check
`ipconfig`.

**Windows Firewall prompted me — is that normal?**
Yes. The scanner sends broadcast/multicast packets (SSDP, mDNS) and
many pings. Allow it on private networks for best results.

**Can I scan a `/16` or a different subnet size?**
Not directly — the toolkit is optimized for `/24`, which covers almost
all home and office networks. Run it once per `/24` prefix instead.

**The updater says "Download failed or file too small".**
No internet, TLS interception, or a proxy blocking `wireshark.org`.
Fix connectivity or edit `URL=` at the top of `update_oui_db.cmd` to
another mirror of the Wireshark `manuf` file.

---

## Responsible use

Scan only networks you own or are explicitly authorized to test
(your home, your lab, a client who hired you). Port probing and
discovery queries are passive-by-design but still constitute network
scanning; using the toolkit on third-party networks without permission
may be illegal in your jurisdiction.

---

## Technical notes

- Both `.cmd` files require **CRLF line endings** (the batch parser
  mishandles `call :label` inside blocks otherwise). They ship as CRLF;
  if you edit them on Linux, re-normalize before use.
- `update_oui_db.cmd` embeds its PowerShell conversion engine as plain
  text between `rem PS_BEGIN_MARKER` / `rem PS_END_MARKER` at the bottom
  of the file, below `exit /b`. cmd never parses it; the launcher
  extracts it at runtime and passes paths via environment variables.
  This avoids the classic `echo`-generated-PowerShell escaping traps.
- The scanner's per-device probes are parallel PowerShell processes,
  synchronized via `DONE`-marked temp files (`%TEMP%\dsh_probe_*.txt`),
  so a hung probe delays the report by at most ~36 seconds.
- Device type inference is heuristic; a device can legitimately match
  several profiles (e.g. a NAS with SMB and a web UI). The most specific
  signature found is reported.
