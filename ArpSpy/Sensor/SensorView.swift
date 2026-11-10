import SwiftUI

/// Tools › ARPradar Sensor…: nearby sensors on the left; the chosen one's Wi-Fi and a one-step scan on the right.
/// Results open in the main window as a new scan.
struct SensorView: View {
    static let windowID = "sensor"
    @ObservedObject private var link = SensorLink.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            nearbyList
                .frame(width: 210)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { link.start() }
    }

    private var nearbyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nearby").font(.caption).foregroundStyle(.secondary).padding([.top, .horizontal], 10)
            List(selection: Binding(get: { link.selected }, set: { link.select($0) })) {
                ForEach(link.nearby) { s in
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(s.rssi > -70 ? .green : s.rssi > -85 ? .orange : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.name)
                            Text(signalText(s.rssi)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(Optional(s.id))
                }
            }
            .listStyle(.sidebar)
            Text(link.nearby.isEmpty ? "Looking for sensors… Power one on within about 10 m of this Mac."
                                     : "Sensors show up when they’re powered on within Bluetooth range.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
        }
    }

    private func signalText(_ rssi: Int) -> String {
        rssi > -70 ? "Strong signal" : rssi > -85 ? "Good signal" : "Weak signal"
    }

    @ViewBuilder private var detail: some View {
        switch link.phase {
        case .bluetoothOff(let why):
            message("Bluetooth", why)
        case .idle:
            message("ARPradar Sensor", "Pick a sensor on the left. The first time, this Mac becomes its owner: other Macs and phones can’t use it until you release it.")
        case .connecting:
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Connecting…") }
        case .ownedByOther:
            VStack(alignment: .leading, spacing: 10) {
                Text("This sensor belongs to another app").font(.headline)
                Text("Ask its owner to choose Release Sensor. Or reset it: put the SD card in a computer, add an empty file named “reset”, and put the card back. It then has no owner.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !link.note.isEmpty { Text(link.note).font(.callout).foregroundStyle(.secondary) }
            }
        case .failed(let why):
            message("Sensor", why)
        case .ready, .working:
            SensorScanForm(link: link, showMain: { openWindow(id: "main") })
        }
    }

    private func message(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SensorScanForm: View {
    @ObservedObject var link: SensorLink
    let showMain: () -> Void
    /// "" = the network the sensor is already on.
    @State private var network = ""
    @State private var other = ""
    @State private var password = ""
    @State private var range = ""
    @State private var quiet = false
    @State private var confirmRelease = false

    private static let otherTag = "\u{1}other"
    private var chosenSSID: String? {
        network.isEmpty ? nil : network == Self.otherTag ? other.trimmingCharacters(in: .whitespaces) : network
    }
    private var chosenSecure: Bool {
        guard let s = chosenSSID else { return false }
        return link.networks.first { $0.ssid == s }?.secure ?? true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(link.sensorName.isEmpty ? "ARPradar Sensor" : link.sensorName).font(.headline)
                Text(link.ssid.isEmpty ? "Not on a Wi-Fi network · sensor \(link.version)"
                                       : "On \(link.ssid) · \(link.ip) · sensor \(link.version)")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Form {
                Picker("Network", selection: $network) {
                    Text(link.ssid.isEmpty ? "The network it’s on" : "\(link.ssid) (the network it’s on)").tag("")
                    if !link.networks.isEmpty { Divider() }
                    ForEach(link.networks.filter { $0.ssid != link.ssid }) { n in
                        Text(n.secure ? n.ssid : "\(n.ssid) (open)").tag(n.ssid)
                    }
                    Divider()
                    Text("Other…").tag(Self.otherTag)
                }
                if network == Self.otherTag {
                    TextField("Network name", text: $other)
                }
                if chosenSSID != nil && chosenSecure {
                    SecureField("Password", text: $password)
                }
                TextField("IP range", text: $range, prompt: Text("Its whole network"))
                    .font(.system(.body, design: .monospaced))
                Picker("Scan", selection: $quiet) {
                    Text("Normal").tag(false)
                    Text("Quiet").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if chosenSSID != nil {
                Text("The sensor joins this network just for the scan, then leaves it and deletes the password.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Release Sensor…") { confirmRelease = true }
                    .disabled(link.isWorking)
                Button { link.refreshNetworks() } label: { Label("Refresh Networks", systemImage: "arrow.clockwise") }
                    .disabled(link.isWorking)
                Spacer()
                if link.isWorking {
                    Button("Stop") { link.cancel() }
                } else {
                    Button("Scan") {
                        link.scan(ssid: chosenSSID, password: password, range: range, quiet: quiet)
                        password = ""
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(network == Self.otherTag && other.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            if case .working(let f, let text) = link.phase {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(max(f, 0), 1))
                    Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if !link.note.isEmpty {
                HStack(spacing: 8) {
                    Text(link.note).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if link.note.contains("main window") { Button("Show") { showMain() } }
                }
            }
        }
        .confirmationDialog("Release this sensor?", isPresented: $confirmRelease) {
            Button("Release Sensor", role: .destructive) { link.release() }
        } message: {
            Text("This Mac stops being its owner. The next Mac or phone that connects to it becomes the owner.")
        }
    }
}
