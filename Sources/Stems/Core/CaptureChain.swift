import Foundation
import CoreAudio

/// One running capture: a device (aggregate tap device or input device),
/// an IOProc, and a stem file.
///
/// Threading contract:
/// - `start`/`stop` run on the control thread.
/// - The IOProc thread only reads `ended` and writes audio into the writer. It
///   never tears down hardware or closes the file synchronously: `endWith(_:)`
///   flips `ended` and hops the teardown (AudioDeviceStop, DestroyIOProcID,
///   writer.closeQuietly) onto the serial `teardownQueue`, then fires `onEnded`
///   on the main queue.
/// - `ended` is a plain Bool read/written from both the IOProc thread and the
///   control thread without a lock. Race window: both may see `false` and both
///   enqueue teardown — harmless, because teardown is idempotent (ioProcID is
///   cleared, writer.close() no-ops once the file is nil) and serialized on the
///   single teardownQueue.
final class CaptureChain {
    let deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope      // .input for taps and mics
    private let writer: StemWriter
    private var ioProcID: AudioDeviceIOProcID?
    private var lastMeterAt: Double = 0
    private let teardownQueue = DispatchQueue(label: "com.stemsapp.Stems.teardown")

    var onLevel: ((Float) -> Void)?          // RMS 0...1, throttled to ~10 Hz
    var onEnded: ((String) -> Void)?         // called once when capture ends

    private var ended = false

    init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope, writer: StemWriter) {
        self.deviceID = deviceID
        self.scope = scope
        self.writer = writer
    }

    private static func inputFormat(deviceID: AudioObjectID, scope: AudioObjectPropertyScope) -> AudioStreamBasicDescription? {
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
        guard let clientFormat = inputFormat(deviceID: deviceID, scope: scope) else {
            throw StemWriterError.status(OSStatus(paramErr), "no input stream format on device \(deviceID)")
        }
        let writer = try StemWriter(url: stemURL, clientFormat: clientFormat, format: format)
        return CaptureChain(deviceID: deviceID, scope: scope, writer: writer)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<CaptureChain>.fromOpaque(clientData).takeUnretainedValue()

            // inputData is a plain UnsafePointer<AudioBufferList> on this SDK;
            // the HAL NULLs mData for disabled streams.
            guard !chain.ended, inputData.pointee.mNumberBuffers > 0,
                  let data = inputData.pointee.mBuffers.mData,
                  inputData.pointee.mBuffers.mDataByteSize > 0 else {
                return noErr
            }

            let byteSize = Int(inputData.pointee.mBuffers.mDataByteSize)
            let asbd = CaptureChain.inputFormat(deviceID: chain.deviceID, scope: chain.scope)
            let bytesPerFrame = Int(asbd?.mBytesPerFrame ?? 4)
            let frameCount = UInt32(byteSize / max(bytesPerFrame, 1))

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
        guard !ended else { return }
        ended = true

        // Never tear down hardware or close the file on the IOProc thread;
        // hop to a serial queue, then report completion on main.
        teardownQueue.async { [self] in
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
