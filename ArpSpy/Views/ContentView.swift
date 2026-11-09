import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject private var model = ScanModel.shared
    @Environment(\.theme) private var theme
    @Environment(\.openWindow) private var openWindow
    @AppStorage("detailsWidth") private var detailsWidth = 300.0
    @State private var confirmForget = false

    var body: some View {
        VStack(spacing: 0) {
            ScanBar(model: model)
            Divider()
            TabBar(model: model)
            Divider()
            if model.showPermissionHint && model.tab == .results { PermissionHint() }
            if model.offerSave && model.siteID == nil && !model.isScanning { SaveScanBar(model: model) }
            if let ip = model.serverOffer, !model.isScanning { ServerOfferBar(model: model, ip: ip) }
            HStack(spacing: 0) {
                Group {
                    switch model.tab {
                case .results, .favorites:
                    ResultsTable(model: model)
                        .overlay { if model.tab == .favorites && model.stored.favorites.isEmpty { EmptyFavorites() } }
                        .overlay { if model.tab == .results { EmptyResults(model: model) } }
                case .map:
                    NetMapView(model: model)
                case .history:
                    HSplitView {
                        HistoryList(model: model).frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                        ResultsTable(model: model)
                            .overlay { if model.selectedRecord == nil { EmptyHint(text: "Pick a past scan on the left.") } }
                    }
                    }
                }
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(-1)       // widening columns scrolls the table instead of pushing the window
                .clipped()
                if model.showDetails && model.tab != .map {
                    ResizeHandle(width: $detailsWidth)
                    DetailsPanel(model: model)
                        .frame(width: detailsWidth)
                        .background(theme.background ?? Color(nsColor: .windowBackgroundColor))
                }
            }
            Divider()
            StatusBar(model: model, confirmForget: $confirmForget)
        }
        .frame(minWidth: 900, minHeight: 500)
        .alert("ARPradar", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.siteSheet) { SiteSheetView(model: model, mode: $0) }
        // Scan Ports runs in its own window, so the main window stays usable while it works.
        .onChange(of: model.portScanTarget) { _, d in
            guard let d else { return }
            PortScanView.pending[d.ip.value] = d
            openWindow(id: PortScanView.windowID, value: d.ip.value)
            model.portScanTarget = nil
        }
        .sheet(item: $model.transferSheet) { sheet in
            switch sheet {
            case .export: ExportScansView(model: model)
            case .importing(let file, let name): ImportScansView(model: model, file: file, fileName: name)
            }
        }
        .confirmationDialog("Forget the \(model.offlineCount) offline device\(model.offlineCount == 1 ? "" : "s")?", isPresented: $confirmForget) {
            Button("Forget Offline", role: .destructive) { model.forgetOfflineDevices() }
        } message: {
            Text("The red rows are removed from this saved scan’s memory, so they won’t show as offline or count as NEW next time. Favorites are kept. This can’t be undone.")
        }
        .confirmationDialog("Delete the saved scan “\(model.siteToDelete?.name ?? "")”?",
                            isPresented: Binding(get: { model.siteToDelete != nil },
                                                 set: { if !$0 { model.siteToDelete = nil } })) {
            Button("Delete Scan", role: .destructive) {
                if let s = model.siteToDelete { model.deleteSite(s.id) }
                model.siteToDelete = nil
            }
        } message: {
            Text("Its saved devices and last scan are removed. This can’t be undone. Past scans in History stay.")
        }
    }
}

// MARK: - Top bar: Scan button, site, range, network, search

struct ScanBar: View {
    @ObservedObject var model: ScanModel
    @ObservedObject private var activity = Activity.shared
    @AppStorage(AppMode.key) private var advanced = true
    @FocusState private var searchFocused: Bool

