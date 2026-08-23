import Foundation
import Testing
@testable import Sapo

@Suite("RecorderEngine mutation") struct RecorderEngineMutationTests {
    @Test func addSourceThrowsWhenIdle() {
        let engine = RecorderEngine()
        #expect(throws: EngineMutationError.self) {
            try engine.addSource(SourceDescriptor(id: "x", kind: .microphone, name: "X", bundleIdentifier: nil, deviceUID: "no-such-uid"))
        }
    }

    @Test func addSourceThrowsAndLeavesNoDebrisWhenUnresolvable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-m-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let engine = RecorderEngine()
        // A fake app source resolves to no process objects → zero-stem session.
        let fakeApp = SourceDescriptor(id: "no.such.app", kind: .application, name: "Ghost", bundleIdentifier: "no.such.app", deviceUID: nil)
        try engine.startSession(sources: [fakeApp], format: .alac, store: store)
        defer { engine.stopSession() }
        #expect(engine.recordingSourceIDs.isEmpty)

        let ghostMic = SourceDescriptor(id: "no-such-uid", kind: .microphone, name: "Ghost Mic", bundleIdentifier: nil, deviceUID: "no-such-uid")
        #expect(throws: EngineMutationError.self) { try engine.addSource(ghostMic) }

        // No stem added, no files created, manifest unchanged.
        let sessions = store.listSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].manifest.stems.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions[0].folderURL.path)
        #expect(files.filter { $0 != "manifest.json" }.isEmpty)

        // Debris for RESOLVABLE-but-failed adds (CaptureChain.make / chain.start /
        // manifest-save failures) can't be unit-tested — triggering them needs
        // live audio hardware (a real tap device or an input device that fails to
        // start). That coverage is: addSource deletes the orphaned stem file
        // directly in each failure catch, and stemEnded's failed-add branch
        // (no manifest stem matches the sourceID) deletes it again as the async
        // onEnded lands — verified via the manual test checklist on the
        // live-audio path.
    }
}
