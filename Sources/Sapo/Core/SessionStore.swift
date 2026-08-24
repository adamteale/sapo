import Foundation

final class SessionStore {
    let root: URL

    init(rootURL: URL? = nil) {
        self.root = rootURL ?? SessionStore.defaultRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return music.appendingPathComponent("Sapo", isDirectory: true)
    }

    static func coders() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    static func folderName(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "Session yyyy-MM-dd HH.mm.ss"
        return fmt.string(from: date)
    }

    func makeSessionFolder(start: Date) throws -> URL {
        var url = root.appendingPathComponent(Self.folderName(for: start), isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(Self.folderName(for: start)) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func save(_ manifest: SessionManifest, to folder: URL) throws {
        let (enc, _) = Self.coders()
        let data = try enc.encode(manifest)
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func loadManifest(at folder: URL) throws -> SessionManifest {
        let (_, dec) = Self.coders()
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        return try dec.decode(SessionManifest.self, from: data)
    }

    func listSessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folder -> SessionSummary? in
                guard let manifest = try? loadManifest(at: folder) else { return nil }
                return SessionSummary(folderURL: folder, manifest: manifest, sizeBytes: diskUsage(of: folder))
            }
            .sorted { $0.manifest.startTime > $1.manifest.startTime }
    }

    func deleteStems(in folder: URL) throws {
        let fm = FileManager.default
        for stem in try loadManifest(at: folder).stems {
            let url = folder.appendingPathComponent(stem.fileName)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    func diskUsage(of folder: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Returns sessions older than `maxAgeDays` days. Each entry is the folder URL,
    /// total duration, and disk size (for display).
    func oldSessions(maxAgeDays: Int) -> [(folder: URL, duration: TimeInterval, sizeBytes: Int64)] {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var result: [(folder: URL, duration: TimeInterval, sizeBytes: Int64)] = []
        for folder in children {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let manifest = try? loadManifest(at: folder) else { continue }
            if manifest.startTime < cutoff {
                let duration: TimeInterval
                if let end = manifest.endTime {
                    duration = end.timeIntervalSince(manifest.startTime)
                } else {
                    duration = manifest.stems.compactMap(\.endTime)
                        .map { $0.timeIntervalSince(manifest.startTime) }.max() ?? 0
                }
                result.append((folder, duration, diskUsage(of: folder)))
            }
        }
        return result
    }

    /// Delete all sessions older than `maxAgeDays` days. Returns the count of
    /// deleted sessions and total bytes freed.
    func deleteOldSessions(maxAgeDays: Int) throws -> (count: Int, bytesFreed: Int64) {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return (0, 0) }
        var deleted = 0
        var freed: Int64 = 0
        for folder in children {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            guard let manifest = try? loadManifest(at: folder) else { continue }
            if manifest.startTime < cutoff {
                freed += diskUsage(of: folder)
                try fm.removeItem(at: folder)
                deleted += 1
            }
        }
        return (deleted, freed)
    }
}