    var body: some View {
        // A narrow window gets the compact bar: "+" for New Scan, no Saved Scans label or radar picture.
        ViewThatFits(in: .horizontal) {
            bar(compact: false)
            bar(compact: true)
        }
        .textFieldStyle(.roundedBorder)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func bar(compact: Bool) -> some View {
        HStack(alignment: .center, spacing: compact ? 8 : 12) {
            Button(action: model.toggleScan) {
                Label(model.isScanning ? "Stop" : model.canRescan ? "Rescan" : "Scan",
                      systemImage: model.isScanning ? "stop.fill" : model.canRescan ? "arrow.clockwise" : "play.fill")
                    .frame(minWidth: 76)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .help(model.canRescan ? "Scan this range again (⌘↩)" : "Scan the IP range (⌘↩)")
            .fixedSize()
            .layoutPriority(1)

            Button { model.newScan() } label: {
                if compact { Image(systemName: "plus").accessibilityLabel("New Scan") } else { Label("New Scan", systemImage: "plus") }
            }
            .controlSize(.large)
            .disabled(model.isScanning)
            .help("Start over: an empty list on this Mac’s network, not saved (⌘N)")
            .fixedSize()
            .layoutPriority(1)

            // Labels on the left; IP range over Network adapter, then Search and Saved Scans side by side.
            Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow {
                    label("IP range")
                    TextField("192.168.1.1-254, 10.0.0.0/24", text: $model.rangeText)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { if !model.isScanning { model.toggleScan() } }
                        .modifier(EntryBox())
                }
                if advanced {
                    GridRow {
                        label("Network adapter")
                        HStack(spacing: 4) {
                            Picker("Network adapter", selection: $model.selectedInterface) {
                                ForEach(model.interfaces) { Text($0.displayName).tag($0.id) }
                            }
                            .labelsHidden()
                            .help("The network adapter (Wi-Fi, Ethernet, USB, VPN) ARPradar scans from, and its subnet")
                            Button { model.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
                                .help("Refresh the adapter list (after plugging in a USB or Thunderbolt adapter)")
                                .accessibilityLabel("Refresh adapter list")
                        }
                    }
                }
            }
            .frame(minWidth: compact ? 240 : 260, idealWidth: compact ? 240 : 280, maxWidth: 380)
            .layoutPriority(1)

            // Search takes the spare width (up to 420) and shrinks when the window narrows.
            HStack(spacing: 6) {
                label("Search")
                TextField("Name, IP, MAC, vendor, port", text: $model.searchText)
                    .modifier(EntryBox())
                    .focused($searchFocused)
                    .onChange(of: model.searchFocusToken) { searchFocused = true }
                    .help("Filter the list (⌘F). Clears when you start a new scan.")
            }
            .frame(minWidth: compact ? 120 : 160, idealWidth: compact ? 120 : 180, maxWidth: 420)

            HStack(spacing: 6) {
                if !compact { label("Saved Scans") }
                SiteMenu(model: model)
                    .frame(minWidth: 120, idealWidth: compact ? 130 : 160, maxWidth: compact ? 140 : 200)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0).layoutPriority(-1)
            ModeSwitch()
            if !compact {
                RadarIcon(scanning: model.isScanning || activity.busy)
                    .frame(width: 40, height: 40)
            }
        }
    }

    /// A typing box that stands out from the bar: filled, with a clear outline (blue while typing in it).
    struct EntryBox: ViewModifier {
        @FocusState private var focused: Bool
        func body(content: Content) -> some View {
            content
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Color.accentColor : Color.primary.opacity(0.35), lineWidth: focused ? 2 : 1))
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
            .fixedSize()
    }
}

/// The Saved Scans menu: pick a saved scan (grouped by organization, then standalone), or manage them.
/// (In the code a saved scan is still a `Site`.)
struct SiteMenu: View {
    @ObservedObject var model: ScanModel
    @ObservedObject private var orgs = OrgStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            if model.stored.sites.isEmpty {
                Text("No saved scans yet. Save one after it finishes.")
            } else {
                ForEach(orgs.sortedOrgs.filter { !model.sites(in: $0.id).isEmpty }) { o in
                    Section(o.name) {
                        ForEach(model.sites(in: o.id)) { s in
                            Button { model.selectSite(s.id) } label: { item("\(s.name)  ·  \(s.range)", on: s.id == model.siteID) }
                        }
                    }
                }
                let loose = model.stored.sites.filter { $0.orgID == nil || orgs.org($0.orgID) == nil }
                if !loose.isEmpty {
                    Section("Standalone") {
                        ForEach(loose) { s in
                            Button { model.selectSite(s.id) } label: { item("\(s.name)  ·  \(s.range)", on: s.id == model.siteID) }
                        }
                    }
                }
            }
            Divider()
            Button("Edit This Scan…") { if let id = model.siteID { model.siteSheet = .edit(id) } }
                .disabled(model.siteID == nil)
            Button("Delete This Scan…") { model.siteToDelete = model.currentSite }
                .disabled(model.siteID == nil)
            Divider()
            Button("Organizations…") { openWindow(id: OrgWindows.list) }
            Button("Edit Scan List…") { openWindow(id: SiteListView.windowID) }
        } label: {
            Text(model.currentSite?.name ?? "Open a saved scan")
        }
        .disabled(model.isScanning)
        .help("Saved scans: pick one to scan that network again. Each keeps its own devices, so two networks with the same subnet don’t mix.")
    }

    @ViewBuilder private func item(_ text: String, on: Bool) -> some View {
        if on { Label(text, systemImage: "checkmark") } else { Text(text) }
    }
}

// MARK: - Results / Favorites / History switch

