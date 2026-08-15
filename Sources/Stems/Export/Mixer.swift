import Foundation
import AVFoundation

enum Mixer {
    /// Resample one stem to the output format, then sum into mix buffer at offset.
    static func mix(_ stems: [StemAudio], outputFormat: AVAudioFormat, gain: Float = 1.0) throws -> AVAudioPCMBuffer {
        // 1. Convert every stem to the output format.
        var converted: [StemAudio] = []
        for stem in stems {
            if stem.buffer.format == outputFormat {
                converted.append(stem)
                continue
            }
            guard let converter = AVAudioConverter(from: stem.buffer.format, to: outputFormat) else { continue }
            let input = stem.buffer
            let ratio = outputFormat.sampleRate / input.format.sampleRate
            let expected = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up))
            // Headroom for the resampler's filter tail, flushed via repeated convert calls.
            let capacity = expected + 4096
            guard let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity),
                  let accum = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { continue }
            var error: NSError?
            var phase = 0  // 0: provide input once, 1: signal end-of-input, 2: drained
            var rounds = 0
            while rounds < 10_000 {
                rounds += 1
                let status = converter.convert(to: scratch, error: &error) { _, inputStatus in
                    switch phase {
                    case 0:
                        phase = 1
                        inputStatus.pointee = .haveData
                        return input
                    case 1:
                        // endOfStream tells the converter no more input is coming, so it
                        // flushes the resampler's internal filter tail into the output.
                        phase = 2
                        inputStatus.pointee = .endOfStream
                        return nil
                    default:
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                }
                let n = scratch.frameLength
                if status == .error { break }
                if n > 0 {
                    for c in 0..<Int(outputFormat.channelCount) {
                        guard let dst = accum.floatChannelData?[c], let src = scratch.floatChannelData?[c] else { continue }
                        dst.advanced(by: Int(accum.frameLength)).update(from: src, count: Int(n))
                    }
                    accum.frameLength += n
                }
                // .inputRanDry may carry the resampler's flush tail (n > 0); keep
                // draining until .endOfStream so no tail samples are lost.
                if status == .endOfStream || (status == .inputRanDry && n == 0) { break }
            }
            if accum.frameLength == 0 { continue }
            // Resampler output may overshoot the mathematically expected length by the
            // filter tail; cap it so offsets and total mix length stay exact.
            accum.frameLength = min(accum.frameLength, expected)
            converted.append(StemAudio(record: stem.record, buffer: accum, offsetSeconds: stem.offsetSeconds))
        }

        // 2. Compute total length: max(offset + duration) in output frames.
        let rate = outputFormat.sampleRate
        let totalFrames = converted.map { Int(($0.offsetSeconds) * rate) + Int($0.buffer.frameLength) }.max() ?? 0
        guard let mix = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "Mixer", code: 1)
        }
        mix.frameLength = AVAudioFrameCount(totalFrames)

        let channels = Int(outputFormat.channelCount)
        // Zero-fill so untouched regions (gaps before first offset) are pristine silence.
        for c in 0..<channels {
            mix.floatChannelData![c].update(repeating: 0, count: totalFrames)
        }
        for stem in converted {
            let startFrame = Int(stem.offsetSeconds * rate)
            let src = stem.buffer
            for c in 0..<channels {
                guard let dst = mix.floatChannelData?[c] else { continue }
                let srcC = min(c, Int(src.format.channelCount) - 1)
                guard let srcData = src.floatChannelData?[srcC] else { continue }
                let n = Int(src.frameLength)
                for i in 0..<n {
                    let idx = startFrame + i
                    guard idx >= 0, idx < totalFrames else { continue }
                    dst[idx] += srcData[i] * gain
                }
            }
        }

        // 3. Soft clip to ±1.
        for c in 0..<channels {
            guard let data = mix.floatChannelData?[c] else { continue }
            for i in 0..<totalFrames {
                let v = data[i]
                data[i] = v > 1 ? 1 : (v < -1 ? -1 : v)
            }
        }
        return mix
    }
}
