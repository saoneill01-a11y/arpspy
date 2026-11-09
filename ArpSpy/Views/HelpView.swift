import SwiftUI

/// One step in a help topic. `advanced` marks a step that needs Advanced mode.
struct HelpStep: Hashable {
    let text: String
    var advanced = false
}

/// A help topic: a title, one line of what it's for, and a few short steps.
/// Step text uses **bold** for menu items and buttons and `code` for things to type.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
    let lead: String
    /// The whole topic needs Advanced mode.
    var advancedOnly = false
    let steps: [HelpStep]

    var needsAdvanced: Bool { advancedOnly || steps.contains { $0.advanced } }

    /// Everything a search looks at, without the ** and ` marks.
    var searchText: String {
        ([title, lead] + steps.map(\.text)).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
    }

    /// Topics containing every word typed (any case). An empty search gives them all.
    static func matching(_ query: String) -> [HelpTopic] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return all }
        return all.filter { t in words.allSatisfy { t.searchText.localizedStandardContains($0) } }
    }

    static let all: [HelpTopic] = [
        HelpTopic(id: "start", title: "Getting started", symbol: "play.circle",
                  lead: "Find everything on a network in about ten seconds.",
                  steps: [
                    HelpStep(text: "Pick the **Network adapter** at the top (Wi-Fi, Ethernet, USB or VPN). ARPradar fills in the **IP range** for its subnet. In Basic, it uses the network this Mac is on.", advanced: true),
                    HelpStep(text: "To scan a different subnet, type it in the **IP range** box: `192.168.1.1-254`, `10.0.0.0/24`, or several separated by commas. Press Return or **Scan**."),
                    HelpStep(text: "Click **Scan** (⌘Return). Click **Stop** to end early. Once a scan has run, the button says **Rescan** (⌘R); type a different range and it says **Scan** again. Typing a different range while a saved scan is open scans it as a new, unsaved scan, so the saved one isn’t changed."),
                    HelpStep(text: "Columns: **Status**, **Name**, **Type** (printer, switch, camera, TV…: a best guess from the name, maker, model and open ports), **IP**, **Description** (what the device says it is), **Manufacturer** (from the MAC address), **MAC address**, **Open ports**, **Response** (ping time, hidden at first) and **Comments**. Right-click a column header to show or hide columns. **View › Type Column** turns the Type column on or off (on at first). **View › Switch Port Column** (off at first) shows where each device plugs in: the UniFi switch and port, or the access point for Wi-Fi; it needs a UniFi controller (see the Map topic). Both are also in **Settings › General**."),
                    HelpStep(text: "Green dot: the device answered this scan. **Red dot**: seen before, but not found this time. **NEW**: the first time this saved scan has seen it. A new, unsaved scan remembers nothing, so it has no red dots or NEW badges; to compare with last time, pick it from **Saved Scans** and click **Rescan**."),
                    HelpStep(text: "The **Show offline** switch in the bottom bar hides the red rows. **Forget Offline** removes them all for good; right-click one red row › **Forget This Device** removes just that one (favorites are kept either way)."),
                    HelpStep(text: "The **Search** box (⌘F) filters by name, IP, MAC, manufacturer or port. While it hides rows, the bottom bar says how many; **Show all** clears it. It clears itself when you start a new scan or open another saved scan."),
                    HelpStep(text: "Double-click a row to open the details panel. Drag the thin line after the **Type** column to make the frozen part (star, status, name, type) wider or narrower. A **Response** time over 200 ms is orange."),
                    HelpStep(text: "After a scan, the network’s **DHCP server** and **name servers** get a label next to their name, and the bottom bar lists them. The DHCP server comes from this Mac’s DHCP lease, so it only shows when you’re on that network (not over a VPN). Name servers are the DNS servers the lease hands out; over a VPN, devices with the DNS port (53) open (not Apple TVs or HomePods, which answer DNS for smart-home gear)."),
                    HelpStep(text: "**File › Open Recent** lists the last 5 scans. A saved scan opens as itself; an unsaved one comes back as a new scan you can still save. **Clear Menu** empties the list (History keeps everything)."),
                  ]),
        HelpTopic(id: "sites", title: "Saved scans", symbol: "tray.full",
                  lead: "Save a network once and scan it again any time. Each saved scan keeps its own devices, so two clients on the same subnet never mix.",
                  steps: [
                    HelpStep(text: "ARPradar always opens as a new scan of this Mac’s network. **New Scan** (next to Scan, or ⌘N) starts over the same way; type another subnet in **IP range** if you like. Then click **Scan**."),
                    HelpStep(text: "When it finishes, a bar asks **Save this scan?** Choose **Save to Organization…**, **Save Standalone…** or **Not Now**. You can also use **File › Save Scan…** (⌘S) later."),
                    HelpStep(text: "**Save to Organization…**: pick the organization (or **New Organization…**) and give the scan a name, like “Main office”. It uses the organization’s name server and DHCP range. **Save Standalone…** is for a scan that doesn’t belong to anyone; it keeps its own."),
                    HelpStep(text: "The **Saved Scans** menu lists saved scans under each organization, then **Standalone**. Pick one to see its devices, then click **Rescan** to scan that network again and update it."),
                    HelpStep(text: "**Edit This Scan…** changes the name, range and organization (and, for a standalone scan, its name server and DHCP range). **Delete This Scan…** removes it. **Organizations…** opens the organizations window, where each organization’s **Settings** hold its domains, name server and DHCP range."),
                    HelpStep(text: "After a scan in an organization, a blue bar offers to use a name server it found if the organization has none (or a different one). The organization’s **Settings** also show what the last scan found."),
                    HelpStep(text: "**Name server**: that network’s DNS server (a domain controller, Pi-hole or router, e.g. `10.0.0.5`). ARPradar asks it for device names. Handy over a VPN."),
                    HelpStep(text: "**SNMP community**: the read-only community that network’s switches, printers and UPSes answer to. It belongs to the organization (or the standalone scan), so it is only ever sent on that network; a new, unsaved scan sends `public`.", advanced: true),
                    HelpStep(text: "**DHCP range**: the DHCP server’s pool, e.g. `10.0.0.100-10.0.0.199` (several allowed, separated by commas). Turn on **Mark outside DHCP** in the bottom bar and addresses outside the pool turn purple, so fixed addresses stand out.", advanced: true),
                    HelpStep(text: "**Saved Scans › Edit Scan List…** (⌥⌘S) shows every saved scan in one table: edit them, move them to an organization, **Duplicate**, **Clear Devices**, or delete several at once."),
                    HelpStep(text: "To move saved scans to another Mac or to ARPradar for Windows: **File › Export Scans…**, tick the scans and save the .arpradar file. On the other computer, **File › Import Scans…** and pick the file. A scan that already exists there can be replaced or kept alongside (it gets a number after its name). Favorites, comments and History stay on each computer."),
                  ]),
        HelpTopic(id: "device", title: "Device details and right-click", symbol: "info.circle",
                  lead: "Everything you can do with one device.",
                  steps: [
                    HelpStep(text: "Select a device and press ⌘I (or the ⓘ button) for the details panel: names, MAC, IPv6, shares, model and open ports."),
                    HelpStep(text: "Right-click a device for **Open in Browser** and **Open Shares in Finder**."),
                    HelpStep(text: "**SSH in Terminal**, **Remote Desktop (RDP)** (opens Windows App) and **Screen Sharing (VNC)**.", advanced: true),
                    HelpStep(text: "**Scan Ports…** opens in its own window and checks the common ports, all 65535, or a list like `1-1024`. You can keep using the main window while it runs.", advanced: true),
                    HelpStep(text: "The details panel ends with **Actions**: Open in Browser, Shares, SSH, RDP, Scan Ports, Ping, Wake, Copy IP, Copy MAC and Copy All."),
                    HelpStep(text: "**Ping** opens the Ping tool with the address filled in. **Traceroute** and **DNS Lookup** do the same in Advanced."),
                    HelpStep(text: "**Wake on LAN** wakes a sleeping device on this network."),
                    HelpStep(text: "**Save for Remote Wake…** adds the device to **File › Wake Remote PC…** (⇧⌘W), to wake it later over a VPN. ARPradar then checks for 2 minutes whether it woke up.", advanced: true),
                    HelpStep(text: "Click the ☆ (or right-click › **Add to Favorites**) to keep a device in the **Favorites** tab."),
                    HelpStep(text: "Click the **Comments** cell and type a note. It’s saved with the device."),
                    HelpStep(text: "Wrong type? Right-click › **Type** and pick the right one. **Automatic** goes back to the guess."),
                  ]),
        HelpTopic(id: "map", title: "Network map (UniFi and SNMP)", symbol: "point.3.connected.trianglepath.dotted",
                  lead: "See how switches and access points are connected, and what’s on each port and access point.",
                  advancedOnly: true,
                  steps: [
                    HelpStep(text: "After a scan, click **Map** (its own button next to Results, Favorites and History). The gateway is at the top, then switches and access points (purple border), each with its wired and Wi-Fi clients. Click a box to see its ports and clients on the right. Click the **12 wired · 3 Wi-Fi** label under a box to list its clients and the port each one is on."),
                    HelpStep(text: "Pinch on the trackpad to zoom, or use the magnifying glasses. **Fit** shows the whole width, and you can’t zoom out further than that. **Full | Compact** switches between full tiles and small ones that show just the name (cut short if needed) and IP address."),
                    HelpStep(text: "For the real cabling, connect the **UniFi controller** (Cloud Key, UDM, Cloud Gateway or a self-hosted Network app): click **Connect UniFi…**, enter its address and an API key. Make the key in UniFi Network under **Settings › Control Plane › Integrations › Create API Key**. ARPradar only reads; it never changes anything."),
                    HelpStep(text: "The key is kept in this Mac’s Keychain, never in ARPradar’s files or exports. After an update macOS may ask once whether ARPradar can use it: click **Always Allow**."),
                    HelpStep(text: "ARPradar remembers the controller’s certificate the first time it connects and refuses to talk to it if the certificate changes later (that is what a man-in-the-middle looks like). If you replaced the controller or its certificate on purpose, choose **Forget Certificate** in the controller’s settings and connect again."),
                    HelpStep(text: "In an organization, the controller goes in its **Settings** (UniFi row) and every scan in it uses it. For other scans, a controller is used when its address is inside the scanned range."),
                    HelpStep(text: "Labels on the lines: **P1 ⇄ P8 · 1G** means port 1 on the switch above, port 8 on this one, at 1 Gb. Line colours show the speed: **blue** 10 Gb, **light blue** 2.5 or 5 Gb, **green** 1 Gb, **orange** 100 Mb or less (on a switch or access point, usually a bad cable or jack). **Dashed** lines are wireless (mesh), or every line when there is no controller."),
                    HelpStep(text: "**Unmanaged switch?** appears when several devices share one switch port and none of them is UniFi: a small unmanaged switch, or a computer running virtual machines."),
                    HelpStep(text: "**Other brands** (Cisco, Aruba/HP, Netgear, TP-Link, Juniper and most managed switches): turn on SNMP (v2c, read-only) on the switches and put the same community in the organization’s **Settings** (or the standalone scan). ARPradar reads each switch’s MAC address table and LLDP neighbours, works out which switch plugs into which, and puts every device on its switch and port. This mixes with a UniFi controller on the same map. **Details** in the map’s top bar shows what each switch answered."),
                    HelpStep(text: "A switch’s uplink is the port where it sees the gateway; a device goes on the port where it was seen with the fewest others. When the gateway is a layer-3 core switch, it sits at the top of the map with its ports. Cisco switches keep a MAC table per VLAN; ARPradar reads each one (up to 64 VLANs) with the same community."),
                    HelpStep(text: "With no controller and no SNMP switches, the map lists the Ubiquiti devices the scan found, under the gateway, with no cabling. Ubiquiti cameras, consoles and airMAX radios tell ARPradar their name, model and firmware; adopted UniFi switches and access points don’t."),
                    HelpStep(text: "**Export…** saves the map as PNG or PDF, or every switch port as an Excel sheet. The map is saved with the scan, so History and Open Recent show it again."),
                  ]),
        HelpTopic(id: "orgs", title: "Organizations and site survey", symbol: "briefcase",
                  lead: "Keep each client’s saved scans and test results together.",
                  advancedOnly: true,
                  steps: [
                    HelpStep(text: "**File › New Organization…** (⇧⌘N): a name, domain names, notes and a first scan."),
                    HelpStep(text: "**Save and Run Survey** runs Connection Info, Wi-Fi, a network scan, a speed test, DNS lookups and an expiry check for each domain, and a traceroute to 1.1.1.1. It takes about a minute. Untick any you don’t need."),
                    HelpStep(text: "**File › Organizations…** (⌘K) lists everything saved, newest first. Double-click to open; right-click to edit a note. **Run Survey…** runs another one."),
                    HelpStep(text: "Every time you scan one of its saved scans, the results are added to the organization automatically."),
                    HelpStep(text: "In an organization, start new work right there: **Scans › New Network Scan**, **DNS › New DNS Lookup** (it looks up the organization’s domain), **Ports › New Port Scan**, or **Other › New…** (Ping, Traceroute, Speed Test, Connection Info, Wi-Fi Analyzer)."),
                    HelpStep(text: "Anything started from an organization is saved there automatically when it finishes (its button says **Saves to …**, then **Saved to … ✓**). Delete what you don’t want from the organization’s list. Ping and Wi-Fi keep running, so save those with their **Save to Organization** button."),
                    HelpStep(text: "Every tool has a **Save to Organization** button."),
                    HelpStep(text: "**Export Organization (Excel)…** makes one workbook: an overview sheet plus a sheet for each saved result."),
                  ]),
        HelpTopic(id: "tools", title: "Tools", symbol: "wrench.and.screwdriver",
                  lead: "The Tools menu. Right-click a device to open some of them with its address filled in.",
                  steps: [
                    HelpStep(text: "**Ping** (⌘1): several addresses at once, with a live chart."),
                    HelpStep(text: "**Traceroute** (⌘2) shows each hop to an address.", advanced: true),
                    HelpStep(text: "Type a domain or paste a web address once in the box at the top of **DNS Lookup** and click **Check all**: Look Up, Email Check, Compare Servers and Expiry all run for it. Each tab shows a check mark when done, or an orange mark when something is worth a look. An IP address only runs Look Up (its name).", advanced: true),
                    HelpStep(text: "DNS Lookup’s other tabs: **Email Check** (SPF with its lookup count, DMARC, DKIM, MX, MTA-STS, TLS reports, DNSSEC, each with a plain-English verdict), **Compare Servers** (the same question to several servers, including the domain’s own, to spot differences), **Expiry** (domain registration and the HTTPS certificates on its usual hosts) and **Reverse Subnet** (the name of every address in a range). **Find subdomains** (with All) adds every name the domain has had an HTTPS certificate for.", advanced: true),
                    HelpStep(text: "**DNS Lookup** (⌘3). **All** checks the usual records and about 100 common names (MX, SPF, DMARC, autodiscover, portal, sso, SRV…) in one go. **Follow CNAMEs to other domains** also shows where they lead. Pick any server, or a saved scan’s name server. **Download…** writes CSV or Excel. **Save to Organization** keeps where CNAMEs lead too, so an opened saved lookup has the same **Follow CNAMEs** switch.", advanced: true),
                    HelpStep(text: "**Wi-Fi Signal** (⌘4): signal, noise and channel. Network names need the Location permission: click **Allow…**."),
                    HelpStep(text: "**Wi-Fi Analyzer** (⌘5): nearby networks and how their channels overlap.", advanced: true),
                    HelpStep(text: "**Connection Info** (⌘6): DHCP server, DNS, gateway and **Renew DHCP Lease…** (asks for your Mac password). Your public IP is looked up only when you click **Look Up**."),
                    HelpStep(text: "**Speed Test** (⌘7) uses the Mac’s own speed test and keeps a history."),
                    HelpStep(text: "**Subnet Calculator** (⌘8): type an address and mask; **Scan This Range** sends it to the main window.", advanced: true),
                  ]),
        HelpTopic(id: "export", title: "History and exporting", symbol: "square.and.arrow.up",
                  lead: "Look back at old scans and take the list with you.",
                  steps: [
                    HelpStep(text: "The **History** tab keeps every scan. Pick one to look at it; go back to **Results** (or click **Open in Results**) and it stays there, so you can rescan it or export it. Right-click one › **Delete This Scan…**, or **Clear History…**; both ask first.", advanced: true),
                    HelpStep(text: "**File › Export as CSV…** (⌘E) or **Export as Excel (.xlsx)…** (⇧⌘E). Both are also under **Export…** in the bottom bar."),
                    HelpStep(text: "**Copy** in the bottom bar copies the whole list, ready to paste into Excel.", advanced: true),
                    HelpStep(text: "Right-click a device for **Copy IP**, **Copy MAC** or **Copy Row**."),
                  ]),
        HelpTopic(id: "menubar", title: "Menu bar", symbol: "menubar.arrow.up.rectangle",
                  lead: "Keep ARPradar a click away, next to the clock.",
                  steps: [
                    HelpStep(text: "Turn on **ARPradar › Settings › General › Show ARPradar in the menu bar**."),
                    HelpStep(text: "Click the radar icon for the current network, how many devices are online, offline and new, and **Scan Now**."),
                    HelpStep(text: "**Ping…**, **Speed Test** and **Open ARPradar** are at the bottom. ARPradar keeps running in the menu bar when its windows are closed."),
                  ]),
        HelpTopic(id: "mode", title: "Basic and Advanced", symbol: "slider.horizontal.3",
                  lead: "Basic keeps the window simple. Advanced shows everything.",
                  steps: [
                    HelpStep(text: "Switch with **Basic | Advanced** at the top right, or **View › Advanced Mode** (⌥⌘B)."),
                    HelpStep(text: "Basic hides the Network adapter field, the History tab, and the Description, MAC address, Open ports and Response columns."),
                    HelpStep(text: "It also hides SSH, RDP, VNC, Scan Ports, Save for Remote Wake, Traceroute, DNS Lookup, Wi-Fi Analyzer, Subnet Calculator, Organizations, Mark outside DHCP, Copy and the expert parts of the details panel."),
                    HelpStep(text: "Nothing is lost: switch back and your columns and saved data are all there."),
                  ]),
        HelpTopic(id: "appearance", title: "Appearance", symbol: "paintpalette",
                  lead: "Light, dark and colour themes.",
                  steps: [
                    HelpStep(text: "Use **Auto / ☀︎ / ☾** in the bottom bar, or **View › Appearance**: Auto (⌥⌘0), Light (⌥⌘1), Dark (⌥⌘2)."),
                    HelpStep(text: "**ARPradar › Settings…** (⌘,) › **Appearance** has the theme: System, Radar, Ocean, Sunset, Graphite or High contrast."),
                    HelpStep(text: "**Row height** (Compact, Regular, Roomy) and **Text size** (Small, Medium, Large) change the device list and details panel."),
                    HelpStep(text: "Themes change colours only; everything stays in the same place."),
                  ]),
        HelpTopic(id: "trouble", title: "Permissions and troubleshooting", symbol: "exclamationmark.triangle",
                  lead: "When something doesn’t show up.",
                  steps: [
                    HelpStep(text: "**Only this Mac found?** macOS may be blocking ARPradar from the local network. Click **Open Local Network Settings** on the orange bar and turn ARPradar on."),
                    HelpStep(text: "**No Wi-Fi names?** macOS shares them only with apps allowed Location. ARPradar never reads where you are. macOS forgets this after an ARPradar update, so click **Allow…** again."),
                    HelpStep(text: "**New-device alerts**: **Settings › General › Notify me about new devices**. If nothing appears, check System Settings › Notifications."),
                    HelpStep(text: "**No switch or printer models?** Set the **SNMP community** in Settings › General (it starts as `public`)."),
                    HelpStep(text: "**Few names over a VPN?** Give the saved scan a name server (the client’s DNS server) in the organization’s **Settings** (Saved Scans › Organizations…), or in **Saved Scans › Edit This Scan…** for a standalone scan."),
                    HelpStep(text: "**Remote Desktop doesn’t open?** Install Windows App from the App Store."),
                  ]),
    ]
}

