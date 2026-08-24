import Foundation

enum SourceKind: String, Codable, CaseIterable {
    case application
    case microphone
}

struct SourceDescriptor: Codable, Hashable, Identifiable {
    var id: String            // bundleIdentifier for apps, deviceUID for mics
    var kind: SourceKind
    var name: String
    var bundleIdentifier: String?
    var deviceUID: String?
    /// Host .app bundle path for application sources — the helper-folding
    /// identity. Optional so v0.1.0 manifests (without it) still decode.
    var appBundlePath: String? = nil
}

enum StemFormat: String, Codable, CaseIterable {
    case alac
    case wav
}

struct StemRecord: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var source: SourceDescriptor
    var fileName: String
    var sampleRate: Double
    var channelCount: Int
    var startTime: Date
    var endTime: Date?
    var endEvent: String?   // "sessionEnd" | "processExited" | "deviceLost"
}

struct SessionManifest: Codable, Equatable {
    var identifier: UUID
    var title: String
    var startTime: Date
    var endTime: Date?
    var stemFormat: StemFormat
    var stems: [StemRecord]
    var appVersion: String
}

struct SessionSummary: Identifiable {
    var id: UUID { manifest.identifier }
    var folderURL: URL
    var manifest: SessionManifest
    var sizeBytes: Int64
    var totalDuration: TimeInterval {
        if let end = manifest.endTime { return end.timeIntervalSince(manifest.startTime) }
        return manifest.stems.compactMap(\.endTime)
            .map { $0.timeIntervalSince(manifest.startTime) }.max() ?? 0
    }
    /// Age in days since the session started.
    var ageInDays: Double {
        Date().timeIntervalSince(manifest.startTime) / 86_400
    }
}
