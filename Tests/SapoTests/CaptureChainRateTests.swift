import Testing
import CoreAudio
@testable import Sapo

/// The IO timeline of a device runs at its NOMINAL sample rate. For a
/// process-tap aggregate that rate is the main (output) device's — e.g.
/// 44.1 kHz Bluetooth — while kAudioDevicePropertyStreamFormat reports the
/// tap's 48 kHz mixdown rate. Stamping 44.1 kHz data into a 48 kHz header
/// makes recordings play back ~9% fast (the "sped up" bug on the tap path).
@Suite("CaptureChain rate reconciliation") struct CaptureChainRateTests {
    private var stereo48k: AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagIsFloat, mBytesPerPacket: 8,
                                    mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                                    mBitsPerChannel: 32, mReserved: 0)
    }

    @Test func nominalRateWinsWhenItDiffers() {
        let reconciled = CaptureChain.reconcilingNominalRate(stereo48k, nominalRate: 44100)
        #expect(reconciled.mSampleRate == 44100)
        #expect(reconciled.mBytesPerFrame == 8)      // layout untouched
        #expect(reconciled.mChannelsPerFrame == 2)
        #expect(reconciled.mBitsPerChannel == 32)
    }

    @Test func agreeingRatesStayUntouched() {
        #expect(CaptureChain.reconcilingNominalRate(stereo48k, nominalRate: 48000).mSampleRate == 48000)
    }

    @Test func missingOrInvalidNominalKeepsStreamRate() {
        #expect(CaptureChain.reconcilingNominalRate(stereo48k, nominalRate: nil).mSampleRate == 48000)
        #expect(CaptureChain.reconcilingNominalRate(stereo48k, nominalRate: 0).mSampleRate == 48000)
    }
}
