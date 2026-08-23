import Foundation
import Testing
@testable import Sapo

@Suite("SourceRegistry naming") struct SourceNamingTests {
    @Test func shorterProcessNameWinsAsDisplayName() {
        // The grouping helper prefers the shortest process name (the app itself,
        // not its helpers).
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 1, bundleID: "com.google.Chrome", processName: "Google Chrome Helper (Renderer)"),
            AudioProcessSnapshot(objectID: 2, pid: 2, bundleID: "com.google.Chrome", processName: "Google Chrome"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).first?.name == "Google Chrome")
    }
}
