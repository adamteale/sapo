import Foundation
import AVFoundation

enum ExportScope: String, CaseIterable { case combined, individual, grouped }

struct ExportRequest {
    var sessionFolder: URL
    var selectedStemIDs: Set<UUID>
    var scope: ExportScope
    var format: ExportFormat
    var destination: URL
    /// Optional progress callback (0.0–1.0). Called after each group is mixed.
    var onProgress: ((Float) -> Void)?
    /// Optional time-range trim. `start` is seconds from the session start;
    /// `end` is the absolute end time. Both nil means full session.
    var trimStart: TimeInterval?
    var trimEnd: TimeInterval?
}

enum ExportError: Error, LocalizedError {
    case missingStems([String])
    case cancelled

    var errorDescription: String? {
        switch self {
        case .missingStems(let files):
            "\(files.count) stem file(s) missing: \(files.joined(separator: ", "))"
        case .cancelled:
            "Export was cancelled."
        }
    }
}

enum ExportEngine {
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    static func export(_ request: ExportRequest) throws -> [URL] {
        let manifest = try SessionStore().loadManifest(at: request.sessionFolder)
        let selected = manifest.stems.filter { request.selectedStemIDs.contains($0.id) }
        guard !selected.isEmpty else { return [] }

        // Read every selected stem explicitly: decode errors propagate, and a nil
        // return (file missing on disk) is treated as a failure so a stem can never
        // silently vanish from the export.
        var stems: [StemAudio] = []
        var missing: [String] = []
        for stem in selected {
            let stemStart = stem.startTime.timeIntervalSince(manifest.startTime)
            let stemEnd = stem.endTime?.timeIntervalSince(manifest.startTime) ?? Double.greatestFiniteMagnitude
            // Clip trim range to stem's actual time range.
            let trimStart: TimeInterval?
            let trimEnd: TimeInterval?
            if let start = request.trimStart {
                trimStart = start > stemStart ? start - stemStart : nil
            } else {
                trimStart = nil
            }
            if let end = request.trimEnd {
                let stemDuration = stemEnd - stemStart
                trimEnd = end > stemStart ? min(end - stemStart, stemDuration) : nil
            } else {
                trimEnd = nil
            }
            // Compute duration: nil means read to end of stem.
            let trimDuration: TimeInterval? = if let start = trimStart, let end = trimEnd {
                end - start
            } else if let end = trimEnd {
                end
            } else if let start = trimStart {
                // No end trim specified: read from start to end of stem.
                nil
            } else {
                nil
            }
            guard let audio = try StemReader.read(stem, sessionStart: manifest.startTime,
                                                  folder: request.sessionFolder,
                                                  offset: trimStart, duration: trimDuration) else {
                missing.append(stem.fileName)
                continue
            }
            stems.append(audio)
        }
        if !missing.isEmpty { throw ExportError.missingStems(missing) }
        guard !stems.isEmpty else { return [] }

        let rate = stems.map(\.buffer.format.sampleRate).max() ?? 48_000
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NSError(domain: "ExportEngine", code: 1)
        }

        var written: [URL] = []
        let ext = request.format == .m4a ? "m4a" : "wav"
        let title = sanitize(manifest.title)

        func urlFor(_ label: String) -> URL {
            var url = request.destination.appendingPathComponent("\(title) — \(label).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = request.destination.appendingPathComponent("\(title) — \(label) \(n).\(ext)")
                n += 1
            }
            return url
        }

        func writeMix(_ group: [StemAudio], label: String, progress: Float) throws {
            // Check cancellation before each group.
            if let onProgress = request.onProgress {
                onProgress(progress)
            }
            let mix = try Mixer.mix(group, outputFormat: outputFormat)
            let url = urlFor(label)
            try ExportEncoder.write(mix, to: url, format: request.format)
            written.append(url)
        }

        let totalGroups: Int
        switch request.scope {
        case .combined:
            totalGroups = 1
        case .grouped:
            let apps = stems.filter { $0.record.source.kind == .application }
            let mics = stems.filter { $0.record.source.kind == .microphone }
            totalGroups = (apps.isEmpty ? 0 : 1) + (mics.isEmpty ? 0 : 1)
        case .individual:
            totalGroups = stems.count
        }

        var groupIndex = 0
        switch request.scope {
        case .combined:
            try writeMix(stems, label: "Mix", progress: 1.0)
        case .grouped:
            let apps = stems.filter { $0.record.source.kind == .application }
            let mics = stems.filter { $0.record.source.kind == .microphone }
            if !apps.isEmpty {
                groupIndex += 1
                try writeMix(apps, label: "Applications",
                             progress: totalGroups > 1 ? Float(groupIndex) / Float(totalGroups) : 1.0)
            }
            if !mics.isEmpty {
                groupIndex += 1
                try writeMix(mics, label: "Microphone",
                             progress: totalGroups > 1 ? Float(groupIndex) / Float(totalGroups) : 1.0)
            }
        case .individual:
            for stem in stems {
                groupIndex += 1
                try writeMix([stem], label: sanitize(stem.record.source.name),
                             progress: Float(groupIndex) / Float(totalGroups))
            }
        }
        return written
    }
}
