import Foundation
import CoreAudio
import AVFoundation
import os

/// One running capture: a device (aggregate tap device or input device),
/// an IOProc, and a stem file.
///
/// Canonical-rate contract: the stem FILE is always written at
/// `canonicalSampleRate` (48 kHz) stereo Float32, regardless of what the
/// device delivers. Devices clocked by Bluetooth outputs change rate — and
/// channel count — mid-session when the headset flips between A2DP
/// (44.1 kHz stereo) and HFP (16 kHz mono) as its mic is used. Writing
/// device-rate headers made such recordings play at the wrong speed
/// (3× for 16 kHz data in a 48 kHz file). The chain instead converts the
/// delivered audio to the canonical rate through an AVAudioConverter that is
/// rebuilt whenever the device's nominal rate changes (property listener).
///
/// Threading contract:
/// - `start`/`stop` run on the control thread.
/// - The IOProc thread reads an immutable `ConversionContext` snapshot under
///   `configLock` (tryLock — on contention the chunk is skipped; a rate flip
///   happens once per headset-mode change, dropping ~5 ms there is fine) and
///   performs no allocation beyond what AVAudioConverter does internally.
/// - The rate-change listener runs on `listenerQueue` (HAL callback): it
///   re-reads the stream format, rebuilds the context (allocations fine
///   there), and swaps it under the lock.
/// - Exactly-once completion: both the IOProc error path and `stop(_:)`
///   enter `endWith(_:)`, which unconditionally enqueues on the serial
///   `teardownQueue`. The queue block checks-and-sets `ended`, tears down
///   hardware/listener and closes the writer, then fires `onEnded` on the
///   main queue. The reason reported is whichever path enqueued first.
/// - Residual race, accepted for v1: an `ExtAudioFileWrite` already executing
///   on the IOProc thread when the teardown block runs races the
///   `ExtAudioFileDispose` in `close()`. v1 accepts this window (see git
///   history; unchanged by the conversion rework).
/// One-shot flag safe to capture by an escaping input block inside a
/// C-function-pointer closure (a nested type would capture dynamic Self).
private final class FeedOnceBox {
    var done = false
}

final class CaptureChain: CaptureUnit {
    /// The one rate every stem file is written at.
    static let canonicalSampleRate: Double = 48000
    static let canonicalChannels: AVAudioChannelCount = 2

