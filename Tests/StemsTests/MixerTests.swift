import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("Mixer") struct MixerTests {
    static func makeBuffer(rate: Double, seconds: Double, value: Float, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        for c in 0..<Int(channels) { buf.floatChannelData![c].update(repeating: value, count: Int(buf.frameLength)) }
        return buf
    }

    static func stem(value: Float, rate: Double, seconds: Double, offset: TimeInterval = 0) -> StemAudio {
        let src = SourceDescriptor(id: "s\(value)-\(rate)", kind: .application, name: "S", bundleIdentifier: "s", deviceUID: nil)
        let rec = StemRecord(source: src, fileName: "x.caf", sampleRate: rate, channelCount: 1,
                             startTime: Date(timeIntervalSince1970: 1000 + offset), endTime: nil, endEvent: nil)
        return StemAudio(record: rec, buffer: makeBuffer(rate: rate, seconds: seconds, value: value), offsetSeconds: offset)
    }

    @Test func mixesSameRateConstantLevels() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.25, rate: 48_000, seconds: 1),
             Self.stem(value: 0.50, rate: 48_000, seconds: 1)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.frameLength == 48_000)
        #expect(abs(mix.floatChannelData![0][100] - 0.75) < 0.001)
    }

    @Test func offsetPadsWithSilence() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 48_000, seconds: 1, offset: 1.0)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.frameLength == 96_000)
        #expect(mix.floatChannelData![0][100] == 0)          // first second silent
        #expect(abs(mix.floatChannelData![0][48_100] - 0.5) < 0.001)
    }

    @Test func resamplesMixedRates() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 8_000, seconds: 2)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(abs(Double(mix.frameLength) - 96_000) < 100) // resampled to 48k
        #expect(abs(mix.floatChannelData![0][50_000] - 0.5) < 0.01)
    }

    @Test func clippingProtectsOutput() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.9, rate: 48_000, seconds: 0.5),
             Self.stem(value: 0.9, rate: 48_000, seconds: 0.5)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.floatChannelData![0][10] <= 1.0)
    }
}
