import Testing
@testable import Sapo

@Suite("meterTargets") struct MeterTargetsTests {
    @Test func windowClosedMeansNoTargets() {
        #expect(meterTargets(rowIDs: ["a", "b"], windowVisible: false,
                             recordingSourceIDs: [], idleMetersEnabled: true) == [])
    }
    @Test func subtractsRecordingSources() {
        #expect(meterTargets(rowIDs: ["a", "b", "c"], windowVisible: true,
                             recordingSourceIDs: ["b"], idleMetersEnabled: true) == ["a", "c"])
    }
    @Test func rowsNotListedAreNeverTargets() {
        #expect(meterTargets(rowIDs: ["a"], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: true) == ["a"])
        #expect(meterTargets(rowIDs: [], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: true) == [])
    }
    /// Idle meter taps are opt-in: disabled by default because every tap
    /// reroutes the tapped app's audio through an aggregate device (audible
    /// quality change) — meters are not worth degrading playback system-wide.
    @Test func idleMetersDisabledMeansNoTargets() {
        #expect(meterTargets(rowIDs: ["a", "b"], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: false) == [])
    }
}
