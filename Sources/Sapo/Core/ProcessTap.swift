import Foundation
import CoreAudio

/// A Core Audio process tap bound to an aggregate device whose input stream is
/// the mix of the tapped processes' output audio. Capture the aggregate device's
/// input via CaptureChain, then `dispose()`.
///
/// Non-destructive: the tap is created with `.unmuted` mute behavior, so the
/// tapped apps keep playing through the speakers while we record their mix.
struct ProcessTapSession {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    private var disposed = false

    static func create(processObjectIDs: [AudioObjectID], name: String) throws -> ProcessTapSession {
        guard !processObjectIDs.isEmpty else {
            throw StemWriterError.status(OSStatus(paramErr), "no process objects for \(name)")
        }
        guard let outputUID = AudioProperty.defaultOutputDeviceUID,
              let outputID = AudioProperty.defaultOutputDeviceID else {
            throw StemWriterError.status(OSStatus(paramErr), "no default output device")
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.muteBehavior = .unmuted   // non-destructive: app audio keeps playing

        var tapID = AudioObjectID()
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createStatus == noErr else {
            throw StemWriterError.status(createStatus, "AudioHardwareCreateProcessTap")
        }

        let aggregateUID = "Sapo.Tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Sapo — \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            // The output device drives the tap's clock. (The brief's
            // kAudioAggregateDeviceMainDeviceKey constant does not exist in this
            // SDK's headers — the current spelling is MainSubDeviceKey, "master".)
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Header documents a CFNumber; `true` would bridge to CFBoolean.
            kAudioAggregateDeviceIsPrivateKey: 1,
            // Tap UUIDs wrapped in a sub-tap dict: the header documents the tap
            // list as "CFArray of CFDictionaries" (keys in the AudioTap section,
            // kAudioSubTapUIDKey). A bare [uuidString] array compiles and returns
            // noErr but silently yields an aggregate with NO tap attached (no
            // input stream) — verified against the SDK at runtime (Task 6).
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapDescription.uuid.uuidString]],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: 0]
            ],
        ]
        var aggregateID = AudioObjectID()
        let cfDescription = description as CFDictionary
        let aggStatus = AudioHardwareCreateAggregateDevice(cfDescription, &aggregateID)
        guard aggStatus == noErr else {
            AudioHardwareDestroyProcessTap(tapID)
            throw StemWriterError.status(aggStatus, "AudioHardwareCreateAggregateDevice")
        }
        _ = outputID
        return ProcessTapSession(tapID: tapID, aggregateDeviceID: aggregateID)
    }

    mutating func dispose() {
        guard !disposed else { return }
        disposed = true
        // Destroy the process tap first — the aggregate device may still be
        // referenced by an IOProc that reads from the tap. Destroying the
        // aggregate first can cause a crash or hang.
        AudioHardwareDestroyProcessTap(tapID)
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
    }
}
