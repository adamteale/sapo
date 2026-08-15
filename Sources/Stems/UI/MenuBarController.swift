import AppKit
import Combine

/// Menu bar (status item) controller: waveform icon when idle, red dot while
/// recording, and a menu with Record/Stop (with elapsed time), Open Stems, and
/// Quit. The menu is rebuilt whenever the engine state changes and once per
/// second while recording so the elapsed time stays fresh.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables: Set<AnyCancellable> = []
    private let model: AppModel
    private let openWindow: () -> Void

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Stems")
        rebuildMenu()
        model.engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        // Menu-bar-initiated start failures never surface in the recorder view
        // (the window may be hidden), so surface them here as an alert and pull
        // the window forward.
        model.$lastError
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in self?.handleLastError(error) }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard case .recording = self?.model.engine.state else { return }
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private var isRecording: Bool {
        if case .recording = model.engine.state { return true }
        return false
    }

    func refresh() { rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRecording {
            if case .recording(let started) = model.engine.state {
                let elapsed = Int(Date().timeIntervalSince(started))
                let title = String(format: "Recording %02d:%02d:%02d",
                                   elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)
                menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
                menu.addItem(.separator())
                let stop = NSMenuItem(title: "Stop", action: #selector(stopTapped), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
            statusItem.button?.contentTintColor = .systemRed
        } else {
            let record = NSMenuItem(title: "Record", action: #selector(recordTapped), keyEquivalent: "r")
            record.target = self
            menu.addItem(record)
            statusItem.button?.contentTintColor = nil
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Stems…", action: #selector(openTapped), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Stems", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func recordTapped() {
        model.refreshSources()
        if model.selectedSourceIDs.isEmpty { openWindow() } // nothing selected → configure in window
        else { model.startRecording() }
    }

    @objc private func stopTapped() { model.stopRecording() }

    @objc private func openTapped() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow()
    }

    /// Last error value we already alerted on; reset when lastError clears so
    /// a later identical failure still shows its own alert.
    private var lastShownError: String?

    private func handleLastError(_ error: String?) {
        guard let error else {
            lastShownError = nil
            return
        }
        guard error != lastShownError else { return }
        lastShownError = error
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't start recording"
        alert.informativeText = error
        alert.addButton(withTitle: "OK")
        alert.runModal()
        // Bring the recorder window forward so the user can fix the cause
        // (e.g. select sources) — same path as Open Stems….
        NSApp.activate(ignoringOtherApps: true)
        openWindow()
    }
}