struct TabBar: View {
    @ObservedObject var model: ScanModel
    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        HStack(spacing: 10) {
            // The device lists in one bubble; the Map in its own next to it. Each shows nothing picked
            // while the other is in use.
            Picker("View", selection: Binding<ScanModel.Tab?>(get: { model.tab == .map ? nil : model.tab },
                                                            set: { if let t = $0 { model.tab = t } })) {
                ForEach(ScanModel.Tab.allCases.filter { $0 != .map && (advanced || $0 != .history) }) { tab in
                    if tab == .favorites && !model.stored.favorites.isEmpty {
                        Text("Favorites (\(model.stored.favorites.count))").tag(Optional(tab))
                    } else {
                        Text(tab.rawValue).tag(Optional(tab))
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: advanced ? 330 : 230)
            .onChange(of: advanced) { _, adv in if !adv && [.history, .map].contains(model.tab) { model.tab = .results } }
            .onAppear { if !advanced && [.history, .map].contains(model.tab) { model.tab = .results } }
            if advanced {
                Picker("Map", selection: Binding<ScanModel.Tab?>(get: { model.tab == .map ? .map : nil },
                                                               set: { if let t = $0 { model.tab = t } })) {
                    Label("Map", systemImage: "point.3.connected.trianglepath.dotted").tag(Optional(ScanModel.Tab.map))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("The network map (switches, access points and what’s plugged into them)")
            }
            Spacer()
            Button { model.showDetails.toggle() } label: {
                Image(systemName: model.showDetails ? "info.circle.fill" : "info.circle")
            }
            .buttonStyle(.borderless)
            .help("Show or hide device details (⌘I)")
            .accessibilityLabel("Device details")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - The device table (used by all three tabs)

extension ResultsTable {
    private static let savedKey = "advancedColumnVisibility"

    /// Basic hides the expert columns; Advanced puts back whatever was showing before.
    func applyMode(_ adv: Bool) {
        let ids = AppMode.advancedColumns
        if adv {
            guard let saved = UserDefaults.standard.dictionary(forKey: Self.savedKey) as? [String: Bool] else { return }
            for id in ids { columns[visibility: id] = (saved[id] ?? (id != "response")) ? .visible : .hidden }
            UserDefaults.standard.removeObject(forKey: Self.savedKey)
        } else {
            if UserDefaults.standard.dictionary(forKey: Self.savedKey) == nil {
                var saved: [String: Bool] = [:]
                for id in ids { saved[id] = columns[visibility: id] == .visible || (columns[visibility: id] == .automatic && id != "response") }
                UserDefaults.standard.set(saved, forKey: Self.savedKey)
            }
            for id in ids { columns[visibility: id] = .hidden }
        }
    }
}

/// The column switches (View menu and Settings › General).
enum ColumnSetting {
    static let typeKey = "showTypeColumn"            // on by default
    static let switchPortKey = "showSwitchPortColumn" // off by default
}

struct ResultsTable: View {
    @ObservedObject var model: ScanModel
    @SceneStorage("ResultsColumnsRight") private var columns: TableColumnCustomization<Device>
    @SceneStorage("ResultsColumnsFrozen") private var frozenColumns: TableColumnCustomization<Device>
    @AppStorage(ColumnSetting.typeKey) private var showType = true
    @AppStorage(ColumnSetting.switchPortKey) private var showSwitchPort = false
    /// Width of the frozen part (star, status, name). Drag the line next to it to change.
    @AppStorage("frozenWidth2") private var frozenWidth = 410.0
    @Environment(\.theme) private var theme
    @AppStorage(RowDensity.storageKey) private var density = RowDensity.regular
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.medium
    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        // Two tables side by side, sharing rows, selection and sort, scrolled up and down together:
        // the left one (star, status, name) stays put when the right one scrolls sideways.
        HStack(spacing: 0) {
            Table(model.visibleDevices, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $frozenColumns) {
                TableColumn("") { d in
                    Button { model.toggleFavorite([d]) } label: {
                        Image(systemName: model.isFavorite(d) ? "star.fill" : "star")
                            .foregroundStyle(model.isFavorite(d) ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(model.isFavorite(d) ? "Remove from Favorites" : "Add to Favorites")
                    .accessibilityLabel(model.isFavorite(d) ? "Remove from Favorites" : "Add to Favorites")
                }
                .width(22)

                TableColumn("Status") { d in
                    Circle().fill(d.isOnline ? theme.online : theme.offline).frame(width: 9, height: 9)
                        .help(d.isOnline ? "Online" : "Offline – last seen \(d.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityLabel(d.isOnline ? "Online" : "Offline")
                }
                .width(46)

                TableColumn("Name", value: \Device.nameSort) { d in
                    HStack(spacing: 5) {
                        Text(d.name.isEmpty ? "(no name)" : d.name)
                            .fontWeight(d.name.isEmpty ? .regular : .semibold)
                            .italic(d.name.isEmpty)
                            .foregroundStyle(d.name.isEmpty || !d.isOnline ? .secondary : .primary)
                        if d.isNew { NewBadge() }
                        if model.tab == .results, let role = model.servers.role(of: d.ip) { ServerBadge(role: role) }
                    }
                    .padding(.vertical, density.padding)
                }

                TableColumn("Type", value: \Device.kindSort) { d in
                    if let k = d.kind {
                        Label(k.label, systemImage: k.symbol)
                            .labelStyle(TypeLabelStyle())
                            .foregroundStyle(d.isOnline ? .primary : .secondary)
                            .help(d.typeOverride != nil ? "\(k.label) (set by you)" : "\(k.label) (best guess; right-click › Type to change)")
                    }
                }
                .width(min: 80, ideal: 110, max: 150)
                .customizationID("type")
            }
            .font(.system(size: textSize.points))
            .frame(width: frozenWidth)
            .scrollIndicators(.never)          // the right-hand table has the scroll bars
            .modifier(TableBehavior(model: model, role: .frozen))

            FrozenEdge(width: $frozenWidth)

            Table(model.visibleDevices, selection: $model.selection, sortOrder: $model.sortOrder,
                  columnCustomization: $columns) {
                TableColumn("IP", value: \Device.ipSort) { d in
                    HStack(spacing: 4) {
                        let outside = advanced && model.isOutsideDHCP(d)
                        Text(d.ip.description).monospaced()
                            .foregroundStyle(outside ? AnyShapeStyle(Color.dhcpOutside) : d.isOnline ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .padding(.horizontal, outside ? 4 : 0)
                            .background(outside ? Color.dhcpOutside.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 4))
                            .help(outside ? "Outside the DHCP range (static or reserved)" : "")
                        if d.isThisMac { Text("this Mac").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, density.padding)
                }
                .width(min: 132, ideal: 145)
                .customizationID("ip")

                TableColumn("Switch port", value: \Device.switchPortSort) { d in
                    if let l = d.switchLink {
                        HStack(spacing: 4) {
                            Image(systemName: l.wireless ? "wifi" : "cable.connector")
                                .foregroundStyle(.secondary).font(.caption)
                            Text(l.short).lineLimit(1)
                                .foregroundStyle(d.isOnline ? .primary : .secondary)
                            if let m = l.mbps, m > 0, !l.wireless {
                                Text(MapNode.speed(m)).font(.caption).monospacedDigit().foregroundStyle(LinkSpeed.color(m))
                            }
                        }
                        .help(SwitchLinkText.help(l))
                    }
                }
                .width(min: 110, ideal: 170)
                .customizationID("switchport")
                .defaultVisibility(.hidden)

                TableColumn("Description", value: \Device.detailsSort) { d in
                    Text(d.details).foregroundStyle(.secondary).lineLimit(1).help(d.details)
                }
                .width(min: 100, ideal: 190)
                .customizationID("description")

                TableColumn("Manufacturer", value: \Device.vendor) { d in
                    Text(d.vendor).foregroundStyle(d.vendor == "Private address" || !d.isOnline ? .secondary : .primary)
                }
                .width(min: 110, ideal: 160)
                .customizationID("vendor")

                TableColumn("MAC address", value: \Device.mac) { d in
                    Text(d.mac).monospaced()
                        .foregroundStyle(d.isOnline ? .primary : .secondary)
                }
                .width(min: 150, ideal: 160)
                .customizationID("mac")

                TableColumn("Open ports", value: \Device.portsSort) { d in
                    HStack(spacing: 4) {
                        ForEach(d.openPorts, id: \.self) { port in
                            Text(Ports.label(port))
                                .font(.caption)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .help(d.openPorts.map { "\($0) \(Ports.label($0))" }.joined(separator: ", "))
                }
                .width(min: 100, ideal: 170)
                .customizationID("ports")

                TableColumn("Response", value: \Device.responseSort) { d in
                    Text(d.responseMs.map { String(format: "%.0f ms", $0) } ?? "")
                        .monospacedDigit()
                        .foregroundStyle((d.responseMs ?? 0) > 200 ? Color.orange : Color.secondary)
                }
                .width(min: 60, ideal: 70)
                .customizationID("response")
                .defaultVisibility(.hidden)

                TableColumn("Comments") { d in
                    TextField("", text: model.commentBinding(for: d))
                        .textFieldStyle(.plain)
                }
                .customizationID("comments")
            }
            .font(.system(size: textSize.points))
            .modifier(TableBehavior(model: model, role: .main))
            .onAppear { applyMode(advanced); applyColumnSettings() }
            .onChange(of: advanced) { _, adv in applyMode(adv) }
            .onChange(of: showType) { applyColumnSettings() }
            .onChange(of: showSwitchPort) { applyColumnSettings() }
        }
    }
}

extension ResultsTable {
    /// The Type and Switch port checkboxes decide whether those columns show.
    func applyColumnSettings() {
        frozenColumns[visibility: "type"] = showType ? .visible : .hidden
        columns[visibility: "switchport"] = showSwitchPort ? .visible : .hidden
    }
}

/// Link speed colours, shared by the map and the table: 10G blue, 2.5G/5G light blue, 1G green, 100M or less orange.
enum LinkSpeed {
    static func color(_ mbps: Int) -> Color {
        switch mbps {
        case 10_000...: return .blue
        case 2_500..<10_000: return .cyan
        case 1_000..<2_500: return .green
        case 1...100: return .orange
        default: return .secondary
        }
    }
}

enum SwitchLinkText {
    /// The tooltip: "Office USW, port 5, 1G" or "Lobby AP (Wi-Fi, Home-5G, −58 dBm)".
    static func help(_ l: SwitchLink) -> String {
        if l.wireless {
            let extra = [l.ssid, l.signal.map { "\($0) dBm" } ?? ""].filter { !$0.isEmpty }
            return "\(l.device) (Wi-Fi\(extra.isEmpty ? "" : ", " + extra.joined(separator: ", ")))"
        }
        var s = l.device
        if let p = l.port { s += ", port \(p)" }
        if let m = l.mbps, m > 0 { s += ", \(MapNode.speed(m))" }
        if l.viaUnmanaged { s += ", behind an unmanaged switch" }
        return s + " (from the UniFi map)"
    }
}

/// Icon in a fixed-width slot, then the label, so the labels line up.
private struct TypeLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(Color.accentColor).frame(width: 18)
            configuration.title.lineLimit(1)
        }
    }
}

/// What both halves of the device table share: bottom margin, solid chrome, scroll sync, menus.
private struct TableBehavior: ViewModifier {
    @ObservedObject var model: ScanModel
    let role: TableSync.Role

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .contentMargins(.bottom, 18, for: .scrollContent)   // the last row clears the bottom scroll bar
            .background(SolidTableChrome(role: role, bar: theme.barNSColor))
            .contextMenu(forSelectionType: Device.ID.self) { ids in
                DeviceMenu(model: model, picked: model.rows(with: ids))
            } primaryAction: { ids in
                if ids.count == 1 { model.showDetails = true }
            }
    }
}

/// The line between the frozen columns and the rest; drag to make the Name column wider or narrower.
private struct FrozenEdge: View {
    @Binding var width: Double
    @State private var start: Double? = nil

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear.frame(width: 9).contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            if start == nil { start = width }
                            width = min(max((start ?? width) + g.translation.width, 200), 520)
                        }
                        .onEnded { _ in start = nil })
            }
            .help("Drag to widen the Name column")
    }
}

/// Keeps the frozen table and the main table scrolled to the same row.
@MainActor
final class TableSync {
    enum Role { case frozen, main }
    static let shared = TableSync()
    private weak var frozen: NSScrollView?
    private weak var main: NSScrollView?
    private var syncing = false
    private var observed = Set<ObjectIdentifier>()

    func register(_ scroll: NSScrollView, as role: Role) {
        switch role { case .frozen: frozen = scroll; case .main: main = scroll }
        let clip = scroll.contentView
        guard observed.insert(ObjectIdentifier(clip)).inserted else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self, weak scroll] _ in
            MainActor.assumeIsolated {
                guard let self, let scroll else { return }
                self.follow(scroll)
            }
        }
    }

