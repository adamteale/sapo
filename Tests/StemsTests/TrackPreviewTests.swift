import Foundation
import Testing
@testable import Stems

@Suite("Sessions model helpers") struct TrackPreviewTests {
    @MainActor
    @Test func previewURLResolvesStemFile() {
        let folder = URL(fileURLWithPath: "/tmp/s1")
        let src = SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: "a", deviceUID: nil)
        let stem = StemRecord(source: src, fileName: "stem-0-A.caf", sampleRate: 48_000,
                              channelCount: 2, startTime: Date(), endTime: nil, endEvent: nil)
        #expect(SessionsModel.previewFileName(for: stem, in: folder).path == "/tmp/s1/stem-0-A.caf")
    }
}
