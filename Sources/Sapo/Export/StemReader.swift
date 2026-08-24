import Foundation
import AVFoundation

struct StemAudio {
    var record: StemRecord
    var buffer: AVAudioPCMBuffer
    var offsetSeconds: TimeInterval
}

enum StemReader {
    /// Read a stem with optional time-range trim. `offset` is the start offset
    /// within the stem (seconds from stem start); `duration` is how many seconds
    /// to read. Pass nil for offset or duration to read the full stem.
    static func read(_ record: StemRecord, sessionStart: Date, folder: URL,
                     offset: TimeInterval? = nil, duration: TimeInterval? = nil) throws -> StemAudio? {
        let url = folder.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        let fullFrames = Int64(file.length)
        guard let fullBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                                frameCapacity: AVAudioFrameCount(fullFrames)) else { return nil }
        try file.read(into: fullBuffer)
        fullBuffer.frameLength = AVAudioFrameCount(fullFrames)

        let stemOffset = record.startTime.timeIntervalSince(sessionStart)
        let sampleRate = file.fileFormat.sampleRate

        // Compute trim region relative to the stem file's content.
        // The file contains the full stem recording; offset/duration are user
        // requested portions within that recording.
        let trimStartFrame: Int64
        let trimEndFrame: Int64
        if let offset {
            trimStartFrame = Int64(Double(offset) * sampleRate)
        } else {
            trimStartFrame = 0
        }
        if let duration {
            trimEndFrame = trimStartFrame + Int64(Double(duration) * sampleRate)
        } else {
            trimEndFrame = fullFrames
        }
        guard trimStartFrame < trimEndFrame else { return nil }
        let readFrames = trimEndFrame - trimStartFrame

        guard let trimmed = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                             frameCapacity: AVAudioFrameCount(readFrames)) else { return nil }
        // Trim from the full buffer (AVAudioFile doesn't support seeking in read).
        let channels = Int(file.processingFormat.channelCount)
        for c in 0..<channels {
            guard let src = fullBuffer.floatChannelData?[c],
                  let dst = trimmed.floatChannelData?[c] else { continue }
            let offset = Int(trimStartFrame)
            let count = Int(readFrames)
            dst.initialize(from: src.advanced(by: offset), count: count)
        }
        trimmed.frameLength = AVAudioFrameCount(readFrames)
        // When trimming, the returned buffer represents only the trimmed portion,
        // so its offset relative to the session is the stem start + the trim offset.
        // However, the Mixer pads output to (offset + buffer length), so if we want
        // the export to be exactly the trimmed duration, we must set offsetSeconds
        // to 0 for trimmed regions. The caller (ExportEngine) already clamped
        // trimStart to stem-relative values, so stemOffset is the true session offset.
        let effectiveOffset: TimeInterval
        if offset != nil || duration != nil {
            effectiveOffset = 0 // trimmed: no padding
        } else {
            effectiveOffset = stemOffset
        }
        return StemAudio(record: record, buffer: trimmed,
                         offsetSeconds: effectiveOffset)
    }
}