    private func follow(_ source: NSScrollView) {
        guard !syncing, let other = source === frozen ? main : (source === main ? frozen : nil) else { return }
        let y = source.contentView.bounds.origin.y
        guard abs(other.contentView.bounds.origin.y - y) > 0.5 else { return }
        syncing = true
        other.contentView.scroll(to: NSPoint(x: other.contentView.bounds.origin.x, y: y))
        other.reflectScrolledClipView(other.contentView)
        syncing = false
    }
}

struct NewBadge: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Text("NEW")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(theme.accentText)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 3))
            .help("First time this saved scan has seen this device")
    }
}

/// "DHCP server" / "Name server" next to a device's name (found by the last scan).
struct ServerBadge: View {
    let role: String
    var body: some View {
        Text(role)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(role.hasPrefix("DHCP") ? Color.green : Color.blue)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background((role.hasPrefix("DHCP") ? Color.green : Color.blue).opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .lineLimit(1)
            .fixedSize()
            .help(role.hasPrefix("DHCP") ? "This network’s DHCP server (from this Mac’s DHCP lease)"
                                         : "A name server: one this network’s DHCP hands out, or (over a VPN) a device with the DNS port (53) open")
    }
}

/// After a scan in an organization: "Found … Use 10.0.0.5 for Example Dental / Not Now".
struct ServerOfferBar: View {
    @ObservedObject var model: ScanModel
    let ip: IPv4

