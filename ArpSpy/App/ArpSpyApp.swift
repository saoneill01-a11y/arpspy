import SwiftUI

@main
struct ArpSpyApp: App {
    init() {
        // Solid, always-visible scroll bars instead of the see-through overlay ones.
        UserDefaults.standard.register(defaults: ["AppleShowScrollBars": "Always"])
        AppMode.setDefault()
    }

    var body: some Scene {
        Window("ARPradar", id: "main") {
            ContentView()
                .modifier(AppearanceApplier())
        }
        .defaultSize(width: 1180, height: 700)
        .commands {
            RemoteWakeCommands()
            MainCommands()
            AppearanceCommands()
            ToolsCommands()
            OrgCommands()
            HelpCommands()
        }

        Window("Wake Remote PC", id: RemoteWakeView.windowID) {
            RemoteWakeView()
                .modifier(AppearanceApplier())
        }
        .defaultSize(width: 800, height: 620)

        WindowGroup("Scan Ports", id: PortScanView.windowID, for: UInt32.self) { $ip in
            PortScanView.window(ip: ip)
        }
        .defaultSize(width: 680, height: 540)

        Window("Scan List", id: SiteListView.windowID) {
            SiteListView()
                .modifier(AppearanceApplier())
        }
        .defaultSize(width: 1020, height: 480)

        ToolScenes()
        MenuBarScene()
        OrgScenes()

        Window("ARPradar Help", id: HelpView.windowID) {
            HelpView()
                .modifier(AppearanceApplier())
        }
        .defaultSize(width: 820, height: 580)

        Window("ARPradar License", id: LicenseView.windowID) {
            LicenseView()
                .modifier(AppearanceApplier())
        }
        .defaultSize(width: 720, height: 620)

        Settings {
            SettingsView()
                .modifier(AppearanceApplier())
        }
    }
}
