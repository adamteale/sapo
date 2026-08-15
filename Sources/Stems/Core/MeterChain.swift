import Foundation
import CoreAudio

/// Meter-only capture chain: an IOProc that computes RMS level and writes
/// nothing. Realtime discipline mirrors CaptureChain — see that file for
/// SDK-exact IOProc signatures on this machine (non-optional inputData,
/// NULL mData for disabled streams).
final class MeterChain {
    private let deviceID: AudioObjectID
    private let scope: AudioObjectPropertyScope
    private let bytesPerFrame: Int
    private let teardownQueue = DispatchQueue(label: "com.stemsapp.Stems.meterTeardown")
    private var ioProcID: AudioDeviceIOProcID?
    private var lastMeterAt: Double = 0
    private var ended = false          // teardownQueue-confined (see stop())

    /// Owned tap session for application sources; nil for input devices.
    private var tap: ProcessTapSession?
    var onLevel: ((Float) -> Void)?    // ~10 Hz, delivered on main

    private init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                 bytesPerFrame: Int, tap: ProcessTapSession?) {
        self.deviceID = deviceID
        self.scope = scope
        self.bytesPerFrame = bytesPerFrame
        self.tap = tap
    }

    static func make(deviceID: AudioObjectID, scope: AudioObjectPropertyScope,
                     tap: ProcessTapSession?) throws -> MeterChain {
        guard let asbd = CaptureChain.inputStreamFormat(deviceID: deviceID, scope: scope) else {
            throw StemWriterError.status(OSStatus(paramErr), "no input stream format on meter device \(deviceID)")
        }
        return MeterChain(deviceID: deviceID, scope: scope,
                          bytesPerFrame: Int(asbd.mBytesPerFrame), tap: tap)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // IOProc mirrors CaptureChain's shape exactly; only the meter block
        // and (no) write differ.
        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<MeterChain>.fromOpaque(clientData).takeUnretainedValue()

            // inputData is a plain UnsafePointer<AudioBufferList> on this SDK;
            // the HAL NULLs mData for disabled streams.
            guard inputData.pointee.mNumberBuffers > 0,
                  let data = inputData.pointee.mBuffers.mData,
                  inputData.pointee.mBuffers.mDataByteSize > 0 else {
                return noErr
            }

            let byteSize = Int(inputData.pointee.mBuffers.mDataByteSize)

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
            return noErr
        }

        let status = AudioDeviceCreateIOProcID(deviceID, ioProc, selfPtr, &ioProcID)
        guard status == noErr else {
            disposeTap()
            throw StemWriterError.status(status, "AudioDeviceCreateIOProcID (meter)")
        }
        let startStatus = AudioDeviceStart(deviceID, ioProcID)
        guard startStatus == noErr else {
            stopHardware()
            disposeTap()
            throw StemWriterError.status(startStatus, "AudioDeviceStart (meter)")
        }
    }

    /// Idempotent; safe from any thread (teardown hops the serial queue).
    func stop() {
        teardownQueue.async { [self] in
            guard !ended else { return }
            ended = true
            stopHardware()
            disposeTap()
        }
    }

    /// Tap ownership is transferred to this chain, so disposal happens exactly
    /// here: on start()'s failure path (control thread) or in the serial
    /// teardown block. Nilling `tap` on both paths means a later stop() cannot
    /// double-dispose (ProcessTapSession.dispose is idempotent anyway).
    private func disposeTap() {
        tap?.dispose()
        tap = nil
    }

    private func stopHardware() {
        if let ioProcID {
            AudioDeviceStop(deviceID, ioProcID)
            AudioDeviceDestroyIOProcID(deviceID, ioProcID)
        }
        ioProcID = nil
    }
}
