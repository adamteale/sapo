import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel

    private var engine: RecorderEngine { model.engine }

    private var isRecording: Bool {
        if case .recording = model.engine.state { return true }
        return false
    }

    private var elapsed: TimeInterval {
        if case .recording(let started) = model.engine.state {
            return Date().timeIntervalSince(started)
        }
        return 0
    }

    private static let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            sourceList
            Divider()
            controlsBar
            if let lastError = model.lastError {
                Text(lastError)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
            if model.permissionDenied { permissionBar }
        }
        .navigationTitle("Recorder")
        .onAppear { model.refreshSources() }
        .onReceive(Self.timer) { _ in
            model.objectWillChange.send() // refresh timer + meters (10Hz; cheap even when idle)
        }
    }

    private var sourceList: some View {
        List {
            Section("Applications") {
                ForEach(model.appSources) { source in
                    sourceRow(source)
                }
            }
            Section("Microphone") {
                ForEach(model.micSources) { source in
                    sourceRow(source)
                }
            }
            if model.appSources.isEmpty && model.micSources.isEmpty {
                Text("No audio sources found — start playing audio in an app, then refresh.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 240)
    }

    private func sourceRow(_ source: SourceDescriptor) -> some View {
        let selected = model.selectedSourceIDs.contains(source.id)
        return HStack {
            Toggle(source.name, isOn: Binding(
                get: { selected },
                set: { _ in model.toggleSource(source.id) }))
            Spacer()
            // Meter column on EVERY row, idle and recording: level(for:) reads
            // engine levels for recording chains, meter taps otherwise. Dimmed
            // while the window gate is off (window hidden / mic denied).
            LevelMeterView(level: model.level(for: source.id))
                .frame(width: 90)
                .opacity(model.metersOn ? 1 : 0.25)
        }
    }

    private var controlsBar: some View {
        HStack {
            if isRecording {
                Button("Stop", role: .destructive) { model.stopRecording() }
                    .controlSize(.large)
                Text(Self.format(elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                Button("Record") { model.startRecording() }
                    .controlSize(.large)
                    .disabled(model.selectedSourceIDs.isEmpty)
            }
            Spacer()
            Button("Refresh") { model.refreshSources() }
            Text(ByteCountFormatter.string(fromByteCount: model.estimatedBytesPerHour,
                                           countStyle: .file) + "/hour")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder private var permissionBar: some View {
        HStack {
            Text("Microphone access is required to record.")
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            Button("Retry") { model.requestMicPermission { _ in model.refreshSources() } }
        }
        .padding(8)
        .background(.red.opacity(0.1))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
