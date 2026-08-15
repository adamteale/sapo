import Foundation
import CoreAudio

/// Thin wrapper over Core Audio object property reads.
enum AudioProperty {
    static func readArray<T>(of type: T.Type, objectID: AudioObjectID,
                             selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<T>.stride) else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buffer) == noErr else { return nil }
        return Array(UnsafeBufferPointer(start: buffer, count: count))
    }

    static func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        guard let cf: CFString = readArray(of: CFString.self, objectID: objectID,
                                           selector: selector, scope: scope)?.first else { return nil }
        return cf as String
    }

    static func readUInt32(objectID: AudioObjectID, selector: AudioObjectPropertySelector,
                           scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        readArray(of: UInt32.self, objectID: objectID, selector: selector, scope: scope)?.first
    }

    static var defaultOutputDeviceID: AudioObjectID? {
        readUInt32(objectID: AudioObjectID(kAudioObjectSystemObject),
                   selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    static var defaultOutputDeviceUID: String? {
        guard let id = defaultOutputDeviceID else { return nil }
        return readString(objectID: id, selector: kAudioDevicePropertyDeviceUID)
    }

    static var defaultInputDeviceID: AudioObjectID? {
        readUInt32(objectID: AudioObjectID(kAudioObjectSystemObject),
                   selector: kAudioHardwarePropertyDefaultInputDevice)
    }
}
