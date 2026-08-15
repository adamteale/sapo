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
    /// Window-gate observers; removed in applicationWillTerminate.
    private var windowObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        menuBar = MenuBarController(model: model) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        // Window gate: recompute metersOn whenever the window becomes/ceases
        // key or its occlusion state changes (hide-on-close, tab switch,
        // covered by a fullscreen app). Observe on the main queue; the handler
        // routes through mic permission (ruling 4) via
        // AppModel.windowVisibilityChanged.
        let center = NotificationCenter.default
        let visibilityHandler: (Notification) -> Void = { _ in
            model.windowVisibilityChanged(AppModel.stemsWindowVisible())
        }
        windowObservers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
            using: visibilityHandler))
        windowObservers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main,
            using: visibilityHandler))
        windowObservers.append(center.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main,
            using: visibilityHandler))
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
            // Initial gate evaluation: SwiftUI created the window before this
            // block ran, so no key/occlusion notification will fire for the
            // launch — evaluate once so meters are live on a launched-but-
            // never-keyed window.
            model.windowVisibilityChanged(AppModel.stemsWindowVisible())
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
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
