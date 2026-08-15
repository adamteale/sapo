import SwiftUI

/// Preferences pane (Settings scene): stem format, post-export cleanup behavior,
/// launch-at-login, and the default microphone.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Stem format", selection: $settings.stemFormat) {
                Text("ALAC (lossless, default)").tag(StemFormat.alac)
                Text("WAV (uncompressed)").tag(StemFormat.wav)
            }
            Picker("After export, delete stems", selection: $settings.stemCleanup) {
                Text("Ask each time").tag(StemCleanupBehavior.ask)
                Text("Always").tag(StemCleanupBehavior.always)
                Text("Never").tag(StemCleanupBehavior.never)
            }
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Picker("Default microphone", selection: Binding(
                get: { settings.defaultMicDeviceUID ?? "" },
                set: { settings.defaultMicDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(model.micSources) { mic in
                    Text(mic.name).tag(mic.deviceUID ?? "")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { model.refreshSources() }
    }
}
