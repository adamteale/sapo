import Foundation
import Testing
@testable import Sapo

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

    @Test func tabCaptureDefaultsOnWhenPluginInstalled() {
        let suite = "stems-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, pluginInstalled: true)
        #expect(store.tabCaptureEnabled == true)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func tabCaptureDefaultsOffWhenNoPlugin() {
        let suite = "stems-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, pluginInstalled: false)
        #expect(store.tabCaptureEnabled == false)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func explicitUserChoiceWinsOverPlugin() {
        let suite = "stems-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // User explicitly turned it off, plugin installed — choice must win.
        defaults.set(false, forKey: "tabCaptureEnabled")
        let off = SettingsStore(defaults: defaults, pluginInstalled: true)
        #expect(off.tabCaptureEnabled == false)
        // User explicitly turned it on, no plugin — still on.
        defaults.set(true, forKey: "tabCaptureEnabled")
        let on = SettingsStore(defaults: defaults, pluginInstalled: false)
        #expect(on.tabCaptureEnabled == true)
        defaults.removePersistentDomain(forName: suite)
    }
}
