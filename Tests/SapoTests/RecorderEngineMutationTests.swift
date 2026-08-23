import Foundation
import Testing
@testable import Sapo

@Suite("RecorderEngine mutation") struct RecorderEngineMutationTests {
    @Test func startSessionThrowsForAllUnresolvableSources() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-m-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let engine = RecorderEngine()
        // All sources unresolvable → throws unresolvedSources, no folder created.
        let fakeApp = SourceDescriptor(id: "no.such.app", kind: .application, name: "Ghost", bundleIdentifier: "no.such.app", deviceUID: nil)
        #expect(throws: SessionStartError.self) { try engine.startSession(sources: [fakeApp], format: .alac, store: store) }
        #expect(engine.state == .idle)

        // No session folder created, no debris left.
        let sessions = store.listSessions()
        #expect(sessions.isEmpty)
    }

    @Test func addSourceThrowsWhenIdle() {
        let engine = RecorderEngine()
        #expect(throws: EngineMutationError.self) {
            try engine.addSource(SourceDescriptor(id: "x", kind: .microphone, name: "X", bundleIdentifier: nil, deviceUID: "no-such-uid"))
        }
    }

    // NOTE: addSource for unresolvable sources can't be unit-tested without
    // live audio hardware (need a real mic to start a session first, then add
    // a ghost source). That path is verified via the manual test checklist on
    // the live-audio path. The addSource code path for unresolvable sources
    // throws EngineMutationError.unresolvableSource — same mechanism as
    // startSession's SessionStartError.unresolvedSources, just a different
    // error type since it's a mid-session mutation.
}
