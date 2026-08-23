import Foundation
import Testing
@testable import Sapo

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
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.sapomac.Sapo", processName: "Sapo"),
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "us.zoom.xos", processName: "zoom.us"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: ["com.sapomac.Sapo"])
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

@Suite("App bundle-path grouping") struct AppBundlePathGroupingTests {
    @Test func chromiumHelpersFoldIntoParentRow() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.brave.Browser",
                                 processName: "Brave Browser", appBundlePath: "/Applications/Brave Browser.app"),
            // Chromium helpers are nested .app bundles inside the parent's Frameworks folder.
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "com.brave.Browser.helper",
                                 processName: "helper", appBundlePath: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/151.1.93.136/Helpers/Brave Browser Helper.app"),
            // Some helpers have no NSRunningApplication record at all (nil path) —
            // they fold in via the bundle-prefix pass.
            AudioProcessSnapshot(objectID: 3, pid: 102, bundleID: "com.brave.Browser.helper",
                                 processName: "helper", appBundlePath: nil),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 1)
        #expect(sources[0].id == "com.brave.Browser")           // parent bundle id wins
        #expect(sources[0].name == "Brave Browser")             // parent display name wins
        #expect(sources[0].appBundlePath == "/Applications/Brave Browser.app")
    }

    @Test func helperAloneStillListedWithParentPath() {
        // Parent not producing audio; only the helper appears.
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 101, bundleID: "com.brave.Browser.helper",
                                 processName: "helper", appBundlePath: "/Applications/Brave Browser.app"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 1)
        #expect(sources[0].appBundlePath == "/Applications/Brave Browser.app")
    }

    @Test func distinctAppsOnDifferentPathsStaySeparate() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.brave.Browser",
                                 processName: "Brave Browser", appBundlePath: "/Applications/Brave Browser.app"),
            AudioProcessSnapshot(objectID: 2, pid: 200, bundleID: "us.zoom.xos",
                                 processName: "zoom.us", appBundlePath: "/Applications/zoom.us.app"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).count == 2)
    }

    @Test func pathlessProcessesFallBackToBundleGrouping() {
        // Old behavior preserved for processes without an .app path (system daemons).
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.apple.PowerChime",
                                 processName: "PowerChime", appBundlePath: nil),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 1)
        #expect(sources[0].id == "com.apple.PowerChime")
        #expect(sources[0].appBundlePath == nil)
    }
}

@Suite("WebKit GPU labeling") struct WebKitGPULabelTests {
    @Test func webkitGPURowGetsSharedAudioHint() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 300, bundleID: "com.apple.WebKit.GPU",
                                 processName: "Ollama Graphics and Media", appBundlePath: nil),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 1)
        #expect(sources[0].name.contains("Ollama Graphics and Media"))
        #expect(sources[0].name.contains("shared Safari/WebKit audio"))
    }

    @Test func ordinaryAppsGetNoHint() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "us.zoom.xos",
                                 processName: "zoom.us", appBundlePath: "/Applications/zoom.us.app"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).first?.name == "zoom.us")
    }
}
