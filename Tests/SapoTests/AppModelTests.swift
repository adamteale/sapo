import Foundation
import Testing
@testable import Sapo

@MainActor
@Suite("AppModel selection state") struct AppModelSelectionTests {
    @Test func idleToggleAddsSource() {
        let model = AppModel.makeIdle()
        model.appSources = [
            SourceDescriptor(id: "com.app.a", kind: .application, name: "App A", bundleIdentifier: nil, deviceUID: nil),
            SourceDescriptor(id: "com.app.b", kind: .application, name: "App B", bundleIdentifier: nil, deviceUID: nil),
        ]
        model.micSources = [SourceDescriptor(id: "mic-1", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "mic-1")]

        model.toggleSource("com.app.a")
        #expect(model.selectedSourceIDs == ["com.app.a"])
    }

    @Test func idleToggleRemovesSource() {
        let model = AppModel.makeIdle()
        model.appSources = [SourceDescriptor(id: "com.app.a", kind: .application, name: "App A", bundleIdentifier: nil, deviceUID: nil)]
        model.selectedSourceIDs = ["com.app.a"]

        model.toggleSource("com.app.a")
        #expect(model.selectedSourceIDs == [])
    }

    @Test func idleToggleMultipleSources() {
        let model = AppModel.makeIdle()
        model.appSources = [
            SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: nil, deviceUID: nil),
            SourceDescriptor(id: "b", kind: .application, name: "B", bundleIdentifier: nil, deviceUID: nil),
            SourceDescriptor(id: "c", kind: .application, name: "C", bundleIdentifier: nil, deviceUID: nil),
        ]

        model.toggleSource("a")
        model.toggleSource("b")
        #expect(model.selectedSourceIDs == ["a", "b"])

        model.toggleSource("b")
        #expect(model.selectedSourceIDs == ["a"])
    }

    @Test func selectedSourcesFiltersCorrectly() {
        let model = AppModel.makeIdle()
        model.appSources = [
            SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: nil, deviceUID: nil),
            SourceDescriptor(id: "b", kind: .application, name: "B", bundleIdentifier: nil, deviceUID: nil),
        ]
        model.micSources = [SourceDescriptor(id: "mic-1", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "mic-1")]
        model.selectedSourceIDs = ["a", "mic-1"]

        let selected = model.selectedSources
        #expect(selected.count == 2)
        #expect(selected.allSatisfy { $0.id == "a" || $0.id == "mic-1" })
    }

    @Test func selectedSourcesEmptyWhenNothingSelected() {
        let model = AppModel.makeIdle()
        #expect(model.selectedSources.isEmpty)
    }

    @Test func estimatedBytesPerHourScalesWithSources() {
        let model = AppModel.makeIdle()
        model.appSources = [
            SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: nil, deviceUID: nil),
            SourceDescriptor(id: "b", kind: .application, name: "B", bundleIdentifier: nil, deviceUID: nil),
        ]
        model.micSources = [SourceDescriptor(id: "mic-1", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "mic-1")]
        model.selectedSourceIDs = ["a", "mic-1"]

        let bytes = model.estimatedBytesPerHour
        // 2 sources: 48000 × 2 × 2 × 0.5 (ALAC) × 3600 = 691,200,000
        #expect(bytes == 691_200_000)
    }

    @Test func estimatedBytesPerHourWAVIsDoubleALAC() {
        let testDefaults = UserDefaults(suiteName: "com.sapomac.Sapo.test.wav")!
        testDefaults.set("wav", forKey: "stemFormat")
        let wavModel = AppModel.makeIdle(settings: SettingsStore(defaults: testDefaults))
        wavModel.appSources = [SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: nil, deviceUID: nil)]
        wavModel.selectedSourceIDs = ["a"]

        let alacModel = AppModel.makeIdle()
        alacModel.appSources = [SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: nil, deviceUID: nil)]
        alacModel.selectedSourceIDs = ["a"]

        #expect(wavModel.estimatedBytesPerHour == 2 * alacModel.estimatedBytesPerHour)
    }
}

@MainActor
@Suite("AppModel recording lifecycle") struct AppModelRecordingTests {
    @Test func startRecordingDoesNothingWithNoSources() {
        let model = AppModel.makeIdle()
        model.startRecording()
        #expect(model.engine.state == .idle)
    }

