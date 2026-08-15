import SwiftUI
import AppKit

/// Hide-on-close window policy. We chose this over the `newWindowForTab:`
/// fallback because hiding preserves the window's identity and state (the
/// same NSWindow comes back on Open Stems…), whereas the sendAction fallback
/// would create a fresh SwiftUI window whose scene state may not line up with
/// the original. This app is LSUIElement, so there is no Dock "reopen"
/// affordance; without this delegate the main window is unrecoverable once
/// closed (WindowGroup windows are not recreatable from AppKit side), which
/// would strand both the menu-bar Open Stems… item and the Record-with-no-
/// selection path.
final class HideOnCloseWindowDelegate: NSObject, NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?
    private let hideOnClose = HideOnCloseWindowDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        menuBar = MenuBarController(model: model) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        // The WindowGroup window is created by SwiftUI after
        // applicationDidFinishLaunching returns, so defer one main-queue turn
        // before installing the hide-on-close delegate. The window stays in
        // NSApp.windows while hidden, so the openWindow closure above can
        // always order it front again.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let mainWindow = NSApp.windows.first(where: { $0.title == "Stems" })
                ?? NSApp.windows.first(where: { $0.canBecomeMain })
            mainWindow?.delegate = self.hideOnClose
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
