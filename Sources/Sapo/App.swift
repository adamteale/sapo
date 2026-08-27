import SwiftUI
import AppKit

/// Hide-on-close window policy. We chose this over the `newWindowForTab:`
/// fallback because hiding preserves the window's identity and state (the
/// same NSWindow comes back on Dock click or Open Sapo…), whereas the
/// sendAction fallback would create a fresh SwiftUI window whose scene state
/// may not line up with the original. Sapo is a regular app (Dock icon +
/// menu bar); applicationShouldHandleReopen restores the hidden window when
/// the user clicks the Dock icon.
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
        // Always-on tab discovery (extension pushes tab lists via the host).
        model.startTabRegistry()
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
            let mainWindow = NSApp.windows.first(where: { $0.title == "Sapo" })
                ?? NSApp.windows.first(where: { $0.canBecomeMain })
            mainWindow?.delegate = self.hideOnClose
            // Initial gate evaluation: SwiftUI created the window before this
            // block ran, so no key/occlusion notification will fire for the
            // launch — evaluate once so meters are live on a launched-but-
            // never-keyed window.
            model.windowVisibilityChanged(AppModel.stemsWindowVisible())
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Hide-on-close orders the window out rather than destroying it, so a
        // Dock click must order it back in — AppKit won't do that on its own
        // for an ordered-out SwiftUI WindowGroup window.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let center = NotificationCenter.default
        windowObservers.forEach(center.removeObserver)
        windowObservers = []
    }
}

struct SapoApp: App {
    // NOTE: no @main here — main.swift calls SapoApp.main() (SwiftPM executables
    // only allow top-level code in main.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Sapo") {
            MainTabs(model: AppModel.shared)
                .frame(minWidth: 560, minHeight: 500)
                .onAppear { registerShortcuts() }
                .onDisappear { unregisterShortcuts() }
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(settings: AppModel.shared.settings, model: AppModel.shared)
        }
    }
}

// MARK: - Keyboard Shortcuts

@MainActor
private var shortcutMonitors: [Any] = []

@MainActor
func registerShortcuts() {
    // ⌘R: Toggle record/stop
    shortcutMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift)
              && event.modifierFlags.contains(.control) == false else { return event }
        let key = event.characters?.lowercased() ?? ""
        if key == "r" {
            let model = AppModel.shared
            if case .recording = model.engine.state { model.stopRecording() }
            else { model.startRecording() }
            return nil // consume
        }
        if key == "e" {
            AppModel.shared.activeTab = 1 // switch to Sessions
            return nil
        }
        if key == "m" {
            if let mic = AppModel.shared.micSources.first {
                AppModel.shared.toggleSource(mic.id)
            }
            return nil
        }
        if let digit = key.first, let num = digit.wholeNumberValue {
            if num >= 1 && num <= 9 {
                let idx = num - 1
                let allSources = AppModel.shared.appSources + AppModel.shared.micSources
                if idx < allSources.count {
                    AppModel.shared.toggleSource(allSources[idx].id)
                }
                return nil
            }
        }
        return event
    })
}

@MainActor
func unregisterShortcuts() {
    for monitor in shortcutMonitors { NSEvent.removeMonitor(monitor) }
    shortcutMonitors.removeAll()
}

struct MainTabs: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView(selection: $model.activeTab) {
            RecorderView(model: model).tabItem { Label("Recorder", systemImage: "record.circle") }.tag(0)
            SessionsView(model: model).tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(1)
        }
    }
}
