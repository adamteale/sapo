import Foundation
import AVFoundation

struct StemAudio {
    var record: StemRecord
    var buffer: AVAudioPCMBuffer
    var offsetSeconds: TimeInterval
}

enum StemReader {
    static func read(_ record: StemRecord, sessionStart: Date, folder: URL) throws -> StemAudio? {
        let url = folder.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        buffer.frameLength = AVAudioFrameCount(file.length)
        return StemAudio(record: record, buffer: buffer,
                         offsetSeconds: record.startTime.timeIntervalSince(sessionStart))
    }
}
