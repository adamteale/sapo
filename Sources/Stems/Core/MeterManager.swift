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
                  let resolved = SourceResolver.resolve(source: source, registry: registry) else { continue }
            // MeterChain.make transfers tap ownership only on success; if it
            // throws (no input stream format), dispose the tap here or it
            // leaks for the process lifetime (struct — no deinit cleanup).
            var tap = resolved.tap
            guard let chain = try? MeterChain.make(deviceID: resolved.deviceID,
                                                   scope: kAudioObjectPropertyScopeInput,
                                                   tap: tap) else {
                tap?.dispose()
                continue
            }
            // MeterChain delivers onLevel on main (documented producer-side), so
            // this main-actor write needs no hop. The chains-dict guard is
            // decisive against stale writes: stop() is async, but chains[id] = nil
            // is synchronous on main (reconcile is @MainActor), so onLevel blocks
            // enqueued before removal run after it (FIFO main queue) and see nil —
            // dropped instead of re-inserting a dead id into meterLevels.
            chain.onLevel = { [weak self] level in
                guard let self, self.chains[id] != nil else { return }
                self.meterLevels[id] = level
            }
            do { try chain.start(); chains[id] = chain }
            catch { chain.stop() }
        }
    }

    func stopAll() { reconcile(targets: [], sources: [:]) }
}
