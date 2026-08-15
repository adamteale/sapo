import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        menuBar = MenuBarController(model: model) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}

struct StemsApp: App {
    // NOTE: no @main here — main.swift calls StemsApp.main() (SwiftPM executables
    // only allow top-level code in main.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Stems") {
            MainTabs(model: AppModel.shared)
                .frame(minWidth: 560, minHeight: 500)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(settings: AppModel.shared.settings, model: AppModel.shared)
        }
    }
}

struct MainTabs: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            RecorderView(model: model).tabItem { Label("Recorder", systemImage: "record.circle") }.tag(0)
            SessionsView(model: model).tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(1)
        }
    }
}
