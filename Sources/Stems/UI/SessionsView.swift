import SwiftUI

/// Browser of recorded sessions with drill-down into a session's stems,
/// preview playback, and export.
struct SessionsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sessions = SessionsModel()

    var body: some View {
        NavigationStack {
            Group {
                if sessions.sessions.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "waveform",
                                           description: Text("Recorded sessions appear here."))
                } else {
                    List(sessions.sessions) { session in
                        NavigationLink(destination: SessionDetailView(model: model, session: session, sessionsModel: sessions)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.manifest.title).font(.headline)
                                HStack {
                                    Text(RecorderView.format(session.totalDuration))
                                    Text("·").foregroundStyle(.secondary)
                                    Text("\(session.manifest.stems.count) tracks")
                                    Text("·").foregroundStyle(.secondary)
                                    Text(ByteCountFormatter.string(fromByteCount: session.sizeBytes,
                                                                   countStyle: .file))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .onAppear { sessions.reload(store: model.store) }
        }
    }
}

/// State + operations backing the sessions browser UI.
@MainActor
final class SessionsModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []

    func reload(store: SessionStore) {
        sessions = store.listSessions()
    }

    static func previewFileName(for stem: StemRecord, in folder: URL) -> URL {
        folder.appendingPathComponent(stem.fileName)
    }

    func export(session: SessionSummary, selectedStemIDs: Set<UUID>,
                scope: ExportScope, format: ExportFormat, to destination: URL) throws -> [URL] {
        try ExportEngine.export(ExportRequest(sessionFolder: session.folderURL,
                                              selectedStemIDs: selectedStemIDs,
                                              scope: scope, format: format,
                                              destination: destination))
    }

    func deleteStems(for session: SessionSummary, store: SessionStore) throws {
        try store.deleteStems(in: session.folderURL)
    }
}
