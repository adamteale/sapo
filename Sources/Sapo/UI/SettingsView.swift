import SwiftUI

/// Preferences pane (Settings scene): stem format, post-export cleanup behavior,
/// launch-at-login, and the default microphone.
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel
    @State private var showCleanupConfirmation = false
    @State private var cleanupMessage: String?

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
            Section("Session retention") {
                Picker("Delete sessions older than", selection: Binding(
                    get: { settings.maxSessionAge ?? 30 },
                    set: { settings.maxSessionAge = $0 > 0 ? $0 : nil })) {
                    Text("Never").tag(0)
                    Text("1 week").tag(7)
                    Text("2 weeks").tag(14)
                    Text("1 month").tag(30)
                    Text("3 months").tag(90)
                }
                Button("Clean up old sessions…") { showCleanupConfirmation = true }
                    .disabled(settings.maxSessionAge == nil || settings.maxSessionAge! == 0)
            }
            Section("Tab capture") {
                Toggle("Enable tab capture", isOn: $settings.tabCaptureEnabled)
                if settings.tabCaptureEnabled {
                    Stepper("TCP port: \(settings.tabCapturePort)", value: $settings.tabCapturePort, in: 1024...65535)
                        .disabled(settings.tabCapturePort == 5678)
                    Text("Chrome extension forwards tab audio to this port.").font(.caption)
                }
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
            if let cleanupMessage { Text(cleanupMessage).font(.callout) }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { model.refreshSources() }
        .alert("Clean up old sessions?", isPresented: $showCleanupConfirmation) {
            Button("Delete", role: .destructive) { performCleanup() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sessions older than \(settings.maxSessionAge ?? 30) days will be permanently deleted. This cannot be undone.")
        }
    }

    private func performCleanup() {
        guard let maxAge = settings.maxSessionAge, maxAge > 0 else { return }
        do {
            let result = try model.store.deleteOldSessions(maxAgeDays: maxAge)
            let fmt = ByteCountFormatter()
            fmt.countStyle = .file
            cleanupMessage = "Deleted \(result.count) session(s), freed \(fmt.string(fromByteCount: result.bytesFreed))."
        } catch {
            cleanupMessage = "Cleanup failed: \(error.localizedDescription)"
        }
    }
}
