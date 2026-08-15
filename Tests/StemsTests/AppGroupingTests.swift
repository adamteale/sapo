import Foundation
import Testing
@testable import Stems

@Suite("AppGrouping") struct AppGroupingTests {
    @Test func mergesHelperProcessesByBundleID() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.google.Chrome", processName: "Google Chrome"),
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "com.google.Chrome", processName: "Google Chrome Helper"),
            AudioProcessSnapshot(objectID: 3, pid: 200, bundleID: "us.zoom.xos", processName: "zoom.us"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 2)
        let chrome = sources.first { $0.bundleIdentifier == "com.google.Chrome" }
        #expect(chrome?.name == "Google Chrome")
        #expect(chrome?.id == "com.google.Chrome")
        #expect(chrome?.kind == .application)
    }

    @Test func excludesConfiguredBundleIDs() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.stemsapp.Stems", processName: "Stems"),
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "us.zoom.xos", processName: "zoom.us"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: ["com.stemsapp.Stems"])
        #expect(sources.map(\.bundleIdentifier) == ["us.zoom.xos"])
    }

    @Test func nilBundleIDFallsBackToPerProcessName() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 300, bundleID: nil, processName: "MysteryDaemon"),
            AudioProcessSnapshot(objectID: 2, pid: 301, bundleID: nil, processName: "MysteryDaemon"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        // No bundle ID: group by process name so user still gets one entry.
        #expect(sources.count == 1)
        #expect(sources[0].id == "pid:300") // deterministic id = first pid
        #expect(sources[0].name == "MysteryDaemon")
    }

    @Test func resultSortedByName() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 1, bundleID: "b.second", processName: "Zeta"),
            AudioProcessSnapshot(objectID: 2, pid: 2, bundleID: "a.first", processName: "Alpha"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).map(\.name) == ["Alpha", "Zeta"])
    }
}
