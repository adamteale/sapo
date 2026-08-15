import Foundation
import Combine
import CoreAudio

/// Pure coordination: which row ids get meter taps right now.
/// The double-tap rule lives here — recording sources are never metered.
func meterTargets(rowIDs: [String], windowVisible: Bool, recordingSourceIDs: Set<String>) -> Set<String> {
    guard windowVisible else { return [] }
    return Set(rowIDs).subtracting(recordingSourceIDs)
}

/// Owns the live meter chains for the visible, non-recording rows.
/// Reconcile is idempotent — callers (AppModel) just pass the desired
/// target set each time the window/session changes.
@MainActor
final class MeterManager: ObservableObject {
    @Published private(set) var meterLevels: [String: Float] = [:]
    private var chains: [String: MeterChain] = [:]
    private let registry = SourceRegistry()

    /// Idempotent: start meter chains for added targets, stop for removed.
    /// Sources whose chain fails to start (app quit between enumerate and
    /// resolve) are simply absent — no error surfaced; the row sits flat.
    func reconcile(targets: Set<String>, sources: [String: SourceDescriptor]) {
        for (id, chain) in chains where !targets.contains(id) {
            chain.stop()
            chains[id] = nil
            meterLevels[id] = nil
        }
        for id in targets where chains[id] == nil {
            guard let source = sources[id],
                  let resolved = SourceResolver.resolve(source: source, registry: registry),
                  let chain = try? MeterChain.make(deviceID: resolved.deviceID,
                                                   scope: kAudioObjectPropertyScopeInput,
                                                   tap: resolved.tap) else { continue }
            chain.onLevel = { [weak self] level in self?.meterLevels[id] = level }
            do { try chain.start(); chains[id] = chain }
            catch { chain.stop() }
        }
    }

    func stopAll() { reconcile(targets: [], sources: [:]) }
}
