import SwiftUI
import UIKit

/// One sensor: connect (claiming it the first time), then a one-step scan.
struct SensorScreen: View {
    let id: UUID
    @ObservedObject private var link = SensorLink.shared

    var body: some View {
        Group {
            switch link.phase {
            case .bluetoothOff(let why):
                message("Bluetooth", why, systemImage: "exclamationmark.triangle")
            case .idle, .connecting:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .ownedByOther:
                message("This sensor belongs to another app",
                        "Ask its owner to choose Release Sensor. Or reset it: put its SD card in a computer, add an empty file named “reset”, and put the card back. It then has no owner." + (link.note.isEmpty ? "" : "\n\n\(link.note)"),
                        systemImage: "lock")
            case .failed(let why):
                VStack(spacing: 16) {
                    message("Sensor", why, systemImage: "exclamationmark.triangle")
                    Button("Try Again") { link.select(nil); link.select(id) }
                        .buttonStyle(.borderedProminent)
                }
            case .ready, .working:
                ScanForm(link: link)
            }
        }
        .navigationTitle(link.sensorName.isEmpty ? "Sensor" : link.sensorName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if link.selected != id { link.select(id) } }
        // Keep the screen on while a scan runs: a locked phone drops the Bluetooth link and the results.
        .onChange(of: link.isWorking) { _, working in UIApplication.shared.isIdleTimerDisabled = working }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func message(_ title: String, _ text: String, systemImage: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ScanForm: View {
    @ObservedObject var link: SensorLink
    /// "" = the network the sensor is already on.
    @AppStorage("scan.network") private var network = ""
    @State private var other = ""
    @State private var password = ""
    @AppStorage("scan.range") private var range = ""
    @AppStorage("scan.quiet") private var quiet = false
    @State private var community = ""
    @State private var confirmRelease = false
    @FocusState private var focused: Bool

    private static let otherTag = "\u{1}other"
    private var chosenSSID: String? {
        network.isEmpty ? nil : network == Self.otherTag ? other.trimmingCharacters(in: .whitespaces) : network
    }
    private var chosenSecure: Bool {
        guard let s = chosenSSID else { return false }
        return link.networks.first { $0.ssid == s }?.secure ?? true
    }
    private var rangeProblem: String? {
        let t = range.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        do { _ = try IPRangeParser.parse(t); return nil } catch { return (error as? LocalizedError)?.errorDescription ?? "That range doesn’t look right." }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Wi-Fi", value: link.ssid.isEmpty ? "Not connected" : link.ssid)
                if !link.ip.isEmpty { LabeledContent("Address", value: link.ip) }
                if !link.version.isEmpty { LabeledContent("Sensor version", value: link.version) }
            } header: { Text("Sensor") }

            Section {
                Picker("Network", selection: $network) {
                    Text(link.ssid.isEmpty ? "The network it’s on" : "\(link.ssid) (now)").tag("")
                    ForEach(link.networks.filter { $0.ssid != link.ssid }) { n in
                        Text(n.secure ? n.ssid : "\(n.ssid) (open)").tag(n.ssid)
                    }
                    if !network.isEmpty, network != Self.otherTag, !link.networks.contains(where: { $0.ssid == network }) {
                        Text(network).tag(network)   // remembered from last time, not seen right now
                    }
                    Text("Other…").tag(Self.otherTag)
                }
                if network == Self.otherTag {
                    TextField("Network name", text: $other)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                if chosenSSID != nil && chosenSecure {
                    SecureField("Wi-Fi password", text: $password)
                }
                Button { link.refreshNetworks() } label: { Label("Refresh Networks", systemImage: "arrow.clockwise") }
                    .disabled(link.isWorking)
            } header: {
                Text("Scan from")
            } footer: {
                if chosenSSID != nil {
                    Text("The sensor joins this network just for the scan, then leaves it and deletes the password.")
                }
            }

            Section {
                TextField("Its whole network", text: $range)
                    .font(.body.monospaced())
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focused)
                Picker("Scan style", selection: $quiet) {
                    Text("Normal").tag(false)
                    Text("Quiet").tag(true)
                }
                .pickerStyle(.segmented)
                TextField("SNMP community (optional)", text: $community)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } header: {
                Text("IP range")
            } footer: {
                Text(rangeProblem ?? "For example 192.168.1.0/24 or 10.0.0.1-10.0.0.200. Quiet is slower and gentler: fewer ports, paced pings.")
                    .foregroundStyle(rangeProblem == nil ? Color.secondary : Color.red)
            }

            Section {
                if case .working(let f, let text) = link.phase {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(f, 0), 1))
                        Text(text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button("Stop", role: .destructive) { link.cancel() }
                } else {
                    Button {
                        focused = false
                        link.scan(ssid: chosenSSID, password: password, range: range, quiet: quiet, community: community)
                        password = ""
                    } label: {
                        Label("Scan", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(rangeProblem != nil || (network == Self.otherTag && other.trimmingCharacters(in: .whitespaces).isEmpty))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
                if !link.note.isEmpty { Text(link.note).font(.callout).foregroundStyle(.secondary) }
            }

            Section {
                Button("Release Sensor…", role: .destructive) { confirmRelease = true }
                    .disabled(link.isWorking)
            } footer: {
                Text("Releasing lets another phone or computer become the sensor’s owner.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Release this sensor?", isPresented: $confirmRelease, titleVisibility: .visible) {
            Button("Release Sensor", role: .destructive) { link.release() }
        } message: {
            Text("This iPhone stops being its owner. The next phone or computer that connects becomes the owner.")
        }
    }
}
