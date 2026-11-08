# 局域网设备扫描工具集(LAN Device Scanner Pro)

> [English](README.md) | 中文

一套 100% 离线运行的 Windows 局域网设备发现工具。双击一个 `.cmd` 文件,
即可列出本地 `/24` 网段内的所有设备:IP 地址、MAC 地址、**IEEE 注册完整
厂商全名**、设备类型,以及(设备愿意自报家门时的)主机名。

无需安装、无需管理员权限、扫描过程完全不需要联网。

---

## 目录

- [工具集文件清单](#工具集文件清单)
- [快速上手](#快速上手)
- [输出内容说明](#输出内容说明)
- [工作原理](#工作原理)
- [五层识别机制](#五层识别机制)
- [实际输出示例](#实际输出示例)
- [更新厂商数据库](#更新厂商数据库)
- [运行环境要求](#运行环境要求)
- [生成的文件](#生成的文件)
- [常见问题与排障](#常见问题与排障)
- [合法使用声明](#合法使用声明)
- [技术细节](#技术细节)

---

## 工具集文件清单

| 文件 | 大小 | 用途 |
|---|---|---|
| `lan_scanner.cmd` | 约 12 KB | 扫描主脚本,**双击运行**。 |
| `lan_scanner.ps1` | 约 7.5 KB | 探测引擎(端口 / NetBIOS / DNS / HTTP / SSDP / mDNS),必须与主脚本同目录。 |
| `oui_db.txt` | 约 1.7 MB | 离线厂商数据库:40,207 个 OUI 前缀及 IEEE 注册完整厂商名。 |
| `update_oui_db.cmd` | 约 6 KB | 厂商库更新器,**双击运行**即可更新 `oui_db.txt`。 |
| `oui_cache.txt` | (自动生成) | 扫描器写入的查询缓存,加速后续运行;可随时删除。 |
| `LAN_Scan_Results.txt` | (自动生成) | 扫描报告,与控制台输出相同的卡片格式。 |

> **务必将 `lan_scanner.cmd`、`lan_scanner.ps1`、`oui_db.txt` 三个文件
> 放在同一目录**,这是唯一的布局要求。

---

## 快速上手

1. 将工具集的四个文件放入同一文件夹。
2. 让电脑接入要检查的局域网(Wi-Fi 或有线均可)。
3. 双击 **`lan_scanner.cmd`**。
4. 直接**回车**确认自动检测到的网段前缀,或输入其他前缀(如 `10.0.1`)
   后回车。
5. 等待约 40 秒。结果以设备卡片形式显示,并自动保存到
   `LAN_Scan_Results.txt`。

以后想刷新厂商数据库时(一年一两次足够),双击
**`update_oui_db.cmd`**,详见[更新厂商数据库](#更新厂商数据库)。

---

## 输出内容说明

每台发现的设备输出一张卡片:

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

- 只有真正解析到主机名(SSDP / mDNS / NetBIOS / 反向 DNS)时才会出现
  `Name` 行。
- 厂商名为 IEEE 注册表中的完整法律名称——单行完整显示,永不截断。

---

## 工作原理

四个阶段,全部基于 Windows 内置工具
(`ping`、`arp`、`route`、`nbtstat`、`ipconfig`)加一个随附的
PowerShell 探测引擎:

| 阶段 | 做什么 | 耗时 |
|---|---|---|
| 1 | 自动检测本机 IPv4 地址与 `/24` 网段;并行 ping 全部 254 个地址以填充 ARP 缓存 | 约 15 秒 |
| 2 | 读取 ARP 缓存,收集存活设备的 IP + MAC 对(过滤广播与无效 MAC),确保本机也在列 | 约 1 秒 |
| 3 | 并行执行:全网 SSDP + mDNS 发现;每台设备单独探测——14 个 TCP 端口、NetBIOS 名、反向 DNS、HTTP `Server` 头与页面 `<title>` | 约 10-25 秒 |
| 4 | 查询每块网卡的厂商(缓存 → 离线数据库),综合所有信号推断设备类型,打印卡片 | 约 1-2 秒 |

### 端口 → 设备类型映射

| 开放端口 | 推断类型 |
|---|---|
| 9100 | 打印机(JetDirect) |
| 554 | 网络摄像头 / 录像机(RTSP) |
| 5555 | 安卓设备(ADB 调试) |
| 8009 | Chromecast / 安卓电视 |
| 32400 | 媒体服务器(Plex) |
| 5000 | NAS / 网页服务(群晖风格) |
| 3389 | Windows 电脑(远程桌面) |
| 445 | Windows / Samba 主机(SMB 共享) |
| 5357 | Windows 设备(WSD) |
| 22 | Linux / SSH 主机 |
| 80/443/8080/… | Web 管理页指纹(HTTP 标题 + 服务器头) |

最具体的信号优先;其余情况回退为 `Device (open ports:…)`。

---

## 五层识别机制

1. **MAC 厂商(离线)** —— 取 MAC 前缀(`AA-BB-CC`)在 `oui_db.txt`
   中查询,该库收录 40,207 个 24 位前缀的 IEEE 注册完整厂商名。
   近期查询结果缓存在 `oui_cache.txt`。**全程不联网。**
2. **随机 MAC 检测** —— 若首字节第二个十六进制位为
   `2/3/6/7/A/B/E/F`,该 MAC 很可能是手机的"隐私 Wi-Fi 地址";
   卡片显示 `(randomized MAC)`,设备类型标注为移动 / IoT 设备。
3. **TCP 端口指纹** —— 并行探测 14 个常用端口
   (22, 80, 443, 445, 554, 3389, 5000, 5357, 5555, 8009, 8080,
   8443, 9100, 32400),每个端口 250 毫秒超时。
4. **名称解析** —— 按以下顺序尝试,取第一个命中:
   SSDP 友好名称 → mDNS 实例名 → NetBIOS(`nbtstat`)
   → 反向 DNS(PTR)→ 本机显示 `%COMPUTERNAME%`。
5. **发现协议** —— 端口探测进行的同时,全网发送 SSDP `M-SEARCH`
   (UPnP:路由器、电视、NAS、打印机)和 mDNS 查询
   (Chromecast、AirPlay、打印机、HomeKit、安卓电视),
   应答提供友好名称和型号字符串。

---

## 实际输出示例

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
  ...(共 9 台设备)

 Total devices found: 9
 Full results saved to: C:\tools\LAN_Scan_Results.txt
```

---

## 更新厂商数据库

双击 **`update_oui_db.cmd`**,它会:

1. 下载最新 IEEE 注册数据(Wireshark 每周同步的 `manuf` 镜像,
   约 3 MB),优先使用 `curl.exe`,缺失时回退 PowerShell 下载。
2. 转换为扫描器格式(约 4 万条)并校验结果——若源格式发生变化,
   更新即中止。
3. **备份旧数据库**为 `oui_db.txt.YYYYMMDD_HHMMSS.bak` 后安装新库。
   重复更新会生成各自独立的时间戳备份,绝不静默覆盖。
4. 清空 `oui_cache.txt`,让扫描器立即使用最新厂商名。

安全保护:

- 任何一步失败(下载文件过小、解析条数过少、安装出错)都会保留
  现有数据库不变,并以非零退出码结束。
- 下载地址是脚本顶部的单个 `URL=` 变量;本机无法联网时,可改为
  内网镜像地址。

---

## 运行环境要求

- Windows 10(1803 版及以上)或 Windows 11——使用系统内置的
  `curl.exe`、Windows PowerShell 5.1 和标准网络工具。
- **无需管理员权限。**
- **扫描器**:完全离线。防火墙可能针对 ping / 探测弹窗询问一次,
  放行后检测效果更好。
- **更新器**:仅在你选择运行它时需要联网。
- 网络范围:`/24` 网段(家庭与办公网的标准规模)。

---

## 生成的文件

| 文件 | 产生方 | 内容 |
|---|---|---|
| `LAN_Scan_Results.txt` | 扫描器 | 完整报告,与控制台相同的卡片格式,带时间戳头部和设备总数。 |
| `oui_cache.txt` | 扫描器 | 实际遇到过的 MAC 对应的 `OUI~厂商` 行。更新器会将其删除重建。 |
| `oui_db.txt.*.bak` | 更新器 | 历届厂商数据库的时间戳备份,可随意删除旧备份。 |

所有输出文件都写在脚本所在目录。

---

## 常见问题与排障

**为什么有些设备厂商显示 `unknown`?**
该 MAC 的 OUI 前缀不在数据库中(库已收录 4 万余条,属罕见情况),
或该 MAC 是随机化的。先运行更新器刷新数据库,或到 IEEE 注册表
人工核对前缀。

**为什么大多数设备没有 `Name` 行?**
主机名只在设备应答 NetBIOS、mDNS、SSDP 或反向 DNS 时才能取得。
手机和许多 IoT 设备这些一概不应答——对它们而言,厂商 + 类型
两列才是可靠的识别依据。

**为什么设备在某次运行中消失了?**
不应答 ping 且在 ARP 扫描期间恰好处于空闲(长休眠、Wi-Fi 省电)
的设备,对基于 ARP 的发现是不可见的。重新扫描,或先手动 ping
该设备再扫。

**扫描结果只有我自己的电脑。**
你可能接在别的网段(访客 Wi-Fi、VPN 虚拟网卡)。在提示时输入正确
的前缀,或先用 `ipconfig` 确认。

**Windows 防火墙弹窗了,正常吗?**
正常。扫描器会发送广播 / 组播包(SSDP、mDNS)和大量 ping,
在专用网络上放行即可获得最佳效果。

**能扫描 `/16` 或其他规模的网段吗?**
不能直接支持——工具针对 `/24` 优化,这覆盖了几乎所有家庭和办公
网络。如有需要,对每个 `/24` 前缀分别运行一次。

**更新器提示 "Download failed or file too small"。**
没有联网、TLS 被拦截,或代理屏蔽了 `wireshark.org`。恢复联网后
重试,或编辑 `update_oui_db.cmd` 顶部的 `URL=` 变量,改为另一个
Wireshark `manuf` 文件镜像。

---

## 合法使用声明

仅扫描你拥有所有权或已获得明确授权的网络(自家网络、自己的实验
环境、委托你测试的客户)。端口探测与发现查询虽然设计上保持克制,
但仍属于网络扫描行为;未经许可对第三方网络使用本工具集,在多数
司法辖区可能构成违法。

---

## 技术细节

- 两个 `.cmd` 文件必须保持 **CRLF 换行**(否则批处理解析器对代码块
  内的 `call :label` 会出错)。文件出厂即为 CRLF;若在 Linux 下编辑,
  使用前请重新规范换行。
- `update_oui_db.cmd` 的 PowerShell 转换引擎以纯文本形式内嵌在文件
  尾部 `rem PS_BEGIN_MARKER` / `rem PS_END_MARKER` 之间、位于
  `exit /b` 之后——cmd 永不解析该段;启动器在运行时提取该段执行,
  并通过环境变量传递路径。这避开了用 `echo` 逐行生成 PowerShell
  代码的经典转义陷阱。
- 扫描器的每设备探测是并行的 PowerShell 进程,通过带 `DONE` 标记的
  临时文件(`%TEMP%\dsh_probe_*.txt`)同步;单个探测卡死最多让报告
  延迟约 36 秒。
- 设备类型推断是启发式的;一台设备完全可能同时命中多个特征
  (如同时开放 SMB 与网页服务的 NAS)。报告显示找到的最具体特征。