/// Help › ARPradar Help (⌘?): topics on the left, the chosen one on the right.
struct HelpView: View {
    static let windowID = "help"
    @State private var selected: String? = HelpTopic.all.first?.id
    @State private var query = ""
    @AppStorage(AppMode.key) private var advanced = true

    private var shown: [HelpTopic] { HelpTopic.matching(query) }
    private var current: HelpTopic? { shown.first { $0.id == selected } ?? shown.first }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: $selected) { t in
                Label(t.title, systemImage: t.symbol).tag(t.id)
            }
            .overlay {
                if shown.isEmpty {
                    Text("No topics match “\(query)”.").foregroundStyle(.secondary).padding()
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            if let t = current {
                ScrollView { HelpTopicView(topic: t, advanced: advanced).padding(24) }
            } else {
                Text("Try another word.").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search help")
        .frame(minWidth: 720, minHeight: 420)
    }
}

private struct HelpTopicView: View {
    let topic: HelpTopic
    let advanced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(topic.title).font(.title2.bold())
            Text(topic.lead).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if !advanced && topic.needsAdvanced {
                Label(topic.advancedOnly
                      ? "This needs Advanced mode. Switch at the top right of the main window, or press ⌥⌘B."
                      : "Steps marked ADVANCED need Advanced mode. Switch at the top right of the main window, or press ⌥⌘B.",
                      systemImage: "slider.horizontal.3")
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.dhcpOutside.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(topic.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(i + 1)")
                        .font(.caption.bold()).monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor.opacity(0.15), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(Self.styled(step.text))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if !advanced && (step.advanced || topic.advancedOnly) {
                            Text("ADVANCED")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.dhcpOutside)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.dhcpOutside))
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **bold** and `code` from the step text.
    static func styled(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Help › ARPradar Help (⌘?).
struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) { OpenHelpButton() }
    }
}

private struct OpenHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("ARPradar Help") { openWindow(id: HelpView.windowID) }
            .keyboardShortcut("?", modifiers: .command)
        Divider()
        Button("License") { openWindow(id: LicenseView.windowID) }
    }
}

/// Help › License: the GPL notice and full text (Resources/License.txt; LICENSE.txt in the repo is the plain GPL).
struct LicenseView: View {
    static let windowID = "license"
    static var text: String {
        guard let url = Bundle.main.url(forResource: "License", withExtension: "txt"),
              let t = try? String(contentsOf: url, encoding: .utf8) else { return "© 2026 Sean O'Neill. Free software under the GNU GPL v3." }
        return t
    }

    var body: some View {
        ScrollView {
            Text(Self.text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 720, minHeight: 420)
    }
}
