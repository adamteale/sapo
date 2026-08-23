import Foundation
import AVFoundation
import Testing
@testable import Sapo

@Suite("StemWriter") struct StemWriterTests {
    /// interleaved Float32 stereo ASBD like a tap provides
    static func clientFormat(channels: UInt32, rate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
                                    mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    static func writeSine(url: URL, format: StemFormat, channels: UInt32, rate: Float64, seconds: Double, freq: Double = 440) throws {
        let writer = try StemWriter(url: url, clientFormat: Self.clientFormat(channels: channels, rate: rate), format: format)
        let framesPerWrite: UInt32 = 4096
        let totalFrames = UInt32(rate * seconds)
        var phase: Float = 0
        var written: UInt32 = 0
        let increment: Float = Float(2.0 * Double.pi * freq / rate)
        while written < totalFrames {
            let n = min(framesPerWrite, totalFrames - written)
            var samples = [Float](repeating: 0, count: Int(n * channels))
            for f in 0..<Int(n) {
                let v = sin(phase); phase += increment
                for c in 0..<Int(channels) { samples[f * Int(channels) + c] = v * 0.5 }
            }
            try samples.withUnsafeMutableBytes { raw in
                var abl = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: n * 4 * channels,
                                          mData: raw.baseAddress))
                try writer.write(&abl, frameCount: n)
            }
            written += n
        }
        writer.close()
    }

    @Test func writesReadableWAV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).wav")
        try Self.writeSine(url: url, format: .wav, channels: 2, rate: 48_000, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 44_000) // ~1s of frames
        #expect(file.fileFormat.sampleRate == 48_000)
    }

    @Test func writesReadableALACCAF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).caf")
        try Self.writeSine(url: url, format: .alac, channels: 2, rate: 48_000, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 44_000)
        #expect(abs(file.fileFormat.sampleRate - 48_000) < 1)
    }

    @Test func wavIsSmallerThanNothingAndALACCompresses() throws {
        // sanity on ALAC actually compressing a pure sine strongly
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).wav")
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).caf")
        try Self.writeSine(url: wav, format: .wav, channels: 2, rate: 48_000, seconds: 2.0)
        try Self.writeSine(url: caf, format: .alac, channels: 2, rate: 48_000, seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: caf) }
        let wavSize = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as! Int
        let cafSize = try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as! Int
        #expect(cafSize < wavSize) // sine must compress below PCM
    }
}
