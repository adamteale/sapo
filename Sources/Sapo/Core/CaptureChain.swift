import Foundation
import CoreAudio

/// One running capture: a device (aggregate tap device or input device),
/// an IOProc, and a stem file.
///
/// Threading contract:
/// - `start`/`stop` run on the control thread.
/// - The IOProc thread writes audio into the writer and updates the meter; it
///   never tears down hardware or closes the file synchronously. On a write
///   error it hops teardown onto the serial `teardownQueue`.
/// - Exactly-once completion: both the IOProc error path and `stop(_:)` enter
///   `endWith(_:)`, which unconditionally enqueues on the serial
///   `teardownQueue`. The queue block checks-and-sets `ended` (so `ended` is
///   only ever touched on that one serial queue — no lock needed), tears down
///   hardware and closes the writer, then fires `onEnded` on the main queue.
///   The reason reported is whichever path enqueued first.
/// - Residual race, accepted for v1: an `ExtAudioFileWrite` already executing
///   on the IOProc thread when the teardown block runs races the
///   `ExtAudioFileDispose` in `close()`. `AudioDeviceStop`'s header only says
///   it "stops IO for the given AudioDeviceIOProcID" — no synchrony guarantee
///   — so a write may still be in flight while the file is disposed. v1
///   accepts this window and does not attempt to close it.
final class CaptureChain: CaptureUnit {
    let deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope      // .input for taps and mics
    /// The client (HAL input stream) format this chain was built with — exposed
    /// so RecorderEngine can write real sample-rate/channel metadata into the
    /// session manifest after creation (Task 7 ruling 1).
    private let _clientFormat: AudioStreamBasicDescription
    private let writer: StemWriter
    private let bytesPerFrame: Int          // hoisted from the HAL read in make()
    private var ioProcID: AudioDeviceIOProcID?
    private var lastMeterAt: Double = 0
    private let teardownQueue = DispatchQueue(label: "com.sapomac.Sapo.teardown")

    var onLevel: ((Float) -> Void)?          // RMS 0...1, throttled to ~10 Hz
    var onEnded: ((String) -> Void)?         // called once when capture ends
    var clientFormat: AudioStreamBasicDescription { _clientFormat }

    private var ended = false                // only touched on teardownQueue

    init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
         writer: StemWriter, bytesPerFrame: Int,
         clientFormat: AudioStreamBasicDescription) {
        self.deviceID = deviceID
        self.scope = scope
        self.writer = writer
        self.bytesPerFrame = bytesPerFrame
        self._clientFormat = clientFormat
    }

    static func inputStreamFormat(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamFormat,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &asbd) == noErr,
              asbd.mSampleRate > 0 else { return nil }
        return asbd
    }

    static func make(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                     stemURL: URL, format: StemFormat) throws -> CaptureChain {
        guard let clientFormat = inputStreamFormat(deviceID: deviceID, scope: scope) else {
            throw StemWriterError.status(OSStatus(paramErr), "no input stream format on device \(deviceID)")
        }
        // Hoisted once here, never re-queried in the IOProc: HAL property reads
        // can take HAL-internal locks and are not realtime-safe.
        let bytesPerFrame = Int(clientFormat.mBytesPerFrame)
        let writer = try StemWriter(url: stemURL, clientFormat: clientFormat, format: format)
        return CaptureChain(deviceID: deviceID, scope: scope, writer: writer,
                            bytesPerFrame: bytesPerFrame, clientFormat: clientFormat)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<CaptureChain>.fromOpaque(clientData).takeUnretainedValue()

            // inputData is a plain UnsafePointer<AudioBufferList> on this SDK;
            // the HAL NULLs mData for disabled streams.
            guard inputData.pointee.mNumberBuffers > 0,
                  let data = inputData.pointee.mBuffers.mData,
                  inputData.pointee.mBuffers.mDataByteSize > 0 else {
                return noErr
            }

            let byteSize = Int(inputData.pointee.mBuffers.mDataByteSize)
            // Pure arithmetic only — the HAL format was read once in make().
            let frameCount = UInt32(byteSize / max(chain.bytesPerFrame, 1))

            // meter (throttled): RMS over Float32 samples
            let now = ProcessInfo.processInfo.systemUptime
            if now - chain.lastMeterAt > 0.1 {
                chain.lastMeterAt = now
                let samples = data.bindMemory(to: Float.self, capacity: byteSize / 4)
                var sum: Float = 0
                for i in 0..<(byteSize / 4) { let v = samples[i]; sum += v * v }
                let rms = byteSize >= 4 ? sqrt(sum / Float(byteSize / 4)) : 0
                if let onLevel = chain.onLevel {
                    DispatchQueue.main.async { onLevel(min(rms * 4, 1)) } // gain for visibility
                }
            }

            do {
                try chain.writer.write(inputData, frameCount: frameCount)
            } catch {
                chain.endWith("deviceLost")
                return noErr
            }
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

    private func endWith(_ reason: String) {
        // Both entry paths (IOProc write error, control-thread stop) enqueue
        // unconditionally; the check-and-set of `ended` happens inside the
        // serial block, so completion is exactly-once without a lock. The
        // reason reported is whichever path enqueued first.
        teardownQueue.async { [self] in
            guard !ended else { return }
            ended = true
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
