import Foundation
import Testing
@testable import Sapo

@Suite("SessionStore") struct SessionStoreTests {
    func makeStore() throws -> (SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stems-tests-\(UUID().uuidString)")
        return (SessionStore(rootURL: root), root)
    }

    @Test func manifestRoundTrip() throws {
        let (store, _) = try makeStore()
        let mic = SourceDescriptor(id: "MicUID", kind: .microphone, name: "MacBook Microphone",
                                   bundleIdentifier: nil, deviceUID: "MicUID")
        var manifest = SessionManifest(
            identifier: UUID(), title: "Session 2026-08-15 10.00.00",
            startTime: Date(timeIntervalSince1970: 1_800_000_000), endTime: nil,
            stemFormat: .alac,
            stems: [StemRecord(source: mic, fileName: "stem-1.caf", sampleRate: 48_000,
                               channelCount: 1, startTime: Date(timeIntervalSince1970: 1_800_000_000),
                               endTime: nil, endEvent: nil)],
            appVersion: "0.1.0"
        )
        let folder = try store.makeSessionFolder(start: manifest.startTime)
        try store.save(manifest, to: folder)
        let loaded = try store.loadManifest(at: folder)
        #expect(loaded == manifest)

        // finalize: partial session gets an endTime and end event
        manifest.endTime = Date(timeIntervalSince1970: 1_800_0_600)
        manifest.stems[0].endTime = manifest.endTime
        manifest.stems[0].endEvent = "sessionEnd"
        try store.save(manifest, to: folder)
        #expect(try store.loadManifest(at: folder) == manifest)
    }

    @Test func sessionsListNewestFirstAndSorted() throws {
        let (store, _) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in [0, 3600, 7200] {
            let folder = try store.makeSessionFolder(start: base.addingTimeInterval(TimeInterval(offset)))
            let manifest = SessionManifest(identifier: UUID(), title: "t", startTime: base.addingTimeInterval(TimeInterval(offset)),
                                           endTime: nil, stemFormat: .wav, stems: [], appVersion: "0")
            try store.save(manifest, to: folder)
        }
        let sessions = store.listSessions()
        #expect(sessions.count == 3)
        #expect(sessions.map(\.manifest.startTime) == sessions.map(\.manifest.startTime).sorted(by: >))
    }

    @Test func deleteStemsKeepsManifest() throws {
        let (store, root) = try makeStore()
        let folder = try store.makeSessionFolder(start: Date())
        try "fake-stem".write(to: folder.appendingPathComponent("stem-1.caf"), atomically: true, encoding: .utf8)
        let manifest = SessionManifest(identifier: UUID(), title: "t", startTime: Date(),
                                       endTime: nil, stemFormat: .alac,
                                       stems: [StemRecord(source: SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: "a", deviceUID: nil),
                                                          fileName: "stem-1.caf", sampleRate: 48_000, channelCount: 2,
                                                          startTime: Date(), endTime: nil, endEvent: nil)],
                                       appVersion: "0")
        try store.save(manifest, to: folder)
        #expect(store.diskUsage(of: folder) > 0)
        try store.deleteStems(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stem-1.caf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        _ = root
    }

    @Test func foldersWithoutManifestAreIgnored() throws {
        let (store, _) = try makeStore()
        let folder = try store.makeSessionFolder(start: Date())
        try "junk".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        #expect(store.listSessions().isEmpty)
    }

    @Test func deleteOldSessionsRemovesOnlyOldOnes() throws {
        let (store, _) = try makeStore()
        let now = Date()

        // Create a recent session (1 day old)
        let recentDate = now.addingTimeInterval(-86_400)
        let recentFolder = try store.makeSessionFolder(start: recentDate)
        let recentManifest = SessionManifest(identifier: UUID(), title: "Recent",
                                             startTime: recentDate, endTime: nil,
                                             stemFormat: .wav, stems: [], appVersion: "0")
        try store.save(recentManifest, to: recentFolder)

        // Create an old session (60 days old)
        let oldDate = now.addingTimeInterval(-86_400 * 60)
        let oldFolder = try store.makeSessionFolder(start: oldDate)
        // Write a small file to give it size
        try "old-data".write(to: oldFolder.appendingPathComponent("stem-1.caf"), atomically: true, encoding: .utf8)
        let oldManifest = SessionManifest(identifier: UUID(), title: "Old",
                                          startTime: oldDate, endTime: nil,
                                          stemFormat: .wav, stems: [], appVersion: "0")
        try store.save(oldManifest, to: oldFolder)

        // Cleanup with 30-day threshold should only remove the old session.
        let result = try store.deleteOldSessions(maxAgeDays: 30)
        #expect(result.count == 1)
        #expect(result.bytesFreed > 0)
        // Recent session should still exist.
        let sessions = store.listSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].manifest.title == "Recent")
    }
}
