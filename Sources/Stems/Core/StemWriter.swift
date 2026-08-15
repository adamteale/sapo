import Foundation
import CoreAudio
import AudioToolbox

enum StemWriterError: Error { case status(OSStatus, String) }

final class StemWriter {
    private var file: ExtAudioFileRef?
    private let url: URL

    init(url: URL, clientFormat: AudioStreamBasicDescription, format: StemFormat) throws {
        self.url = url

        // File (data) format
        var fileFormat = AudioStreamBasicDescription()
        var fileType: AudioFileTypeID
        switch format {
        case .alac:
            fileType = kAudioFileCAFType
            fileFormat.mFormatID = kAudioFormatAppleLossless
            // ALAC's bit depth is signaled by the format flags, not mBitsPerChannel
            // (the encoder defaults to 32-bit source when flags are 0, which does not compress).
            fileFormat.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            fileFormat.mChannelsPerFrame = clientFormat.mChannelsPerFrame
            fileFormat.mSampleRate = clientFormat.mSampleRate
            // ALAC "magic" cookie frames: 16-bit depth, no source bit depth loss beyond PCM32 client
            fileFormat.mBitsPerChannel = 16
            // ALAC frames-per-packet and cookie details are filled by ExtAudioFile's converter.
            fileFormat.mFramesPerPacket = 4096
            fileFormat.mBytesPerPacket = 0
            fileFormat.mBytesPerFrame = 0
        case .wav:
            fileType = kAudioFileWAVEType
            fileFormat = AudioStreamBasicDescription(
                mSampleRate: clientFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2 * clientFormat.mChannelsPerFrame,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2 * clientFormat.mChannelsPerFrame,
                mChannelsPerFrame: clientFormat.mChannelsPerFrame,
                mBitsPerChannel: 16,
                mReserved: 0)
        }

        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(url as CFURL, fileType, &fileFormat,
                                                     nil, AudioFileFlags.eraseFile.rawValue, &ref)
        guard createStatus == noErr, let created = ref else {
            throw StemWriterError.status(createStatus, "ExtAudioFileCreateWithURL(\(format))")
        }
        self.file = created

        var client = clientFormat
        let setClient = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard setClient == noErr else {
            closeQuietly()
            throw StemWriterError.status(setClient, "set client format")
        }
    }

    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32) throws {
        guard let file else { return }
        let status = ExtAudioFileWrite(file, frameCount, bufferList)
        guard status == noErr else { throw StemWriterError.status(status, "ExtAudioFileWrite") }
    }

    func close() {
        guard let file else { return }
        ExtAudioFileDispose(file)
        self.file = nil
    }

    /// For IOProc error paths — never throws, never fails stop.
    func closeQuietly() { close() }
}
