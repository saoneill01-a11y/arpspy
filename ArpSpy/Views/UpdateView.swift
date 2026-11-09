import SwiftUI

/// Help › Check for Updates…
struct UpdateView: View {
    static let windowID = "updates"
    @ObservedObject private var model = UpdateModel.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch model.state {
            case .idle, .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking for updates…") }
            case .upToDate(let v):
                Text("You’re up to date").font(.headline)
                Text("ARPradar \(v) is the latest version.").foregroundStyle(.secondary)
                buttons { Button("OK") { dismiss() }.keyboardShortcut(.defaultAction) }
            case .available(let r):
                Text("ARPradar \(r.version) is available").font(.headline)
                Text("You have \(Updates.currentVersion).").foregroundStyle(.secondary)
                if !r.whatsNew.isEmpty { Text("What’s new: \(r.whatsNew)").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                buttons {
                    Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Download") { model.download(r) }.keyboardShortcut(.defaultAction)
                }
            case .downloading(let r):
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Downloading ARPradar \(r.version) and checking it…") }
            case .ready(let r, let app):
                Text("ARPradar \(r.version) is downloaded").font(.headline)
                Text("It’s in your Downloads folder and matches the checksum in the release notes.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if Updates.canInstallInPlace {
                    Text("Install replaces this copy in Applications and reopens ARPradar. macOS then asks again to allow Local Network.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Quit ARPradar, then drag the new ARPradar into your Applications folder.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                buttons {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                    if Updates.canInstallInPlace {
                        Button("Install and Relaunch") { model.install(app) }.keyboardShortcut(.defaultAction)
                    }
                }
            case .failed(let why):
                Text("Couldn’t update").font(.headline)
                Text(why).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                buttons {
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Try Again") { model.check() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .onAppear {
            switch model.state {
            case .downloading, .ready: break
            default: model.check()
            }
        }
    }

    private func buttons<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        HStack { Spacer(); c() }.padding(.top, 6)
    }
}
