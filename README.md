# ARPradar

(Formerly ARPspy. The code folders, Xcode scheme and data folder are still called `ArpSpy`.)

A native Mac network scanner in the spirit of Advanced IP Scanner. It finds devices on your network and lists their name, IP, manufacturer and MAC address. Results stay on your Mac.

**Version 1.0.0.** Download it from [arpradar.com](https://arpradar.com). The Windows version is in [arpradar-windows](https://github.com/saoneill01-a11y/arpradar-windows).

Built by a network engineer with [Claude Code](https://claude.com/claude-code).

## What it does

- **Scan:** type a range (`192.168.1.1-254`, `10.0.0.0/24`, several separated by commas) or pick a network from the list.
- **Find devices in three ways:**
  1. ping sweep
  2. a quick knock on common ports (SMB, HTTP, HTTPS, SSH, RDP) for devices that ignore ping
  3. the Mac's ARP table, which catches quiet devices on the local subnet
- **Name lookup:** Windows names (NetBIOS) first, then reverse DNS.
- **Manufacturer:** comes from the MAC address, using the IEEE list in `ArpSpy/Resources/oui.csv`. Phones using private Wi-Fi addresses show "Private address".
- **Comments:** type a note in the Comments column. It's remembered per MAC address.
- **Open ports:** each device gets tags for common ports (SSH, HTTP/HTTPS, SMB, RDP, VNC, printer and more).
- **Right-click actions:** open in browser, open shares in Finder, SSH in Terminal, Remote Desktop (needs Microsoft's free Windows App), Screen Sharing, Wake-on-LAN, and copy IP, MAC or the row.
- **Favorites:** click the ☆ to pin a device. The Favorites tab shows whether each one is online in the latest scan.
- **History:** every finished scan is saved (last 50) in the History tab. A device seen before in the same range that's missing now shows up grey as **offline**. "Forget Offline" clears those rows.
- **Sharing results:** sortable columns, search, Copy all, and Export CSV.
- **Data stays on this Mac:** everything is saved in `~/Library/Application Support/ArpSpy/data.json`.
- **No admin rights needed** and no app sandbox.

## Build it

You need Xcode (free from the App Store) and Homebrew.

```sh
brew install xcodegen
cd arpspy
xcodegen            # creates ArpSpy.xcodeproj
open ArpSpy.xcodeproj
```

Then press **⌘R** to build and run, or **⌘U** to run the tests.

Or do it all in one step from Terminal: `scripts/build.sh` (runs the tests, builds, installs ARPradar in Applications and opens it).

The first launch asks: *"Allow ARPradar to find devices on local networks?"* Click **Allow**. If you miss it, go to System Settings › Privacy & Security › Local Network.

## Project layout

| Folder | What's in it |
|---|---|
| `ArpSpy/App` | App entry point |
| `ArpSpy/Views` | The window: top bar, results table, status bar |
| `ArpSpy/Model` | IP range parsing, the device list, Scan/Stop logic, CSV export |
| `ArpSpy/Scan` | Network code: ping, port knock, ARP table, names, vendor lookup, network interfaces |
| `ArpSpyTests` | Tests for the range parser, ARP parsing, CSV and more |
| `scripts/update-oui.sh` | Refreshes the manufacturer list |

## License

ARPradar is free software under the [GNU General Public License v3.0 or later](LICENSE.txt). Copyright (C) 2026 Sean O'Neill.

ARPradar sends traffic to the devices it scans. Use it only on networks you own or have permission to scan.
