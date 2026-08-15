import Testing
@testable import Stems

@Suite("meterTargets") struct MeterTargetsTests {
    @Test func windowClosedMeansNoTargets() {
        #expect(meterTargets(rowIDs: ["a", "b"], windowVisible: false, recordingSourceIDs: []) == [])
    }
    @Test func subtractsRecordingSources() {
        #expect(meterTargets(rowIDs: ["a", "b", "c"], windowVisible: true, recordingSourceIDs: ["b"]) == ["a", "c"])
    }
    @Test func rowsNotListedAreNeverTargets() {
        #expect(meterTargets(rowIDs: ["a"], windowVisible: true, recordingSourceIDs: []) == ["a"])
        #expect(meterTargets(rowIDs: [], windowVisible: true, recordingSourceIDs: []) == [])
    }
}
