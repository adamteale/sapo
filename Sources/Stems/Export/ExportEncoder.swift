import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

enum ExportFormat: String, CaseIterable { case m4a, wav }

enum ExportEncoder {
    /// Encode one non-interleaved Float32 buffer to a file at `url`.
    /// WAV → 16-bit interleaved PCM; M4A → AAC (Apple software codec).
    static func write(_ buffer: AVAudioPCMBuffer, to url: URL, format: ExportFormat) throws {
        // File (data) format ASBD, built directly. For WAV the file is 16-bit
        // interleaved PCM stereo; for M4A the file is AAC and ExtAudioFile
        // performs the encode from the Float32 client format below.
        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: buffer.format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * 2, mFramesPerPacket: 1, mBytesPerFrame: 2 * 2,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        let fileType: AudioFileTypeID
        switch format {
        case .wav:
            fileType = kAudioFileWAVEType
        case .m4a:
            fileType = kAudioFileM4AType
            fileASBD = AudioStreamBasicDescription(
                mSampleRate: buffer.format.sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        }

        var ref: ExtAudioFileRef?
        let create = ExtAudioFileCreateWithURL(url as CFURL, fileType, &fileASBD,
                                               nil, AudioFileFlags.eraseFile.rawValue, &ref)
        guard create == noErr, let file = ref else { throw StemWriterError.status(create, "create export file") }
        defer { ExtAudioFileDispose(file) }

        if format == .m4a {
            // kAppleSoftwareAudioCodecManufacturer ('appl') is not imported into
            // Swift on the macOS 26 SDK, so spell the OSType directly.
            var manufacturer = UInt32(0x6170706C)
            let setManufacturer = ExtAudioFileSetProperty(file, kExtAudioFileProperty_CodecManufacturer,
                                                          UInt32(MemoryLayout<UInt32>.size), &manufacturer)
            guard setManufacturer == noErr else { throw StemWriterError.status(setManufacturer, "codec manufacturer") }
        }

        var clientASBD = buffer.format.streamDescription.pointee
        let setClient = ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                                &clientASBD)
        guard setClient == noErr else { throw StemWriterError.status(setClient, "client format") }

        // Wrap the (non-interleaved Float32) buffer in an AudioBufferList with one
        // AudioBuffer per channel. AudioBufferList's fixed mBuffers tuple cannot be
        // subscripted with a runtime index on this SDK, so index through the
        // mutable pointer view.
        let channelCount = Int(buffer.format.channelCount)
        let list = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(list.unsafeMutablePointer) }
        for i in 0..<channelCount {
            list[i] = AudioBuffer(mNumberChannels: 1,
                                  mDataByteSize: buffer.frameLength * 4,
                                  mData: buffer.floatChannelData![i])
        }
        let status = ExtAudioFileWrite(file, buffer.frameLength, list.unsafeMutablePointer)
        guard status == noErr else { throw StemWriterError.status(status, "export write") }
    }
}
