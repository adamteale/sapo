import Foundation
import Combine
import AVFoundation
import AppKit

@MainActor
final class AppModel: ObservableObject {
    let engine = RecorderEngine()
    let store = SessionStore()
    let settings: SettingsStore
    /// Coordinates meter-only capture taps (Task 2/3): one MeterChain per
    /// metered row id, reconciled on window/session/row changes.
    let meters = MeterManager()

    @Published var appSources: [SourceDescriptor] = []
    @Published var micSources: [SourceDescriptor] = []
    @Published var tabSources: [SourceDescriptor] = []
    @Published var selectedSourceIDs: Set<String> = []
    @Published var permissionDenied = false
    /// Window-visibility gate: meter taps only run while the Sapo window is
    /// on screen (hide-on-close keeps the window in NSApp.windows with
    /// isVisible == false while hidden — that's the signal). Driven by
    /// AppDelegate's key/occlusion notifications via windowVisibilityChanged.
    @Published var metersOn = false
    /// Last recording-start error (e.g. low disk), shown in the recorder view;
    /// cleared on the next Record tap.
    @Published var lastError: String?
    /// Which tab is active (0 = Recorder, 1 = Sessions). Driven by MainTabs
    /// so RecorderView can switch to Sessions after a recording ends.
    @Published var activeTab = 0
    /// Source IDs whose stem is muted during recording (their chain is stopped
    /// and removed; unmute restores it). Empty when idle.
    @Published var mutedSourceIDs: Set<String> = []

    private let registry = SourceRegistry()
    private var cancellables: Set<AnyCancellable> = []

