import Foundation
import AVFoundation

enum ExportScope: String, CaseIterable { case combined, individual, grouped }

struct ExportRequest {
    var sessionFolder: URL
    var selectedStemIDs: Set<UUID>
    var scope: ExportScope
    var format: ExportFormat
    var destination: URL
}

enum ExportEngine {
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    static func export(_ request: ExportRequest) throws -> [URL] {
        let manifest = try SessionStore().loadManifest(at: request.sessionFolder)
        let selected = manifest.stems.filter { request.selectedStemIDs.contains($0.id) }
        guard !selected.isEmpty else { return [] }

        let stems = selected.compactMap { try? StemReader.read($0, sessionStart: manifest.startTime,
                                                               folder: request.sessionFolder) }
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

        func writeMix(_ group: [StemAudio], label: String) throws {
            let mix = try Mixer.mix(group, outputFormat: outputFormat)
            let url = urlFor(label)
            try ExportEncoder.write(mix, to: url, format: request.format)
            written.append(url)
        }

        switch request.scope {
        case .combined:
            try writeMix(stems, label: "Mix")
        case .grouped:
            let apps = stems.filter { $0.record.source.kind == .application }
            let mics = stems.filter { $0.record.source.kind == .microphone }
            if !apps.isEmpty { try writeMix(apps, label: "Applications") }
            if !mics.isEmpty { try writeMix(mics, label: "Microphone") }
        case .individual:
            for stem in stems {
                try writeMix([stem], label: sanitize(stem.record.source.name))
            }
        }
        return written
    }
}
