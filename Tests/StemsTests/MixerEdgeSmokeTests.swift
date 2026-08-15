import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("MixerEdge") struct MixerEdgeTests {
    static func makeBuffer(rate: Double, seconds: Double, value: Float, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        for c in 0..<Int(channels) { buf.floatChannelData![c].update(repeating: value, count: Int(buf.frameLength)) }
        return buf
    }

    static func stem(value: Float, rate: Double, seconds: Double, offset: TimeInterval = 0, channels: AVAudioChannelCount = 1) -> StemAudio {
        let src = SourceDescriptor(id: "s\(value)", kind: .application, name: "S", bundleIdentifier: "s", deviceUID: nil)
        let rec = StemRecord(source: src, fileName: "x.caf", sampleRate: rate, channelCount: Int(channels),
                             startTime: Date(timeIntervalSince1970: 1000 + offset), endTime: nil, endEvent: nil)
        return StemAudio(record: rec, buffer: makeBuffer(rate: rate, seconds: seconds, value: value, channels: channels), offsetSeconds: offset)
    }

    @Test func downsamples96kTo48k() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 96_000, seconds: 1)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(abs(Double(mix.frameLength) - 48_000) < 100)
        let mid = mix.floatChannelData![0][24_000]
        #expect(abs(mid - 0.5) < 0.02, "mid sample \(mid)")
    }

    @Test func nonIntegerRatio44100To48000() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 44_100, seconds: 1)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(abs(Double(mix.frameLength) - 48_000) < 100)
    }

    @Test func stereoDownmixToMonoAndUpmix() throws {
        // stereo 44.1k -> mono 48k (downmix: channels min() maps to 0 only)
        let mono = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 44_100, seconds: 1, channels: 2)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!)
        #expect(abs(Double(mono.frameLength) - 48_000) < 100)
        // mono 48k -> stereo 48k (upmix: both channels get the mono signal)
        let stereo = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 48_000, seconds: 1)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(abs(stereo.floatChannelData![0][100] - 0.5) < 0.001)
        #expect(abs(stereo.floatChannelData![1][100] - 0.5) < 0.001)
    }

    @Test func negativeOffsetDropsPreSessionAudio() throws {
        // stem starts 0.25s before sessionStart: its first 0.25s is cut, rest lands at 0
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 48_000, seconds: 1, offset: -0.25)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.frameLength == 36_000)
        // Pre-session 12k frames are cut, but the stem is already sounding at t=0
        #expect(abs(mix.floatChannelData![0][0] - 0.5) < 0.001)
        #expect(abs(mix.floatChannelData![0][35_999] - 0.5) < 0.001)
    }

    @Test func gainScalesStems() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 48_000, seconds: 0.5)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!, gain: 0.5)
        #expect(abs(mix.floatChannelData![0][10] - 0.25) < 0.001)
    }

    @Test func readerRoundTripsWrittenFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
        buf.frameLength = 44_100
        buf.floatChannelData![0].update(repeating: 0.25, count: 44_100)
        let url = tmp.appendingPathComponent("stem.caf")
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        try file.write(from: buf)
        let sessionStart = Date(timeIntervalSince1970: 1000)
        let rec = StemRecord(source: SourceDescriptor(id: "s", kind: .application, name: "S", bundleIdentifier: "s", deviceUID: nil),
                             fileName: "stem.caf", sampleRate: 44_100, channelCount: 1,
                             startTime: Date(timeIntervalSince1970: 1001), endTime: nil, endEvent: nil)
        let audio = try StemReader.read(rec, sessionStart: sessionStart, folder: tmp)
        #expect(audio != nil)
        #expect(abs(audio!.offsetSeconds - 1.0) < 0.0001)
        #expect(audio!.buffer.frameLength == 44_100)
        #expect(abs(audio!.buffer.floatChannelData![0][5_000] - 0.25) < 0.001)
        // missing file returns nil
        let missing = StemRecord(source: rec.source, fileName: "nope.caf", sampleRate: 44_100, channelCount: 1,
                                 startTime: rec.startTime, endTime: nil, endEvent: nil)
        #expect(try StemReader.read(missing, sessionStart: sessionStart, folder: tmp) == nil)
    }
}