    static func canonicalAVFormat() -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32,
                      sampleRate: canonicalSampleRate,
                      channels: canonicalChannels,
                      interleaved: false)!
    }

    /// ExtAudioFile client ASBD matching `canonicalAVFormat` (non-interleaved).
    static func canonicalClientFormat() -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: canonicalSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: canonicalChannels,
            mBitsPerChannel: 32,
            mReserved: 0)
    }

    let deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope      // .input for taps and mics
    /// The file (client) format this chain writes — always canonical. Exposed
    /// so RecorderEngine writes true metadata into the session manifest.
    private let _clientFormat: AudioStreamBasicDescription
    private let writer: StemWriter
    private var ioProcID: AudioDeviceIOProcID?
    private var lastMeterAt: Double = 0
    private let teardownQueue = DispatchQueue(label: "com.sapomac.Sapo.teardown")
    private let listenerQueue = DispatchQueue(label: "com.sapomac.Sapo.rateChange")

    private var ended = false                // only touched on teardownQueue

    var onLevel: ((Float) -> Void)?          // RMS 0...1, throttled to ~10 Hz
    var onEnded: ((String) -> Void)?         // called once when capture ends
    var clientFormat: AudioStreamBasicDescription { _clientFormat }

    /// Immutable snapshot of everything the IOProc needs to turn delivered
    /// bytes into canonical-rate stereo. Swapped atomically on rate changes.
    private final class ConversionContext {
        let deviceRate: Double
        let deviceChannels: Int
        let deviceBytesPerFrame: Int
        /// nil when deviceRate == canonical (write-through fast path).
        let converter: AVAudioConverter?
        /// 2-channel non-interleaved buffer at the DEVICE rate.
        let deviceBuffer: AVAudioPCMBuffer
        /// Zero-length buffer of the same format — end-of-input signal for
        /// the converter's pull block (this SDK's block returns non-optional
        /// AVAudioBuffer).
        let emptyBuffer: AVAudioPCMBuffer

        init(rate: Double, channels: Int, bytesPerFrame: Int,
             converter: AVAudioConverter?, deviceBuffer: AVAudioPCMBuffer,
             emptyBuffer: AVAudioPCMBuffer) {
            self.deviceRate = rate
            self.deviceChannels = channels
            self.deviceBytesPerFrame = bytesPerFrame
            self.converter = converter
            self.deviceBuffer = deviceBuffer
            self.emptyBuffer = AVAudioPCMBuffer(pcmFormat: deviceBuffer.format, frameCapacity: 1)!
        }
    }

    private var context: ConversionContext
    private let contextLock: OSAllocatedUnfairLock<ConversionContext>
    private var rateListenerBlock: AudioObjectPropertyListenerBlock?
    /// Canonical-rate output; allocated once, written by the converter.
    private let canonicalBuffer: AVAudioPCMBuffer

    private init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                 writer: StemWriter, context: ConversionContext) {
        self.deviceID = deviceID
        self.scope = scope
        self.writer = writer
        self._clientFormat = Self.canonicalClientFormat()
        self.context = context
        self.contextLock = OSAllocatedUnfairLock(initialState: context)
        self.canonicalBuffer = AVAudioPCMBuffer(pcmFormat: Self.canonicalAVFormat(),
                                                frameCapacity: 16384)!
    }

    static func inputStreamFormat(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }

        // The delivered data rate is the device's NOMINAL rate (for a tap
        // aggregate: the main/output device's rate), which can differ from
        // StreamFormat's reported rate. Header must match the data.
        var nominal = Double(0)
        var nominalSize = UInt32(MemoryLayout<Double>.size)
        var nominalAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(deviceID, &nominalAddress, 0, nil, &nominalSize, &nominal) == noErr {
            asbd = reconcilingNominalRate(asbd, nominalRate: nominal)
        }
        return asbd
    }

    /// Reconcile a stream-format ASBD with the device's nominal rate: when
    /// the nominal rate is valid and differs, it wins (layout untouched).
    static func reconcilingNominalRate(_ asbd: AudioStreamBasicDescription,
                                       nominalRate: Double?) -> AudioStreamBasicDescription {
        var result = asbd
        if let nominalRate, nominalRate > 0, nominalRate != asbd.mSampleRate {
            result.mSampleRate = nominalRate
        }
        return result
    }

    /// Rate-only converter between two 2-channel float formats. Returns nil
    /// when no conversion is needed (rates match).
    static func makeRateConverter(fromRate: Double, toRate: Double) -> AVAudioConverter? {
        guard fromRate != toRate,
              let from = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: fromRate, channels: canonicalChannels,
                                       interleaved: false),
              let converter = AVAudioConverter(from: from, to: canonicalAVFormat()) else { return nil }
        return converter
    }

    /// Distribute delivered input into the canonical 2-channel
    /// (non-interleaved) device buffer, handling both HAL layouts:
    /// interleaved (1 buffer, n channels) and non-interleaved (1 buffer per
    /// channel). Mono is duplicated to both channels, >2 channels take the
    /// first two. Returns frames filled.
    @discardableResult
    static func fillDeviceBuffer(_ buffer: AVAudioPCMBuffer,
                                 from abl: UnsafePointer<AudioBufferList>,
                                 byteCount: Int, srcChannels: Int, srcBytesPerFrame: Int) -> AVAudioFrameCount {
        guard let l = buffer.floatChannelData?[0], let r = buffer.floatChannelData?[1],
              srcChannels >= 1 else { return 0 }
        let ablPtr = UnsafeMutablePointer<AudioBufferList>(mutating: abl)
        let nBuffers = Int(ablPtr.pointee.mNumberBuffers)

        // Non-interleaved: one buffer per channel — straight copy per channel.
        // This SDK exposes mBuffers as a single AudioBuffer, but the HAL lays
        // out nBuffers AudioBuffers contiguously from its address (C
        // flexible-array pattern): the second one lives at +stride.
        if nBuffers >= 2 {
            let first = ablPtr.pointee.mBuffers
            let second = withUnsafePointer(to: &ablPtr.pointee.mBuffers) { firstPtr in
                UnsafeRawPointer(firstPtr)
                    .advanced(by: MemoryLayout<AudioBuffer>.stride)
                    .assumingMemoryBound(to: AudioBuffer.self).pointee
            }
            let frames = min(Int(first.mDataByteSize / 4), Int(buffer.frameCapacity))
            for (dst, ch) in zip([l, r], [first, second]) {
                guard let src = ch.mData else { return 0 }
                dst.update(from: src.assumingMemoryBound(to: Float.self), count: frames)
            }
            buffer.frameLength = AVAudioFrameCount(frames)
            return AVAudioFrameCount(frames)
        }

        // Interleaved: single buffer, n channels packed per frame.
        guard let first = ablPtr.pointee.mBuffers.mData,
              srcBytesPerFrame >= srcChannels * 4 else { return 0 }
        let frames = min(Int(byteCount / max(srcBytesPerFrame, 1)), Int(buffer.frameCapacity))
        let s = first.assumingMemoryBound(to: Float.self)
        switch srcChannels {
        case 1:
            for i in 0..<frames { let v = s[i]; l[i] = v; r[i] = v }
        default:
            for i in 0..<frames { l[i] = s[i * srcChannels]; r[i] = s[i * srcChannels + 1] }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return AVAudioFrameCount(frames)
    }

    static func make(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                     stemURL: URL, format: StemFormat) throws -> CaptureChain {
        guard let deviceFormat = inputStreamFormat(deviceID: deviceID, scope: scope) else {
            throw StemWriterError.status(OSStatus(paramErr), "no input stream format on device \(deviceID)")
        }
        let writer = try StemWriter(url: stemURL,
                                    clientFormat: canonicalClientFormat(), format: format)
        let context = makeContext(deviceFormat: deviceFormat)
        return CaptureChain(deviceID: deviceID, scope: scope, writer: writer, context: context)
    }

    private static func makeContext(deviceFormat: AudioStreamBasicDescription) -> ConversionContext {
        let channels = max(Int(deviceFormat.mChannelsPerFrame), 1)
        let bytesPerFrame = max(Int(deviceFormat.mBytesPerFrame), channels * 4)
        let rate = deviceFormat.mSampleRate
        let deviceFormatAV = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                           sampleRate: rate, channels: canonicalChannels,
                                           interleaved: false)!
        let deviceBuffer = AVAudioPCMBuffer(pcmFormat: deviceFormatAV, frameCapacity: 16384)!
        let emptyBuffer = AVAudioPCMBuffer(pcmFormat: deviceFormatAV, frameCapacity: 1)!
        let converter = makeRateConverter(fromRate: rate, toRate: canonicalSampleRate)
        return ConversionContext(rate: rate, channels: channels, bytesPerFrame: bytesPerFrame,
                                 converter: converter, deviceBuffer: deviceBuffer,
                                 emptyBuffer: emptyBuffer)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        installRateListener()

        // The C-function-pointer closure must capture nothing (no dynamic
        // Self, no locals): everything flows through `clientData` → `chain`.
        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<CaptureChain>.fromOpaque(clientData).takeUnretainedValue()
            chain.process(inputData: inputData)
            return noErr
        }

        let status = AudioDeviceCreateIOProcID(deviceID, ioProc, selfPtr, &ioProcID)
        guard status == noErr else {
            writer.closeQuietly()
            throw StemWriterError.status(status, "AudioDeviceCreateIOProcID")
        }
        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            stopHardware()
            writer.closeQuietly()
            throw StemWriterError.status(startStatus, "AudioDeviceStart")
        }
    }

    /// Realtime body, called on the IOProc thread with the delivered input.
    private func process(inputData: UnsafePointer<AudioBufferList>) {
        // the HAL NULLs mData for disabled streams.
        guard inputData.pointee.mNumberBuffers > 0,
              inputData.pointee.mBuffers.mData != nil,
              inputData.pointee.mBuffers.mDataByteSize > 0 else {
            return
        }
        let byteSize = Int(inputData.pointee.mBuffers.mDataByteSize)

        // Snapshot the conversion config (tryLock: contention only at a rate
        // flip — skipping one chunk there beats blocking real-time).
        guard let ctx = contextLock.withLockIfAvailable({ $0 }) else { return }

        let framesIn = CaptureChain.fillDeviceBuffer(ctx.deviceBuffer, from: inputData,
                                                     byteCount: byteSize,
                                                     srcChannels: ctx.deviceChannels,
                                                     srcBytesPerFrame: ctx.deviceBytesPerFrame)
        guard framesIn > 0 else { return }

        // meter (throttled): RMS over the canonical 2-channel buffer
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterAt > 0.1 {
            lastMeterAt = now
            emitLevel(buffer: ctx.deviceBuffer, frames: framesIn)
        }

        do {
            if let converter = ctx.converter {
                var convertError: NSError?
                // AVAudioConverterInputBlock is escaping — capture state in a
                // box, not a local var.
                let fed = FeedOnceBox()
                // This SDK's input block MUST set outStatus: .haveData while
                // supplying data, .noDataNow (+ zero-length buffer) after.
                // Leaving it unset reads as end-of-stream — the converter then
                // emits nothing, forever (silently empty stems).
                let inputBlock: AVAudioConverterInputBlock = { _, status in
                    if fed.done {
                        status.pointee = .noDataNow
                        return ctx.emptyBuffer
                    }
                    fed.done = true
                    status.pointee = .haveData
                    return ctx.deviceBuffer
                }
                let status = converter.convert(to: canonicalBuffer,
                                               error: &convertError,
                                               withInputFrom: inputBlock)
                guard status != .error, canonicalBuffer.frameLength > 0 else {
                    if let convertError { throw convertError }
                    return
                }
                try writeBuffer(canonicalBuffer)
            } else {
                ctx.deviceBuffer.frameLength = framesIn
                try writeBuffer(ctx.deviceBuffer)
            }
        } catch {
            endWith("deviceLost")
        }
    }

    private func installRateListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, !self.ended else { return }
            guard let fresh = CaptureChain.inputStreamFormat(deviceID: self.deviceID, scope: self.scope) else { return }
            let newContext = CaptureChain.makeContext(deviceFormat: fresh)
            self.contextLock.withLock { $0 = newContext }
        }
        rateListenerBlock = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
    }

    private func removeRateListener() {
        guard let block = rateListenerBlock else { return }
        rateListenerBlock = nil
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, block)
    }

    /// RMS meter, throttled upstream. Uses the device buffer's first channel
    /// (mono-fied content is duplicated to both).
    private func emitLevel(buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) {
        guard let l = buffer.floatChannelData?[0] else { return }
        var sum: Float = 0
        for i in 0..<Int(frames) { let v = l[i]; sum += v * v }
        let rms = frames > 0 ? sqrt(sum / Float(frames)) : 0
        DispatchQueue.main.async { [weak self] in self?.onLevel?(min(rms * 4, 1)) }
    }

    /// Write a 2-channel non-interleaved AVAudioPCMBuffer through an
    /// AudioBufferList. Buffer data lives as long as this synchronous call.
    private func writeBuffer(_ buffer: AVAudioPCMBuffer) throws {
        guard let l = buffer.floatChannelData?[0], let r = buffer.floatChannelData?[1] else { return }
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        list[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(buffer.frameLength) * 4, mData: l)
        list[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(buffer.frameLength) * 4, mData: r)
        try writer.write(list.unsafeMutablePointer, frameCount: buffer.frameLength)
    }

    private func endWith(_ reason: String) {
        // Both entry paths (IOProc write error, control-thread stop) enqueue
        // unconditionally; the check-and-set of `ended` happens inside the
        // serial block, so completion is exactly-once without a lock. The
        // reason reported is whichever path enqueued first.
        teardownQueue.async { [self] in
            guard !ended else { return }
            ended = true
            removeRateListener()
            stopHardware()
            writer.closeQuietly()
            DispatchQueue.main.async { self.onEnded?(reason) }
        }
    }

    private func stopHardware() {
        if let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
    }

    /// Graceful stop from owner.
    func stop(reason: String) { endWith(reason) }
}