    var body: some View {
        let org = model.currentSite?.organization
        HStack(spacing: 10) {
            Image(systemName: "server.rack").foregroundStyle(.secondary)
            Text("Found on this network: \(model.servers.summary).")
            if let org {
                Text(org.nameServer.trimmingCharacters(in: .whitespaces).isEmpty
                     ? "\(org.name)’s settings have no name server yet."
                     : "\(org.name) uses \(org.nameServer).")
                    .foregroundStyle(.secondary)
                Button("Use \(ip.description) for \(org.name)") { model.useOfferedNameServer() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Not Now") { model.serverOffer = nil }
            Spacer()
        }
        .lineLimit(1)
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.blue.opacity(0.10))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The right-click menu.
struct DeviceMenu: View {
    @ObservedObject var model: ScanModel
    let picked: [Device]
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        if picked.count == 1, let d = picked.first {
            Button("Open in Browser") { model.perform(DeviceActions.openWeb, on: d) }
            Button("Open Shares in Finder") { model.perform(DeviceActions.openShares, on: d) }
            if advanced {
                Button("SSH in Terminal") { model.perform(DeviceActions.ssh, on: d) }
                Button("Remote Desktop (RDP)") { model.perform(DeviceActions.remoteDesktop, on: d) }
                Button("Screen Sharing (VNC)") { model.perform(DeviceActions.screenSharing, on: d) }
            }
            Divider()
            if advanced { Button("Scan Ports…") { model.portScanTarget = d } }
            DeviceToolItems(device: d)
            Button("Show Details") { model.selection = [d.id]; model.showDetails = true }
            Divider()
        }
        if !picked.isEmpty {
            Button(picked.count == 1 ? "Wake on LAN" : "Wake on LAN (\(picked.count))") { model.wake(picked) }
                .disabled(picked.allSatisfy { $0.mac.isEmpty })
            if advanced, picked.count == 1, let d = picked.first {
                Button("Save for Remote Wake…") {
                    RemoteWakeStore.shared.add(from: d, interfaces: model.interfaces)
                    openWindow(id: RemoteWakeView.windowID)
                }
            }
            Button(model.allFavorite(picked) ? "Remove from Favorites" : "Add to Favorites") {
                model.toggleFavorite(picked)
            }
            if model.tab == .results, picked.contains(where: { !$0.isOnline }) {
                let n = picked.filter { !$0.isOnline }.count
                Button(n == 1 ? "Forget This Device" : "Forget \(n) Offline Devices") { model.forgetDevices(picked) }
                    .help("Stop remembering it for this saved scan (favorites are kept)")
            }
            Menu("Type") {
                let auto = picked.count == 1 ? DeviceTypeGuess.guess(picked[0]).map { " (\($0.label))" } ?? "" : ""
                Toggle("Automatic" + auto, isOn: Binding(get: { picked.allSatisfy { $0.typeOverride == nil } },
                                                         set: { if $0 { model.setType(nil, for: picked) } }))
                Divider()
                ForEach(DeviceKind.allCases, id: \.self) { k in
                    Toggle(isOn: Binding(get: { picked.allSatisfy { $0.typeOverride == k } },
                                         set: { if $0 { model.setType(k, for: picked) } })) {
                        Label(k.label, systemImage: k.symbol)
                    }
                }
            }
            Divider()
            let what = picked.count == 1 ? "" : " (\(picked.count))"
            Button("Copy IP") { Exporter.copyToClipboard(picked.map(\.ip.description).joined(separator: "\n")); model.flashStatus("Copied IP\(what)") }
            Button("Copy MAC") { Exporter.copyToClipboard(picked.map(\.mac).joined(separator: "\n")); model.flashStatus("Copied MAC\(what)") }
            Button("Copy Row") { Exporter.copyToClipboard(Exporter.tsv(model.withComments(picked))); model.flashStatus("Copied row\(what)") }
        }
    }
}

// MARK: - History list (left side of the History tab)

struct HistoryList: View {
    @ObservedObject var model: ScanModel
    @State private var deleting: ScanRecord? = nil
    @State private var confirmClear = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedRecord) {
                ForEach(model.stored.history) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.date.formatted(date: .abbreviated, time: .shortened)).fontWeight(.semibold)
                        Text([record.siteName, record.range, "\(record.devices.count) devices"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(record.id)
                    .contextMenu {
                        Button("Open in Results") { model.openHistoryRecord(record); model.tab = .results }
                        Divider()
                        Button("Delete This Scan…") { deleting = record }
                    }
                }
            }
            .overlay { if model.stored.history.isEmpty { EmptyHint(text: "No scans yet. Every finished scan is kept here.") } }
            Divider()
            HStack {
                Button("Open in Results") {
                    if let id = model.selectedRecord, let r = model.stored.history.first(where: { $0.id == id }) {
                        model.openHistoryRecord(r); model.tab = .results
                    }
                }
                .disabled(model.selectedRecord == nil || model.isScanning)
                .help("Show this scan in Results, where it stays when you leave History")
                Spacer()
                Button("Clear History…") { confirmClear = true }
                    .disabled(model.stored.history.isEmpty)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(8)
        }
        .confirmationDialog("Delete the scan from \(deleting?.date.formatted(date: .abbreviated, time: .shortened) ?? "")?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Scan", role: .destructive) { if let d = deleting { model.deleteHistory(d.id) }; deleting = nil }
        } message: { Text("It is removed from History. Saved scans aren’t affected. This can’t be undone.") }
        .confirmationDialog("Clear all \(model.stored.history.count) scans from History?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { model.clearHistory() }
        } message: { Text("Saved scans and their devices aren’t affected. This can’t be undone.") }
    }
}

