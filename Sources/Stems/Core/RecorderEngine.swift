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

    private var chains: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?)] = []
    private var manifest: SessionManifest?
    private var store: SessionStore?
    private var workspaceObserver: NSObjectProtocol?

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

        let registry = SourceRegistry()
        let folder = try store.makeSessionFolder(start: Date())
        var manifest = Self.initialManifest(title: folder.lastPathComponent, sources: sources,
                                            format: format, folder: folder)

        var built: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?)] = []
        do {
            for (index, source) in sources.enumerated() {
                let fileName = manifest.stems[index].fileName
                let stemURL = folder.appendingPathComponent(fileName)

                var tap: ProcessTapSession?
                let deviceID: AudioObjectID
                switch source.kind {
                case .application:
                    let objectIDs = registry.processObjectIDs(for: source)
                    guard !objectIDs.isEmpty else { continue } // app not making audio right now → skipped stem
                    var t = try ProcessTapSession.create(processObjectIDs: objectIDs, name: source.name)
                    deviceID = t.aggregateDeviceID
                    tap = t
                case .microphone:
                    guard let uid = source.deviceUID,
                          let id = registry.deviceID(forUID: uid) else { continue }
                    deviceID = id
                }

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
                built.append((source, chain, tap))
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
    /// contract). Ends one stem in the manifest, then auto-stops the whole
    /// session once every stem has ended.
    @MainActor
    private func stemEnded(sourceID: String, reason: String) {
        guard var manifest = self.manifest, let store = self.store else { return }
        levels[sourceID] = nil
        if let idx = manifest.stems.firstIndex(where: { $0.source.id == sourceID }) {
            manifest.stems[idx].endTime = Date()
            manifest.stems[idx].endEvent = reason
            try? store.save(manifest, to: activeSessionFolder!)
        }
        self.manifest = manifest
        // All stems ended → auto-stop session.
        if manifest.stems.allSatisfy({ $0.endTime != nil }) { stopSession() }
    }

    func stopSession() {
        guard case .recording = state else { return }
        for item in chains { item.chain.stop(reason: "sessionEnd") }
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
