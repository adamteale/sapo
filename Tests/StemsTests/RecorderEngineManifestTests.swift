import Foundation
import Testing
@testable import Stems

@Suite("RecorderEngine helpers") struct RecorderEngineManifestTests {
    @Test func stemFileNamesSanitizedAndIndexed() {
        let chrome = SourceDescriptor(id: "com.google.Chrome", kind: .application,
                                      name: "Google Chrome", bundleIdentifier: "com.google.Chrome", deviceUID: nil)
        #expect(RecorderEngine.stemFileName(for: chrome, index: 0) == "stem-0-Google Chrome.caf")
        #expect(RecorderEngine.stemFileName(for: chrome, index: 0, format: .wav) == "stem-0-Google Chrome.wav")
    }

    @Test func manifestPersistsAtStartWithOpenStems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-t-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let mic = SourceDescriptor(id: "u", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "u")
        let manifest = RecorderEngine.initialManifest(title: "T", sources: [mic], format: .alac,
                                                      folder: try store.makeSessionFolder(start: Date()))
        #expect(manifest.stems.allSatisfy { $0.endTime == nil })
        #expect(manifest.stemFormat == .alac)
    }

    @Test func lowDiskGuardThrowsBeforeCreatingAnything() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-t-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let mic = SourceDescriptor(id: "u", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "u")
        let engine = RecorderEngine()
        // minimumFreeBytes: .max forces the guard to trip regardless of real
        // volume capacity; the check must fire before any session folder or
        // capture chain exists.
        #expect(throws: SessionStartError.self) {
            try engine.startSession(sources: [mic], format: .alac, store: store,
                                    minimumFreeBytes: Int64.max)
        }
        #expect(store.listSessions().isEmpty) // nothing created, nothing left behind
    }
}
