import SwiftUI
import AppKit

/// Detail view for a single session: stem list with per-stem preview playback
/// and an export section (scope, format, destination picker).
struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: SessionSummary
    @ObservedObject var sessionsModel: SessionsModel

    @StateObject private var preview = TrackPreview()
    @State private var selectedStemIDs: Set<UUID> = []
    @State private var scope: ExportScope = .combined
    @State private var format: ExportFormat = .m4a
    @State private var exportMessage: String?

    var body: some View {
        List {
            Section("Tracks") {
                ForEach(session.manifest.stems) { stem in
                    trackRow(stem)
                }
            }
            if session.manifest.stems.isEmpty {
                Text("No stems (stems may have been cleaned up).").foregroundStyle(.secondary)
            }
            Section("Export") {
                Picker("Scope", selection: $scope) {
                    Text("Combined mix").tag(ExportScope.combined)
                    Text("Grouped by type").tag(ExportScope.grouped)
                    Text("Individual files").tag(ExportScope.individual)
                }
                Picker("Format", selection: $format) {
                    Text("M4A (AAC)").tag(ExportFormat.m4a)
                    Text("WAV").tag(ExportFormat.wav)
                }
                Button("Export…") { runExport() }
                    .disabled(selectedStemIDs.isEmpty)
                if let exportMessage { Text(exportMessage).font(.callout) }
            }
        }
        .navigationTitle(session.manifest.title)
        .onAppear {
            if selectedStemIDs.isEmpty {
                selectedStemIDs = Set(session.manifest.stems.map(\.id))
            }
        }
        .onDisappear { preview.stop() }
    }

    private func trackRow(_ stem: StemRecord) -> some View {
        HStack {
            Toggle(stem.source.name, isOn: Binding(
                get: { selectedStemIDs.contains(stem.id) },
                set: { on in
                    if on { selectedStemIDs.insert(stem.id) } else { selectedStemIDs.remove(stem.id) }
                }))
            Spacer()
            Text("\(Int(stem.sampleRate/1000)) kHz")
                .font(.caption).foregroundStyle(.secondary)
            if let event = stem.endEvent, event != "sessionEnd" {
                Image(systemName: "exclamationmark.triangle")
                    .help("Ended early: \(event)")
            }
            Button {
                if preview.playingStemID == stem.id { preview.stop() }
                else { preview.play(stem, folder: session.folderURL) }
            } label: {
                Image(systemName: preview.playingStemID == stem.id ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func runExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose export destination"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let files = try sessionsModel.export(session: session, selectedStemIDs: selectedStemIDs,
                                                 scope: scope, format: format, to: url)
            exportMessage = "Exported \(files.count) file(s) to \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
