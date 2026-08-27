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

    @Test func tabListPushPopulatesPerTabRows() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabs1")
        model.handleTabList([
            TabInfo(id: 11, title: "YouTube — Some Song", audible: true),
            TabInfo(id: 22, title: "GitHub", audible: false),
        ])
        #expect(model.tabSources.count == 2)
        #expect(model.tabSources[0].kind == .tabCapture)
        #expect(model.tabSources[0].name == "YouTube — Some Song")
        // id encodes the tabID RecorderEngine demuxes on: "tab-11" → "11"
        #expect(model.tabSources[0].id.components(separatedBy: "-").last == "11")
        #expect(model.tabSources[1].id == "tab-22")
    }

    @Test func longTitlesTruncatedTo60() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabs2")
        let long = String(repeating: "a", count: 100)
        model.handleTabList([TabInfo(id: 1, title: long, audible: false)])
        #expect(model.tabSources[0].name.count == 60)
        #expect(model.tabSources[0].name.hasSuffix("…"))
    }

    @Test func noRowsWhenDisabled() {
        let model = makeModel(tabCaptureEnabled: false, suite: "com.sapomac.Sapo.test.tabs3")
        model.handleTabList([TabInfo(id: 1, title: "t", audible: false)])
        #expect(model.tabSources.isEmpty)
    }

    @Test func disablingClearsExistingRows() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabs4")
        model.handleTabList([TabInfo(id: 1, title: "t", audible: false)])
        #expect(model.tabSources.count == 1)
        model.settings.tabCaptureEnabled = false
        model.refreshTabSources() // explicit refresh applies the setting
        #expect(model.tabSources.isEmpty)
    }

    @Test func emptyListClearsRowsWhenEnabled() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabs5")
        model.handleTabList([TabInfo(id: 1, title: "t", audible: false)])
        model.handleTabList([]) // browser closed / last tab closed
        #expect(model.tabSources.isEmpty)
    }

    @Test func refreshSourcesPreservesRegistryRows() {
        let model = makeModel(tabCaptureEnabled: true, suite: "com.sapomac.Sapo.test.tabs6")
        model.handleTabList([TabInfo(id: 5, title: "docs", audible: false)])
        model.refreshSources() // full refresh must not wipe registry rows
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
