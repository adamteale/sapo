import Foundation
import Combine
import AppKit
import CoreAudio

enum RecordState: Equatable {
    case idle
    case recording(startedAt: Date)
}

enum SessionStartError: Error, Equatable {
    /// Not enough free disk space on the session volume for a recording of the
    /// estimated size. `available` is the volume's current free space;
    /// `needed` is the greater of the caller's `minimumFreeBytes` and the
    /// 2-hour session estimate.
    case lowDisk(available: Int64, needed: Int64)
}

extension SessionStartError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .lowDisk(let available, let needed):
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            return "Not enough free disk space: \(fmt.string(fromByteCount: available)) free, "
                 + "but recording needs at least \(fmt.string(fromByteCount: needed))."
        }
    }
}

enum EngineMutationError: LocalizedError {
    case notRecording
    case unresolvableSource(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: return "No recording session is running."
        case .unresolvableSource(let name):
            return "\(name) isn’t producing audio right now — start audio in it and try again."
        }
    }
}

/// Orchestrates one recording session: builds one CaptureChain per source,
/// persists the manifest at session start (crash-safe: all stems open,
/// `endTime: nil`), updates it as each stem ends, and tears everything down
/// on stop.
///
/// Lifetime contract (controller ruling 2): every chain stays retained in
/// `self.chains` until stop clears them — CaptureChain's IOProc holds
/// `Unmanaged.passUnretained(self)`, so dropping a chain while its IOProc is
/// still registered would dangle. Teardown is asynchronous (serial queue in
/// CaptureChain), but the enqueued teardown blocks capture the chain strongly,
/// so chains stay alive until each one has actually stopped; `onEnded`
/// callbacks may still reference a chain after stop and that is safe.
final class RecorderEngine: ObservableObject {
    @Published private(set) var state: RecordState = .idle
    @Published private(set) var levels: [String: Float] = [:]
    @Published private(set) var activeSessionFolder: URL?

