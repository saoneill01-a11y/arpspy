import SwiftUI

/// The "Wake Remote PC" window: saved PCs on the left, the selected one's settings on the right.
struct RemoteWakeView: View {
    @ObservedObject var store = RemoteWakeStore.shared
    /// The PCs a delete is waiting on the user to confirm (empty = no dialog).
    @State private var toDelete = Set<UUID>()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $store.selection) {
                    Section("Saved PCs") {
                        ForEach(store.targets) { t in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.displayName)
                                if !t.subtitle.isEmpty {
                                    Text(t.subtitle).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(t.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onDeleteCommand { askToDelete(store.selection) }
                Divider()
                HStack(spacing: 4) {
                    Button { store.addBlank() } label: { Image(systemName: "plus") }
                        .help("Add a PC")
                        .accessibilityLabel("Add a PC")
                    Button { askToDelete(store.selection) } label: { Image(systemName: "minus") }
                        .help("Delete the selected PCs")
                        .accessibilityLabel("Delete the selected PCs")
                        .disabled(store.selection.isEmpty)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 200, idealWidth: 240, maxWidth: 340)

            Group {
                if store.selection.count == 1, let id = store.selection.first, let i = store.index(of: id) {
                    TargetForm(store: store, target: $store.targets[i], onDelete: { askToDelete([id]) })
                } else if store.selection.count > 1 {
                    MultiWake(store: store)
                } else {
                    EmptyRemote(store: store)
                }
            }
            .frame(minWidth: 460, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 440)
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !toDelete.isEmpty }, set: { if !$0 { toDelete = [] } })) {
            Button("Delete", role: .destructive) { store.delete(toDelete); toDelete = [] }
        } message: {
            Text("This can’t be undone.")
        }
    }

    private var deleteTitle: String {
        if toDelete.count == 1, let t = store.targets.first(where: { toDelete.contains($0.id) }) { return "Delete “\(t.displayName)”?" }
        return "Delete \(toDelete.count) saved PCs?"
    }

    /// Asks first, naming what goes. A row that is still blank (no name, no MAC) just goes.
    private func askToDelete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let picked = store.targets.filter { ids.contains($0.id) }
        if picked.allSatisfy({ $0.name.isEmpty && $0.mac.isEmpty && $0.ip.isEmpty }) { store.delete(ids); return }
        toDelete = ids
    }
}

private struct TargetForm: View {
    @ObservedObject var store: RemoteWakeStore
    @Binding var target: RemoteWakeTarget
    var onDelete: () -> Void

    private var macOK: Bool { RemoteWake.normalizeMAC(target.mac) != nil }
    private var ip: IPv4? { IPv4(target.ip) }
    private var broadcastText: String {
        guard let ip, let b = RemoteWake.broadcast(of: ip, prefix: target.prefix) else { return "" }
        _ = ip
        return "(\(b))"
    }

    var body: some View {
        ScrollView {
            Form {
                TextField("Name", text: $target.name, prompt: Text("Front desk PC"))
                TextField("Client / site", text: $target.site, prompt: Text("Client name"))
                LabeledContent("MAC address") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextField("", text: $target.mac, prompt: Text("Paste from your RMM, any format"))
                            .font(.system(.body, design: .monospaced))
                            .onSubmit { tidyMAC() }
                        if !target.mac.isEmpty && !macOK {
                            Text("Needs 12 hex digits, like 3C-52-82-1A-7E-09").font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                LabeledContent("PC’s IP address") {
                    HStack(spacing: 6) {
                        TextField("", text: $target.ip, prompt: Text("10.20.30.45"))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 150)
                        Text("/")
                        TextField("", value: $target.prefix, format: .number)
                            .frame(width: 44)
                            .multilineTextAlignment(.center)
                        Text("subnet").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Send to") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $target.sendToIP) {
                            Text("The PC’s IP ") + Text(ip.map { "(\($0))" } ?? "").foregroundColor(.secondary)
                        }
                        Toggle(isOn: $target.sendToBroadcast) {
                            Text("Its subnet broadcast ") + Text(broadcastText).foregroundColor(.secondary)
                        }
                        HStack {
                            Toggle("Another relay address:", isOn: $target.useRelay)
                            TextField("", text: $target.relay, prompt: Text("10.20.30.1"))
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 140)
                                .disabled(!target.useRelay)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                LabeledContent("UDP port") {
                    HStack {
                        TextField("", value: $target.port, format: .number.grouping(.never))
                            .frame(width: 60)
                            .multilineTextAlignment(.center)
                        Text("9 is standard; some setups use 7").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("After sending") {
                    Toggle("Check for 2 minutes and tell me when it wakes up", isOn: $target.checkAfter)
                        .toggleStyle(.checkbox)
                }
            }
            .formStyle(.columns)
            .padding(.top, 18)
            .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Delete", role: .destructive) { onDelete() }
                    Spacer()
                    Button("Wake") { tidyMAC(); store.wake([target.id]) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!macOK || ip == nil)
                }
                if let s = store.statuses[target.id] { StatusBox(status: s) }

                Text("**How it gets there:** the packet goes out through your VPN like any other traffic. Sending to the PC’s IP works if the client’s router still has the PC in its ARP table. The broadcast works only if that router forwards directed broadcasts. Sending both gives the best chance.")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.yellow.opacity(0.35)))

            }
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
    }

    private func tidyMAC() {
        if let m = RemoteWake.normalizeMAC(target.mac), m != target.mac { target.mac = m }
    }
}

private struct StatusBox: View {
    let status: RemoteWakeStore.Status

    private var color: Color {
        switch status.state {
        case .awake, .sent: return .green
        case .waiting, .sending: return .orange
        case .noAnswer, .failed: return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if status.state == .waiting { ProgressView().controlSize(.small) }
                Text(status.headline).bold().foregroundStyle(color)
            }
            ForEach(status.lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        .textSelection(.enabled)
    }
}

private struct MultiWake: View {
    @ObservedObject var store: RemoteWakeStore

    var body: some View {
        let picked = store.targets.filter { store.selection.contains($0.id) }
        VStack(alignment: .leading, spacing: 12) {
            Text("\(picked.count) PCs selected").font(.title3).bold()
            ForEach(picked) { t in
                HStack(alignment: .firstTextBaseline) {
                    Text(t.displayName).frame(width: 160, alignment: .leading)
                    if let s = store.statuses[t.id] {
                        Text(s.headline).bold()
                        Text(s.lines.last ?? "").foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Wake All \(picked.count)") { store.wake(store.selection) }
                    .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
        .padding(22)
    }
}

private struct EmptyRemote: View {
    @ObservedObject var store: RemoteWakeStore

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "power").font(.system(size: 34)).foregroundStyle(.secondary)
            Text(store.targets.isEmpty ? "No saved PCs yet." : "Pick a PC on the left.")
                .foregroundStyle(.secondary)
            if store.targets.isEmpty {
                Button("Add a PC") { store.addBlank() }
                Text("Or right-click a device in a scan and choose “Save for Remote Wake…”.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// File > Wake Remote PC…
struct RemoteWakeCommands: Commands {
    var body: some Commands {
        // Wake Remote PC… is in MainCommands' File menu group (separate groups at the same spot get dropped).
        CommandGroup(after: .newItem) {}
    }
}

struct OpenRemoteWakeButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Wake Remote PC…") { openWindow(id: RemoteWakeView.windowID) }
            .keyboardShortcut("w", modifiers: [.command, .shift])
    }
}

extension RemoteWakeView {
    static let windowID = "remote-wake"
}