/// The Results tab before anything has been scanned, or when the Search box hides every row.
struct EmptyResults: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        if model.visibleDevices.isEmpty && !model.isScanning {
            if model.hiddenBySearch > 0 {
                VStack(spacing: 8) {
                    Text("No devices match “\(model.searchText.trimmingCharacters(in: .whitespaces))”.").foregroundStyle(.secondary)
                    Button("Show All") { model.searchText = "" }
                }
                .padding()
            } else if model.devices.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text(model.currentSite.map { "\($0.name) hasn’t been scanned yet." } ?? "Nothing scanned yet.")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(model.rangeText.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "Type an IP range above, then press Scan (⌘↩)."
                         : "Press Scan (⌘↩) to find everything on \(model.rangeText.trimmingCharacters(in: .whitespaces)). It takes about ten seconds.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(action: model.toggleScan) { Label("Scan", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
            } else if !model.showOffline {
                EmptyHint(text: "Every device here is offline. Turn on Show offline in the bottom bar to see them.")
            }
        }
    }
}

// MARK: - Bottom bar

struct StatusBar: View {
    @ObservedObject var model: ScanModel
    @Binding var confirmForget: Bool
    @Environment(\.theme) private var theme
    @AppStorage(AppMode.key) private var advanced = true

    var body: some View {
        HStack(spacing: 14) {
            ProgressView(value: model.progress).frame(minWidth: 50, idealWidth: 140, maxWidth: 140)
            Text(model.statusText).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            if model.scannedCount > 0 {
                Text(counts).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
            }
            if model.hiddenBySearch > 0 {
                HStack(spacing: 4) {
                    Text("\(model.hiddenBySearch) hidden by search")
                    Button("Show all") { model.searchText = "" }
                }
                .font(.caption)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .lineLimit(1).fixedSize()
                .help("The Search box is hiding these rows")
            }
            if !model.servers.isEmpty && model.tab == .results && !model.isScanning {
                Text(model.servers.summary)
                    .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail).layoutPriority(-1)
                    .help("This network’s DHCP server and name servers, found by the scan")
            }
            Spacer()
            Toggle("Show offline", isOn: $model.showOffline)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .help("Show devices seen before that weren’t found in the last scan (red dots)")
            if advanced {
            Toggle("Mark outside DHCP", isOn: $model.markOutsideDHCP)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
                .disabled(model.dhcpRange == nil)
                .help(model.dhcpRange == nil
                      ? "Set a DHCP range in the organization’s Settings (or Edit This Scan… for a standalone scan) to use this"
                      : "Tint addresses outside the DHCP range \(model.dhcpRange!.short)")
            if model.markOutsideDHCP, let n = model.outsideDHCPCount, let r = model.dhcpRange {
                Text("\(n) outside \(r.short)")
                    .font(.caption)
                    .foregroundStyle(Color.dhcpOutside)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.dhcpOutside.opacity(0.14), in: RoundedRectangle(cornerRadius: 4))
                    .lineLimit(1)
            }
            }
            if model.showOffline && model.offlineCount > 0 && model.tab == .results && !model.isScanning {
                Button("Forget Offline…") { confirmForget = true }
                    .help("Remove devices that weren’t found this time. Favorites are kept. Asks first.")
            }
            if advanced {
                Button("Copy") {
                    Exporter.copyToClipboard(Exporter.tsv(model.withComments(model.visibleDevices)))
                    model.flashStatus("Copied \(model.visibleDevices.count) row\(model.visibleDevices.count == 1 ? "" : "s") (paste into Excel)")
                }
                .help("Copy the list as shown, ready to paste into Excel")
            }
            Menu("Export…") {
                Button("Export as CSV…") { model.export(.csv) }
                Button("Export as Excel (.xlsx)…") { model.export(.excel) }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Color.accentColor)
            AppearancePicker()
        }
        .font(.callout)
        .buttonStyle(.link)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(theme.bar.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.bar))
    }

    private var counts: String {
        var parts = ["\(model.onlineCount) online"]
        if model.offlineCount > 0 { parts.append("\(model.offlineCount) offline") }
        if model.newCount > 0 { parts.append("\(model.newCount) new") }
        parts.append("\(model.scannedCount) scanned")
        return parts.joined(separator: " · ")
    }
}

