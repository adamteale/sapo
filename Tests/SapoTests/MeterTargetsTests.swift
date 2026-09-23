import Testing
@testable import Sapo

@Suite("meterTargets") struct MeterTargetsTests {
    private func app(_ id: String) -> SourceDescriptor {
        SourceDescriptor(id: id, kind: .application, name: id,
                         bundleIdentifier: "com.example.\(id)", deviceUID: nil)
    }
    private func mic(_ id: String, uid: String) -> SourceDescriptor {
        SourceDescriptor(id: id, kind: .microphone, name: id,
                         bundleIdentifier: nil, deviceUID: uid)
    }
    private func tab(_ id: String) -> SourceDescriptor {
        SourceDescriptor(id: id, kind: .tabCapture, name: id,
                         bundleIdentifier: nil, deviceUID: nil)
    }

    @Test func windowClosedMeansNoTargets() {
        #expect(meterTargets(sources: [app("a")], windowVisible: false,
                             recordingSourceIDs: [], idleMetersEnabled: true) == [])
    }

    /// Idle meter taps are opt-in: disabled by default so launching the app
    /// never reroutes other apps' audio uninvited.
    @Test func idleMetersDisabledMeansNoTargets() {
        #expect(meterTargets(sources: [app("a")], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: false) == [])
    }

    @Test func appRowsBecomeTargetsWhenEnabled() {
        #expect(meterTargets(sources: [app("a"), app("b")], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: true) == ["a", "b"])
    }

    @Test func recordingAppsAreSubtracted() {
        #expect(meterTargets(sources: [app("a"), app("b")], windowVisible: true,
                             recordingSourceIDs: ["b"], idleMetersEnabled: true) == ["a"])
    }

    /// Holding a mic open just for an idle level bar forces Bluetooth headsets
    /// into HFP (16 kHz mono) — degrading ALL system audio. Mic rows must never
    /// be idle-metered, no matter what the setting says.
    @Test func micsAreNeverIdleMetered() {
        #expect(meterTargets(sources: [app("a"), mic("m", uid: "bt-0")], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: true) == ["a"])
    }

    /// Mic rows meter only while actually recording (engine chains feed those
    /// levels — not meter targets).
    @Test func tabsAreNeverIdleMetered() {
        #expect(meterTargets(sources: [app("a"), tab("t-1")], windowVisible: true,
                             recordingSourceIDs: [], idleMetersEnabled: true) == ["a"])
    }
}
