import Foundation
import Combine
import AVFoundation
import AppKit

/// Minimal settings holder; Task 12 expands into a persisted SettingsStore.
final class SettingsStore: ObservableObject {
    @Published var stemFormat: StemFormat = .alac
}

@MainActor
final class AppModel: ObservableObject {
    let engine = RecorderEngine()
    let store = SessionStore()
    let settings = SettingsStore()

    @Published var appSources: [SourceDescriptor] = []
    @Published var micSources: [SourceDescriptor] = []
    @Published var selectedSourceIDs: Set<String> = []
    @Published var permissionDenied = false

    private let registry = SourceRegistry()

    var selectedSources: [SourceDescriptor] {
        (appSources + micSources).filter { selectedSourceIDs.contains($0.id) }
    }

    /// WAV: rate × channels × 2 bytes; ALAC ≈ 50% of WAV.
    var estimatedBytesPerHour: Int64 {
        let channelsAvg = 2.0
        let wavBytesPerSecond = 48_000.0 * channelsAvg * 2
        let factor = settings.stemFormat == .alac ? 0.5 : 1.0
        return Int64(Double(selectedSourceIDs.count) * wavBytesPerSecond * factor * 3600)
    }

    func refreshSources() {
        appSources = registry.currentAppSources()
        micSources = registry.currentMicSources()
    }

    func toggleSource(_ id: String) {
        if selectedSourceIDs.contains(id) { selectedSourceIDs.remove(id) }
        else { selectedSourceIDs.insert(id) }
    }

    func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
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
        let sources = selectedSources
        guard !sources.isEmpty else { return }
        requestMicPermission { [weak self] granted in
            guard let self, granted else { return }
            try? self.engine.startSession(sources: sources, format: self.settings.stemFormat,
                                          store: self.store)
        }
    }

    func stopRecording() {
        engine.stopSession()
    }
}
