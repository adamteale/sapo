import Foundation
import Combine
import ServiceManagement

/// How stems should be handled after a combined export succeeds.
enum StemCleanupBehavior: String, CaseIterable {
    case ask, always, never
}

enum TabCapturePluginDetector {
    static func isInstalled(fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:)) -> Bool {
        let home = NSHomeDirectory()
        let manifests = [
            "\(home)/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.sapomac.sapo-tab-capture.json",
            "\(home)/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.sapomac.sapo-tab-capture.json",
            "\(home)/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.sapomac.sapo-tab-capture.json",
            "\(home)/Library/Application Support/Chromium/NativeMessagingHosts/com.sapomac.sapo-tab-capture.json",
        ]
        return manifests.contains(where: fileExists)
    }
}

/// Persisted user preferences, backed by `UserDefaults`.
///
/// Values round-trip through a `UserDefaults` suite so the suite can be
/// swapped in tests. `launchAtLogin` additionally drives the system
/// ServiceManagement registration, which only works when running from an
/// installed .app bundle — in CLI/test runs (`Bundle.main.bundleURL` has no
/// `.app` extension) the registration is skipped so `swift test` stays quiet.
final class SettingsStore: ObservableObject {
    @Published var stemFormat: StemFormat {
        didSet { defaults.set(stemFormat.rawValue, forKey: "stemFormat") }
    }
    @Published var stemCleanup: StemCleanupBehavior {
        didSet { defaults.set(stemCleanup.rawValue, forKey: "stemCleanup") }
    }
    @Published var maxSessionAge: Int? {
        didSet { defaults.set(maxSessionAge, forKey: "maxSessionAge") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var defaultMicDeviceUID: String? {
        didSet { defaults.set(defaultMicDeviceUID ?? "", forKey: "defaultMicDeviceUID") }
    }
    @Published var tabCaptureEnabled: Bool {
        didSet { defaults.set(tabCaptureEnabled, forKey: "tabCaptureEnabled") }
    }
    @Published var tabCapturePort: Int {
        didSet { defaults.set(tabCapturePort, forKey: "tabCapturePort") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, pluginInstalled: Bool? = nil) {
        self.defaults = defaults
        stemFormat = StemFormat(rawValue: defaults.string(forKey: "stemFormat") ?? "") ?? .alac
        stemCleanup = StemCleanupBehavior(rawValue: defaults.string(forKey: "stemCleanup") ?? "") ?? .ask
        let maxAge = defaults.integer(forKey: "maxSessionAge")
        maxSessionAge = maxAge > 0 ? maxAge : nil
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        let mic = defaults.string(forKey: "defaultMicDeviceUID")
        defaultMicDeviceUID = (mic?.isEmpty == false) ? mic : nil
        if defaults.object(forKey: "tabCaptureEnabled") == nil {
            // Never explicitly chosen: follow the plugin. Installing the
            // plugin is itself the opt-in, so the source row shows up without
            // hunting for a toggle. Deliberately NOT persisted — the default
            // keeps tracking install state until the user makes an explicit
            // choice, which then wins forever.
            tabCaptureEnabled = pluginInstalled ?? TabCapturePluginDetector.isInstalled()
        } else {
            tabCaptureEnabled = defaults.bool(forKey: "tabCaptureEnabled")
        }
        tabCapturePort = defaults.integer(forKey: "tabCapturePort")
        if tabCapturePort == 0 { tabCapturePort = 5678; defaults.set(5678, forKey: "tabCapturePort") }
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        // SMAppService.mainApp requires a real .app bundle; under `swift test`
        // or CLI tool mode registration fails and prints noise, so skip it.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            print("launch-at-login failed: \(error)")
        }
    }
}