    static let shared = AppModel()

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        // Forward engine state changes (recording started/stopped, meter levels)
        // to this model so views observing only AppModel stay in sync, and
        // re-evaluate meter targets on every engine change: record start/stop
        // changes recordingSourceIDs, so recording sources must stop being
        // metered the moment they start capturing and resume when they end
        // (ruling 2). reconcileMeters is idempotent — the 10Hz levels churn
        // during recording is a cheap no-op diff, not a churn of taps.
        engine.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                self.reconcileMeters()
            }
            .store(in: &cancellables)
    }

    var selectedSources: [SourceDescriptor] {
        (appSources + micSources + tabSources).filter { selectedSourceIDs.contains($0.id) }
    }

    /// WAV: rate × channels × 2 bytes; ALAC ≈ 50% of WAV.
    var estimatedBytesPerHour: Int64 {
        let channelsAvg = 2.0
        let wavBytesPerSecond = 48_000.0 * channelsAvg * 2
        let factor = settings.stemFormat == .alac ? 0.5 : 1.0
        return Int64(Double(selectedSourceIDs.count) * wavBytesPerSecond * factor * 3600)
    }

    /// True while the Sapo window is on screen. Hide-on-close keeps the
    /// window in NSApp.windows but orderOut sets isVisible == false — so this
    /// is the visibility signal the window gate keys on (onDisappear is never
    /// used, per the plan).
    ///
    /// The window is identified structurally, not by title: its title tracks
    /// the selected tab's navigationTitle ("Recorder"/"Sessions"/session
    /// title), never "Sapo". This app is LSUIElement with exactly one regular
    /// window, so a visible window that can become main is precisely it.
    static func stemsWindowVisible() -> Bool {
        NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    }

    /// Window-visibility entry point, called from AppDelegate's key/occlusion
    /// notifications. Mic permission gates meter taps (ruling 4): the first
    /// time the window shows, route through requestMicPermission — granted
    /// turns meters on, denial keeps the existing permission bar and meters
    /// stay off. requestMicPermission's .authorized fast path is synchronous,
    /// so the common case has no async gap.
    func windowVisibilityChanged(_ visible: Bool) {
        guard visible else {
            metersOn = false
            reconcileMeters()
            return
        }
        requestMicPermission { [weak self] granted in
            guard let self else { return }
            // The first-ever prompt is async: the window may have hidden while
            // it was up. Re-check so the gate can't turn meters on for a
            // hidden window.
            guard Self.stemsWindowVisible() else {
                self.metersOn = false
                self.reconcileMeters()
                return
            }
            self.metersOn = granted
            self.reconcileMeters()
        }
    }

    /// Display level for a row: recording chains win; otherwise meter taps.
    func level(for id: String) -> Float {
        engine.levels[id] ?? meters.meterLevels[id] ?? 0
    }

    /// Idempotent: bring meter taps in line with the current window gate, row
    /// set, and recording set. Callers: windowVisibilityChanged (App.swift
    /// notifications), engine transitions (init sink), and toggle/refresh.
    /// The double-tap rule lives in meterTargets: recording sources are never
    /// metered.
    func reconcileMeters() {
        guard metersOn else { meters.stopAll(); return }
        let rows = (appSources + micSources + tabSources)
        let sources = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        meters.reconcile(targets: meterTargets(rowIDs: rows.map(\.id),
                                               windowVisible: metersOn,
                                               recordingSourceIDs: engine.recordingSourceIDs),
                         sources: sources)
    }

    func refreshSources() {
        appSources = registry.currentAppSources()
        micSources = registry.currentMicSources()
        refreshTabSources()
        // New rows need meter chains started; gone rows need theirs stopped.
        reconcileMeters()
    }

    /// Refresh tab sources. PoC: one static "Chrome Tab" row — selecting it
    /// makes startSession() spin up a TabCaptureSession whose TCP server the
    /// extension's native host connects to once the user clicks Start Capture.
    func refreshTabSources() {
        if settings.tabCaptureEnabled {
            tabSources = [SourceDescriptor(id: "tab-chrome-0",
                                           kind: .tabCapture,
                                           name: "Chrome Tab",
                                           bundleIdentifier: nil,
                                           deviceUID: nil)]
        } else {
            tabSources = []
        }
        reconcileMeters()
    }

    func toggleSource(_ id: String) {
        if case .recording = engine.state {
            // Live mid-session mutation: tick starts a real stem, un-tick ends
            // it (its onEnded lands on main; stemEnded frees tap + un-tracks).
            if selectedSourceIDs.contains(id) {
                engine.removeSource(id: id)
                selectedSourceIDs.remove(id)
            } else if let source = (appSources + micSources + tabSources).first(where: { $0.id == id }) {
                do {
                    try engine.addSource(source)
                    selectedSourceIDs.insert(id)
                } catch {
                    lastError = error.localizedDescription
                }
            }
        } else {
            // Idle path: pure selection — startRecording uses it later.
            if selectedSourceIDs.contains(id) { selectedSourceIDs.remove(id) }
            else { selectedSourceIDs.insert(id) }
        }
        reconcileMeters()
    }

    /// Toggle mute for a source. During recording, stops the chain and records
    /// the muted state; unmute restores the chain. Idle: toggles selection.
    func toggleMute(_ id: String) {
        if case .recording = engine.state {
            if mutedSourceIDs.contains(id) {
                // Unmute: restore the chain.
                mutedSourceIDs.remove(id)
                if let source = (appSources + micSources + tabSources).first(where: { $0.id == id }) {
                    selectedSourceIDs.insert(id)
                    do {
                        try engine.addSource(source)
                    } catch {
                        lastError = error.localizedDescription
                    }
                }
            } else {
                // Mute: stop and remove the chain.
                mutedSourceIDs.insert(id)
                engine.removeSource(id: id)
                selectedSourceIDs.remove(id)
            }
            reconcileMeters()
        } else {
            // Idle: just toggle selection (same as toggleSource).
            toggleSource(id)
        }
    }

    func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            permissionDenied = false
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permissionDenied = !granted
                    done(granted)
                }
            }
        default:
            permissionDenied = true
            done(false)
        }
    }

    func startRecording() {
        lastError = nil
        let sources = selectedSources
        guard !sources.isEmpty else { return }
        requestMicPermission { [weak self] granted in
            guard let self, granted else { return }
            do {
                try self.engine.startSession(sources: sources, format: self.settings.stemFormat,
                                             store: self.store)
            } catch {
                // Surface start failures (low disk, device errors) instead of
                // swallowing them: the message is shown under the controls bar.
                self.lastError = error.localizedDescription
            }
        }
    }

    func stopRecording() {
        engine.stopSession()
        // Auto-navigate to Sessions so the user sees the saved recording.
        activeTab = 1
    }
}