// MARK: - Hints

struct PermissionHint: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Only this Mac was found. If you expected more, ARPradar may be blocked from your local network.")
            Spacer()
            Button("Open Local Network Settings") { NSWorkspace.shared.open(LocalNetworkPermission.settingsURL) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}

struct EmptyFavorites: View {
    var body: some View {
        EmptyHint(text: "No favorites yet. Click the ☆ next to a device, or right-click › Add to Favorites.")
    }
}

struct EmptyHint: View {
    let text: String
    var body: some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center).padding().allowsHitTesting(false)
    }
}

/// The line between the table and the details panel; drag it to resize the panel.
struct ResizeHandle: View {
    @Binding var width: Double
    @State private var start: Double? = nil
    static let range = 240.0...560.0

    var body: some View {
        Divider()
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            let base = start ?? width
                            if start == nil { start = width }
                            width = min(max(base - g.translation.width, Self.range.lowerBound), Self.range.upperBound)
                        }
                        .onEnded { _ in start = nil })
            }
            .accessibilityLabel("Resize details panel")
    }
}

/// Makes the table's header and scroll bars opaque. SwiftUI's Table lets rows show through both
/// (macOS's floating header and overlay scroll bars), which looks messy when columns are wide.
struct SolidTableChrome: NSViewRepresentable {
    var role: TableSync.Role = .main
    var bar: NSColor = .windowBackgroundColor

