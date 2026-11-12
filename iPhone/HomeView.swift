import SwiftUI

/// Nearby sensors, then the scans kept on this phone.
struct HomeView: View {
    @EnvironmentObject private var archive: ScanArchive
    @EnvironmentObject private var router: Router
    @ObservedObject private var link = SensorLink.shared
    @State private var confirmDelete: IndexSet? = nil

    var body: some View {
        NavigationStack(path: $router.path) {
            List {
                Section {
                    if case .bluetoothOff(let why) = link.phase {
                        Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else if link.nearby.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for sensors… Power one on within about 10 m (30 ft).")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(link.nearby) { s in
                        NavigationLink(value: Route.sensor(s.id)) {
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(signalColor(s.rssi))
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.name)
                                    Text(signalText(s.rssi)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Nearby sensors")
                } footer: {
                    Text("The first time you connect, this iPhone becomes the sensor’s owner. Other phones and computers can’t use it until you release it.")
                }

                HeatmapSection()

                Section("Past scans") {
                    if archive.scans.isEmpty {
                        Text("Scans you run show up here.").foregroundStyle(.secondary)
                    }
                    ForEach(archive.scans) { scan in
                        NavigationLink(value: Route.scan(scan.id)) { ScanRowLabel(scan: scan) }
                    }
                    .onDelete { confirmDelete = $0 }
                }
            }
            .navigationTitle("ARPradar")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(value: Route.about) { Image(systemName: "info.circle") }
                        .accessibilityLabel("About")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .sensor(let id): SensorScreen(id: id)
                case .scan(let id):
                    if let scan = archive.scan(id) { ResultsView(scan: scan) } else { Text("This scan was deleted.") }
                case .heatmap(let id): HeatmapScreen(id: id)
                case .about: AboutView()
                }
            }
            .confirmationDialog("Delete this scan?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let set = confirmDelete { archive.delete(Set(set.map { archive.scans[$0].id })) }
                    confirmDelete = nil
                }
            }
        }
        .onAppear { link.start() }
        .onChange(of: router.path) { _, path in
            // Back on the home screen: hang up, so the sensor is free and the battery isn't used.
            if path.isEmpty { link.select(nil) }
        }
    }
}

struct ScanRowLabel: View {
    let scan: SavedScan
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(scan.title)
            Text("\(scan.rows.count) devices · \(scan.date.formatted(date: .abbreviated, time: .shortened))\(scan.cancelled ? " · stopped" : "")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

func signalColor(_ rssi: Int) -> Color { rssi > -70 ? .green : rssi > -85 ? .orange : .secondary }
func signalText(_ rssi: Int) -> String { rssi > -70 ? "Strong signal" : rssi > -85 ? "Good signal" : "Weak signal" }

struct AboutView: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("ARPradar").font(.title2.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                    Text("Runs network scans on an ARPradar Sensor (a small Raspberry Pi) and shows every device it finds: IP and MAC address, manufacturer, name and open ports.")
                        .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
            Section("Good to know") {
                Text("Only scan networks you own or have permission to scan.")
                Text("The phone talks to the sensor over Bluetooth, encrypted. Scans stay on this iPhone; nothing is sent anywhere else.")
                Text("Wi-Fi passwords you type go to the sensor for that one scan, then it deletes them.")
            }
            Section {
                Link("arpradar.com", destination: URL(string: "https://arpradar.com")!)
                Text("© 2026 Sean O'Neill. Free software under the GNU GPL v3 or later. Manufacturer names from the IEEE list.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}