    @Test func stopRecordingWhenIdleDoesNothing() {
        let model = AppModel.makeIdle()
        model.stopRecording()
        #expect(model.engine.state == .idle)
    }

    @Test func startRecordingClearsLastError() {
        let model = AppModel.makeIdle()
        model.lastError = "some error"
        model.startRecording()
        #expect(model.lastError == nil)
    }

    @Test func metersOnStartsWithFalse() {
        let model = AppModel.makeIdle()
        #expect(model.metersOn == false)
    }

    @Test func permissionDeniedStartsFalse() {
        let model = AppModel.makeIdle()
        #expect(model.permissionDenied == false)
    }

    @Test func lastErrorStartsNil() {
        let model = AppModel.makeIdle()
        #expect(model.lastError == nil)
    }
}

@MainActor
@Suite("AppModel level computation") struct AppModelLevelTests {
    @Test func levelReturnsZeroWhenNoEngineOrMeters() {
        let model = AppModel.makeIdle()
        #expect(model.level(for: "com.app.a") == 0)
    }

    @Test func levelReturnsZeroForUnknownId() {
        let model = AppModel.makeIdle()
        #expect(model.level(for: "any-id") == 0)
    }
}

@MainActor
@Suite("AppModel mute state") struct AppModelMuteTests {
    @Test func idleToggleMuteTogglesSelection() {
        let model = AppModel.makeIdle()
        model.appSources = [SourceDescriptor(id: "com.app.a", kind: .application, name: "App A", bundleIdentifier: nil, deviceUID: nil)]

        model.toggleMute("com.app.a")
        #expect(model.selectedSourceIDs == ["com.app.a"])
        #expect(model.mutedSourceIDs.isEmpty)

        model.toggleMute("com.app.a")
        #expect(model.selectedSourceIDs == [])
        #expect(model.mutedSourceIDs.isEmpty)
    }

    @Test func mutedSourceIDsStartsEmpty() {
        let model = AppModel.makeIdle()
        #expect(model.mutedSourceIDs.isEmpty)
    }

    @Test func toggleMuteOnUnselectedSourceDoesNothing() {
        let model = AppModel.makeIdle()
        model.appSources = [SourceDescriptor(id: "com.app.a", kind: .application, name: "App A", bundleIdentifier: nil, deviceUID: nil)]

        model.toggleMute("com.app.a") // selects it
        #expect(model.selectedSourceIDs == ["com.app.a"])

        model.toggleMute("com.app.a") // deselects it
        #expect(model.selectedSourceIDs == [])
    }
}

// MARK: - Tab source refresh

@MainActor
@Suite("AppModel tab sources") struct AppModelTabSourceTests {
    private func makeModel(tabCaptureEnabled: Bool, suite: String) -> AppModel {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(tabCaptureEnabled, forKey: "tabCaptureEnabled")
        return AppModel(settings: SettingsStore(defaults: defaults))
    }

    @Test func tabSourceAppearsWhenEnabled() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabon")
        #expect(model.tabSources.isEmpty) // not populated until refresh
        model.refreshTabSources()
        #expect(model.tabSources.count == 1)
        #expect(model.tabSources[0].kind == .tabCapture)
        #expect(model.tabSources[0].name == "Browser Tab")
        // id suffix is the tabID RecorderEngine extracts: "tab-chrome-0" → "0"
        #expect(model.tabSources[0].id.components(separatedBy: "-").last == "0")
    }

    @Test func noTabSourceWhenDisabled() {
        let model = makeModel(tabCaptureEnabled: false, suite: "com.sapomac.Sapo.test.taboff")
        model.refreshTabSources()
        #expect(model.tabSources.isEmpty)
    }

    @Test func refreshSourcesPopulatesTabSources() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabrefresh")
        model.refreshSources()
        #expect(model.tabSources.count == 1)
    }
}

// MARK: - Helpers

extension AppModel {
    /// Convenience factory that bypasses the singleton.
    static func makeIdle(settings: SettingsStore = SettingsStore()) -> AppModel {
        AppModel(settings: settings)
    }
}