    private var chains: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?, fileName: String)] = []
    private var manifest: SessionManifest?
    private var store: SessionStore?
    private var workspaceObserver: NSObjectProtocol?
    /// Shared with addSource: mid-session mutation must resolve against the
    /// same process/device snapshot registry that started the session.
    private let registry = SourceRegistry()

    static func stemFileName(for source: SourceDescriptor, index: Int, format: StemFormat = .alac) -> String {
        let ext = format == .alac ? "caf" : "wav"
        let clean = source.name.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "stem-\(index)-\(clean).\(ext)"
    }

    /// Pure function: the manifest skeleton written at session start. Sample
    /// rate / channel count are placeholders here — `startSession` overwrites
    /// them with each chain's real input format before the first save.
    static func initialManifest(title: String, sources: [SourceDescriptor], format: StemFormat, folder: URL) -> SessionManifest {
        SessionManifest(
            identifier: UUID(),
            title: folder.lastPathComponent,
            startTime: Date(),
            endTime: nil,
            stemFormat: format,
            stems: sources.enumerated().map { i, source in
                StemRecord(source: source,
                           fileName: stemFileName(for: source, index: i, format: format),
                           sampleRate: 48_000,   // placeholder; corrected after chain creation
                           channelCount: source.kind == .microphone ? 1 : 2,
                           startTime: Date(), endTime: nil, endEvent: nil)
            },
            appVersion: "0.1.0")
    }

    /// Rough 2-hour session size in bytes: bytes/sec per source × 7200s, ALAC
    /// ≈ 50% of WAV (heuristic for the low-disk pre-flight, not a billing
    /// meter). Matches `AppModel.estimatedBytesPerHour`'s math at ×2 hours.
    static func estimatedSessionBytes(sources: [SourceDescriptor], format: StemFormat) -> Int64 {
        let wavBytesPerSecond = 48_000.0 * 2.0 * 2.0 // rate × channels × 2 bytes
        let factor = format == .alac ? 0.5 : 1.0
        return Int64(Double(sources.count) * wavBytesPerSecond * 7200.0 * factor)
    }

    func startSession(sources: [SourceDescriptor], format: StemFormat, store: SessionStore,
                      minimumFreeBytes: Int64? = nil) throws {
        guard case .idle = state else { return }
        guard !sources.isEmpty else { return }

        // Low-disk pre-flight: checked BEFORE any folder or capture chain is
        // created, so a failed start leaves no trace behind. Reads the volume's
        // important-usage capacity off the store root (the volume sessions are
        // written to); if the capacity can't be read we proceed — the check is
        // best-effort, not a failure path.
        let threshold = max(minimumFreeBytes ?? 0, Self.estimatedSessionBytes(sources: sources, format: format))
        if threshold > 0 {
            let capacity = try? store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < threshold {
                throw SessionStartError.lowDisk(available: capacity, needed: threshold)
            }
        }

        let folder = try store.makeSessionFolder(start: Date())
        var manifest = Self.initialManifest(title: folder.lastPathComponent, sources: sources,
                                            format: format, folder: folder)

        var built: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?, fileName: String)] = []
        do {
            for (index, source) in sources.enumerated() {
                let fileName = manifest.stems[index].fileName
                let stemURL = folder.appendingPathComponent(fileName)

                // Shared resolution: app not making audio / device absent →
                // skipped stem (pruned from the manifest below).
                guard let resolved = SourceResolver.resolve(source: source, registry: registry) else { continue }
                let deviceID = resolved.deviceID
                let tap = resolved.tap

                let chain = try CaptureChain.make(deviceID: deviceID,
                                                  scope: kAudioObjectPropertyScopeInput,
                                                  stemURL: stemURL, format: format)
                let sourceID = source.id
                chain.onLevel = { [weak self] level in self?.levels[sourceID] = level }
                chain.onEnded = { [weak self] reason in
                    // CaptureChain fires onEnded on the main queue (documented
                    // contract in its teardown path), so the main-actor hop is
                    // a pure assertion, not a re-dispatch.
                    MainActor.assumeIsolated { self?.stemEnded(sourceID: sourceID, reason: reason) }
                }
                built.append((source, chain, tap, fileName))
            }
        } catch {
            for item in built { item.chain.stop(reason: "startupFailed") }
            for var tap in built.compactMap(\.tap) { tap.dispose() }
            throw error
        }

        // prune stems whose sources produced no chain (not playing / no device)
        manifest.stems = manifest.stems.filter { stem in built.contains { $0.source.id == stem.source.id } }

        // Ruling 1: real input-stream metadata from each chain, BEFORE the
        // first manifest save (the crash-safe start manifest).
        for i in manifest.stems.indices {
            guard let item = built.first(where: { $0.source.id == manifest.stems[i].source.id }) else { continue }
            manifest.stems[i].sampleRate = item.chain.clientFormat.mSampleRate
            manifest.stems[i].channelCount = Int(item.chain.clientFormat.mChannelsPerFrame)
        }
        try store.save(manifest, to: folder)

        self.store = store
        self.manifest = manifest
        self.chains = built
        self.activeSessionFolder = folder
        self.levels = [:]

        // Partial-start failure guard: chains 0..k-1 may already be running
        // with live IOProcs writing stems; the k-th chain's start() rolls back
        // its own writer/hardware before throwing, but the ones before it do
        // not. Roll everything back and clear ALL engine state so a retry
        // starts from a clean slate — otherwise the manifest on disk
        // advertises an open session while the engine sits in .idle with
        // non-nil store/manifest/chains/activeSessionFolder (the allSatisfy
        // auto-stop can never fire, and a retry would abandon running chains
        // by overwriting self.chains).
        do {
            for item in built { try item.chain.start() }
        } catch {
            for item in built { item.chain.stop(reason: "startupFailed") }
            for var tap in built.compactMap(\.tap) { tap.dispose() }
            if let observer = workspaceObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            workspaceObserver = nil
            self.chains = []
            self.levels = [:]
            self.manifest = nil
            self.store = nil
            self.activeSessionFolder = nil
            if FileManager.default.fileExists(atPath: folder.path) {
                do {
                    try FileManager.default.removeItem(at: folder)
                } catch {
                    try? store.deleteStems(in: folder) // best-effort fallback
                }
            }
            throw error
        }

        observeAppTermination()

        state = .recording(startedAt: manifest.startTime)
    }

    private func observeAppTermination() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for item in self.chains {
                // Require a real bundle identifier on BOTH sides: with a plain
                // `==`, a bundle-less termination (nil bundleIdentifier) would
                // match every source whose bundleIdentifier is also nil.
                guard let sourceBundle = item.source.bundleIdentifier,
                      sourceBundle == app.bundleIdentifier else { continue }
                item.chain.stop(reason: "processExited")
            }
        }
    }

    /// Runs on main: onEnded is delivered on the main queue (CaptureChain
    /// contract). Ends one stem in the manifest, frees the tap and un-tracks
    /// the chain, then auto-stops the whole session once every stem has ended.
    @MainActor
    private func stemEnded(sourceID: String, reason: String) {
        guard var manifest = self.manifest, let store = self.store else { return }
        levels[sourceID] = nil
        if let idx = manifest.stems.firstIndex(where: { $0.source.id == sourceID }) {
            manifest.stems[idx].endTime = Date()
            manifest.stems[idx].endEvent = reason
            try? store.save(manifest, to: activeSessionFolder!)
        } else {
            // No manifest stem matched this chain: it was a mid-session add
            // whose manifest save failed (the on-disk manifest never gained a
            // stem for it). The stem file the chain created is orphaned —
            // unreferenced by the manifest — so delete it here. Safe: onEnded
            // fires only after the serial teardown block closed the writer, so
            // the file handle is released before the unlink. The chain entry is
            // still tracked (addSource appends it before the save), so its
            // fileName is available for the deletion; the removal block below
            // then un-tracks the entry.
            if let folder = activeSessionFolder,
               let chainIdx = chains.firstIndex(where: { $0.source.id == sourceID }) {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(chains[chainIdx].fileName))
            }
        }
        self.manifest = manifest

        // Tap disposal lives here (Task 3): a mid-session removal must free the
        // tap while the session keeps recording, so the chain is disposed and
        // un-tracked as soon as its onEnded lands. This removal site is the
        // reentrancy-critical point in the teardown drain — reasoning:
        //
        // (a) A chain is only removed AFTER its own teardown completed: onEnded
        //     fires exactly-once from the serial teardown queue, after
        //     stopHardware() unregistered the IOProc and the queue block held
        //     the chain strongly. So if the auto-stop below (or a concurrent
        //     stopSession) later iterates `chains` and "misses" a chain that
        //     this block removed, that chain has already stopped itself — the
        //     miss cannot skip a chain that is still running.
        //
        // (b) No tap is double-disposed here: onEnded is exactly-once, so this
        //     block runs once per chain, and after removal the chain is gone
        //     from `chains` — stopSession's final dispose safety (below) and
        //     this block can each run at most once per tap. The only
        //     theoretical overlap (stopSession racing this block off-main)
        //     double-disposes, which ProcessTapSession.dispose tolerates — it
        //     returns an ignorable error at the HAL level.
        if let idx = chains.firstIndex(where: { $0.source.id == sourceID }) {
            chains[idx].tap?.dispose()
            chains.remove(at: idx)
        }
        // All stems ended → auto-stop session. Reentrant while this drain is
        // still unwinding: the chain above was already removed, so the nested
        // stopSession only sees the chains that are genuinely still running.
        if manifest.stems.allSatisfy({ $0.endTime != nil }) { stopSession() }
    }

    /// Live mutation: add a source to the running session, or throw.
    ///
    /// Ruling-3 deviation from the task brief: `chain.start()` runs BEFORE any
    /// state mutation (stem record, manifest save, chains append). The brief's
    /// order appended the StemRecord and saved the manifest first, which would
    /// persist a stem for a source whose start() then failed — debris in the
    /// manifest and on disk for a stem that never recorded a single frame.
    func addSource(_ source: SourceDescriptor) throws {
        guard case .recording = state, let store, let manifest, let folder = activeSessionFolder else {
            throw EngineMutationError.notRecording
        }
        guard var resolved = SourceResolver.resolve(source: source, registry: registry) else {
            throw EngineMutationError.unresolvableSource(source.name)
        }
        let sourceID = source.id
        let fileName = Self.stemFileName(for: source, index: manifest.stems.count, format: manifest.stemFormat)
        let chain: CaptureChain
        do {
            chain = try CaptureChain.make(deviceID: resolved.deviceID, scope: kAudioObjectPropertyScopeInput,
                                          stemURL: folder.appendingPathComponent(fileName), format: manifest.stemFormat)
        } catch {
            // make() failed after resolve() created the tap: don't leak it.
            resolved.tap?.dispose()
            // StemWriter.init created the stem file eagerly
            // (ExtAudioFileCreateWithURL), and the setClient-format failure
            // path only closes it — the file stays on disk. No chain exists to
            // fire onEnded, so stemEnded can never reclaim it: delete the
            // orphan here, directly.
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
            throw error
        }
        chain.onLevel = { [weak self] level in self?.levels[sourceID] = level }
        chain.onEnded = { [weak self] reason in
            MainActor.assumeIsolated { self?.stemEnded(sourceID: sourceID, reason: reason) }
        }
        do {
            try chain.start()
        } catch {
            // Mirror startSession's failure cleanup for this one chain. The
            // chain was never tracked, so nothing to remove from `chains`; the
            // async onEnded("startupFailed") that lands later finds no stem in
            // the manifest and no chain in `chains` (firstIndex guards) and is
            // a no-op. start() already closed the writer before throwing, so
            // the stem file it created is orphaned — and no chains entry exists
            // for stemEnded's orphan cleanup to find — delete the file here.
            chain.stop(reason: "startupFailed")
            resolved.tap?.dispose()
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
            throw error
        }
        var updated = manifest
        updated.stems.append(StemRecord(source: source, fileName: fileName,
                                        sampleRate: chain.clientFormat.mSampleRate,
                                        channelCount: Int(chain.clientFormat.mChannelsPerFrame),
                                        startTime: Date(), endTime: nil, endEvent: nil))
        // Track the chain BEFORE persisting: if the save below throws, the
        // chain must already be reachable so the drain can reclaim it (the
        // async onEnded lands in stemEnded's failed-add branch, which deletes
        // the orphaned file, disposes the tap and un-tracks the chain). If it
        // were untracked, nothing would retain it while its IOProc is
        // registered — the IOProc holds the chain unretained, so it would
        // dangle on deallocation.
        //
        // Residual, accepted: if onEnded never fires for a failed-add chain,
        // its stem file could sit orphaned — unreachable in practice, because
        // every addSource failure path below either deletes the file directly
        // or drives stop() (which always enqueues onEnded), and stopSession's
        // dispose loop reclaims any leftover chains entry on session end.
        chains.append((source, chain, resolved.tap, fileName))
        do {
            try store.save(updated, to: folder)
            self.manifest = updated
        } catch {
            // Save failed after start succeeded: stop the chain, dispose the
            // tap, and delete the orphaned stem file DIRECTLY (deterministic —
            // don't rely on the async onEnded landing). The chains entry is
            // removed synchronously too (ruling, Task 4 pre-step): if it were
            // left tracked, a stale onEnded("startupFailed") landing later
            // would find a RE-ADDED chain with the same source id in
            // stemEnded's failed-add branch and delete THAT chain's stem file
            // (and dispose its tap) — removing the entry here closes that
            // window. The chain stays alive after removal: stop() enqueues a
            // teardown block that captures it strongly until the IOProc is
            // unregistered. No manifest debris: the on-disk manifest never
            // gained the stem (the save failed before the in-memory manifest
            // was updated).
            chain.stop(reason: "startupFailed")
            resolved.tap?.dispose()
            chains.removeAll { $0.source.id == sourceID }
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(fileName))
            throw error
        }
    }

    /// Live mutation: stop and remove a source from the running session.
    /// Safe when called twice or for an unknown id (the lookup guard returns
    /// without doing anything). Teardown is async: the chain's onEnded
    /// ("userRemoved") lands on main and stemEnded frees the tap and un-tracks
    /// the chain.
    func removeSource(id: String) {
        guard let item = chains.first(where: { $0.source.id == id }) else { return }
        item.chain.stop(reason: "userRemoved")
    }

    /// Sources currently producing stems in the active session.
    var recordingSourceIDs: Set<String> { Set(chains.map(\.source.id)) }

    func stopSession() {
        guard case .recording = state else { return }
        for item in chains { item.chain.stop(reason: "sessionEnd") }
        // Deliberately KEPT (deviation from the brief, per controller ruling 1):
        // the brief drops this loop on the assumption that each chain's
        // onEnded("sessionEnd") callback removes it in stemEnded — but on this
        // all-main path stopSession nil's out store/manifest/chains
        // synchronously, so by the time the async onEnded blocks land,
        // stemEnded early-returns at its guard and the taps would never be
        // disposed. This idempotent safety frees them; chains removed earlier
        // by stemEnded (mid-session removals) are no longer in the array, and
        // dispose() is idempotent at the HAL level.
        for var tap in chains.compactMap(\.tap) { tap.dispose() }
        if var manifest = self.manifest, let store = self.store {
            manifest.endTime = Date()
            for i in manifest.stems.indices where manifest.stems[i].endTime == nil {
                manifest.stems[i].endTime = manifest.endTime
                manifest.stems[i].endEvent = "sessionEnd"
            }
            try? store.save(manifest, to: activeSessionFolder!)
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObserver = nil
        chains = []
        levels = [:]
        manifest = nil
        store = nil
        activeSessionFolder = nil
        state = .idle
    }
}