    final class Probe: NSView {
        var role: TableSync.Role = .main
        var bar: NSColor = .windowBackgroundColor
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); fixSoon() }
        override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); fixSoon() }
        func fixSoon() { DispatchQueue.main.async { [weak self] in self?.fix() } }

        func fix() {
            guard let root = window?.contentView else { return }
            // The table is the scroll view that shares our position in the window.
            let mine = convert(bounds, to: nil)
            let centre = NSPoint(x: mine.midX, y: mine.midY)
            for scroll in Self.scrollViews(in: root) {
                guard let table = Self.first(NSTableView.self, in: scroll),
                      scroll.convert(scroll.bounds, to: nil).contains(centre) else { continue }
                TableSync.shared.register(scroll, as: role)
                if role == .frozen {
                    scroll.hasVerticalScroller = false
                    scroll.hasHorizontalScroller = false
                }
                scroll.scrollerStyle = .legacy
                scroll.autohidesScrollers = false
                // SwiftUI's table keeps the scroll bars floating over the rows even in the "legacy" style,
                // so give them a solid background. (Room for the bottom bar comes from .contentMargins.)
                for scroller in [scroll.horizontalScroller, scroll.verticalScroller].compactMap({ $0 }) {
                    scroller.scrollerStyle = .legacy
                    scroller.wantsLayer = true
                    scroller.layer?.backgroundColor = Self.resolved(bar, for: scroller)
                }

                if let header = table.headerView {
                    header.wantsLayer = true
                    header.layer?.backgroundColor = Self.resolved(bar, for: header)
                }
            }
        }

        /// A system colour as it looks in this view's light/dark appearance.
        static func resolved(_ color: NSColor, for view: NSView) -> CGColor {
            var out = color.cgColor
            view.effectiveAppearance.performAsCurrentDrawingAppearance { out = color.cgColor }
            return out
        }

        static func first<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
            if let t = v as? T { return t }
            for s in v.subviews { if let t = first(type, in: s) { return t } }
            return nil
        }

        static func scrollViews(in v: NSView) -> [NSScrollView] {
            ((v as? NSScrollView).map { [$0] } ?? []) + v.subviews.flatMap { scrollViews(in: $0) }
        }
    }

    func makeNSView(context: Context) -> Probe { let p = Probe(); p.role = role; p.bar = bar; return p }
    func updateNSView(_ v: Probe, context: Context) { v.role = role; v.bar = bar; v.fixSoon() }
}

/// After a scan that isn't saved: "Save this scan?" with a choice of organization or standalone.
struct SaveScanBar: View {
    @ObservedObject var model: ScanModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down").foregroundStyle(.secondary)
            Text("\(model.onlineCount) devices found.").fontWeight(.semibold)
            Text("Save this scan?")
            Button("Save to Organization…") { model.saveStandalone = false; model.siteSheet = .new }
                .buttonStyle(.borderedProminent)
            Button("Save Standalone…") { model.saveStandalone = true; model.siteSheet = .new }
            Button("Not Now") { model.offerSave = false }
            Spacer()
        }
        .controlSize(.small)
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(Color.yellow.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
    }
}
