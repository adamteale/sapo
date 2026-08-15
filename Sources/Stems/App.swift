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
            RecorderView(model: AppModel.shared)
                .frame(minWidth: 520, minHeight: 480)
        }
        .windowResizability(.contentSize)
    }
}
