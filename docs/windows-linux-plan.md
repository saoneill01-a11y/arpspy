# ARPradar for Windows and Linux: plan

Written 2026-11-06. **Not started.** Windows comes first (Sean sometimes has to use it); Linux is a bonus.

## The short version

- The Mac app stays as it is: native SwiftUI.
- Windows and Linux get **one shared app** built with **Tauri 2**. That's a Rust engine for the network work, with the window drawn as a web page. One codebase builds a Windows `.exe` installer and Linux `.deb` / AppImage packages.
- It looks and works like the Mac version: the same main window, sites, details panel, Tools and remote wake. Saved sites use the same file format, so client sites can move between the Mac and a Windows PC.
- It's about as much work again as the Mac version: roughly **8–10 evening sessions** like the ones we've had, plus testing on a real Windows PC.

## Why Tauri (Rust + web page)

| Option | For | Against |
|---|---|---|
| **Tauri 2 (Rust)** ✅ | Small app (~10 MB), no runtime to install, Rust is good at raw sockets, one codebase for Windows + Linux, uses Windows' own browser engine | A new language in the project |
| .NET + Avalonia | Very good on Windows | Bigger download, weaker on Linux networking |
| Electron | Easy UI | 150 MB+ app, slow and heavy |
| Swift on Windows | Reuse Swift code | No SwiftUI there, so the whole UI is rewritten anyway |
| Qt (C++/Python) | Mature | Harder to keep tidy; licensing questions |

## What carries over, and what changes per system

Most of the network code ports almost line for line, because it uses plain UDP/TCP: TCP port knocks, NetBIOS, Bonjour/mDNS, UPnP/SSDP, SNMP, DNS PTR to a site's name server, web page titles, service banners and Wake-on-LAN. The vendor list (`oui.csv`) is bundled as it is.

The parts that need their own code on each system:

| Feature | Windows (no admin rights) | Linux |
|---|---|---|
| Ping sweep, response times | `IcmpSendEcho2` (built into Windows, no admin) | ICMP "ping" sockets (allowed by default on Ubuntu/Fedora; else fall back to the `ping` command) |
| MAC addresses | `SendARP` + `GetIpNetTable2` (SendARP can ask any LAN IP for its MAC) | `/proc/net/arp`, `ip neigh` |
| IPv6 addresses | `GetIpNetTable2` (IPv6) | `ip -6 neigh` |
| Network list | `GetAdaptersAddresses` | `getifaddrs` |
| Shares | `NetShareEnum`: uses your Windows login, so it **can list shares on domain PCs**, which the Mac can't | `smbclient -L` if installed; `showmount` for NFS |
| Open in browser / Finder / SSH / RDP / VNC | browser, Explorer `\\ip`, Windows Terminal + `ssh`, `mstsc /v:ip`, VNC viewer if installed | browser, file manager `smb://`, terminal + `ssh`, Remmina/xfreerdp, VNC viewer if installed |
| Wi-Fi Signal / Analyzer | Native Wi-Fi API (`WlanGetNetworkBssList`). Windows 11 also hides network names without Location permission | NetworkManager (`nmcli`) or `iw` |
| Connection Info | `GetAdaptersAddresses` (includes DHCP server and lease times) | NetworkManager / lease files |
| Renew DHCP | `ipconfig /renew` (may show a Windows admin prompt) | `nmcli` (may ask for a password) |
| Traceroute | `IcmpSendEcho2` with rising TTL | UDP probes, or `traceroute` / `tracepath` |
| DNS Lookup | Built-in DNS library (no `dig` on Windows); same "All" list | same library |
| Speed Test | Apple's test isn't available. Use Cloudflare's speed test servers (download/upload/latency) | same |
| Excel export | `rust_xlsxwriter` | same |
| Notifications | Tauri notification plugin | same |
| Radar icon | the same drawing, as an animated SVG | same |

## Steps

Each step ends with something usable, so it can pause anywhere.

1. **Set up** (½ session): new private repo `saoneill01-a11y/arpspy-win` (name to confirm), Tauri skeleton, GitHub Actions building the Windows installer and Linux packages, the same CLAUDE.md rules as the Mac repo.
2. **Scanner** (2 sessions): ping, port knocks, MAC addresses, vendors, names, open ports; the main table with frozen columns, red offline rows, Show offline switch, search, favorites, history; sites (Site menu, Site List); CSV/Excel export. → A working Windows scanner.
3. **Device details** (1–2 sessions): web titles, UPnP, SNMP, IPv6, shares, banners, the details panel, Scan Ports, right-click actions.
4. **Tools** (2 sessions): Ping, Traceroute, DNS Lookup, Connection Info, Wi-Fi Signal and Analyzer, Speed Test, Subnet Calculator.
5. **Remote wake, settings, polish** (1 session): Wake Remote PC, appearance switch, NEW-device notifications, installer.
6. **Linux** (1–2 sessions): the per-system pieces in the table above, then `.deb` and AppImage packages.
7. **Share sites between Mac and Windows** (½ session, also changes the Mac app): Export/Import Sites in both apps. Optionally keep the sites file in OneDrive so both see the same list.

## Decisions for Sean before starting

- ✅ **Code signing for Windows:** no certificate for now (decided 2026-11-06). Windows SmartScreen will warn the first few times (More info › Run anyway). Revisit if a client PC blocks unsigned apps.
- ✅ **A Windows machine to test on:** Sean's Windows laptop (decided 2026-11-06). It has Wi-Fi, so the Wi-Fi tools can be tested too. Builds come from GitHub Actions as an installer to download and run on it.
- **A Linux VM** on Unraid for step 6 (free).
- **GitHub Actions minutes:** the repo is private, and Windows build minutes count double against the free 2,000 a month. One build is about 10 minutes, so this should fit; I'd check usage after the first week.
- **Repo name** and whether it shares the ARPradar icon (suggested: yes).

## Risks

- Windows antivirus/EDR on client PCs may flag a fast ping and port sweep. Scans can be slowed down per site if needed.
- Some client PCs block unsigned apps entirely (company policy). That's where the signing certificate would matter.
- Linux distributions differ (NetworkManager vs others, ping socket settings); support Ubuntu/Debian and Fedora first.
