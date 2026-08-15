import Foundation
import Testing
@testable import Stems

@Suite("SettingsStore") struct SettingsStoreTests {
    @Test func roundTripsThroughUserDefaults() {
        let suite = "stems-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        #expect(store.stemFormat == .alac)
        #expect(store.stemCleanup == .ask)

        store.stemFormat = .wav
        store.stemCleanup = .never
        store.launchAtLogin = true

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.stemFormat == .wav)
        #expect(reloaded.stemCleanup == .never)
        #expect(reloaded.launchAtLogin == true)
        defaults.removePersistentDomain(forName: suite)
    }
}
