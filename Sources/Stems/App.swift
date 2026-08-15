import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar + wiring arrive in later tasks.
    }
}

extension AppModel {
    static let shared = AppModel()
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
