import Foundation
import AppKit
import CoreAudio

/// Discovers recordable sources (apps producing audio + input devices) from Core Audio.
final class SourceRegistry {
    static let excludedBundleIDs: Set<String> = [
        "com.stemsapp.Stems",          // never record ourselves
        "com.apple.audio.CoreAudioServer",
        "com.apple.audioserverd",
    ]

    func processObjectSnapshots() -> [AudioProcessSnapshot] {
        let objects = AudioProperty.readArray(of: AudioObjectID.self,
                                              objectID: AudioObjectID(kAudioObjectSystemObject),
                                              selector: kAudioHardwarePropertyProcessObjectList) ?? []
        return objects.compactMap { objectID in
            guard let pidInt = AudioProperty.readUInt32(objectID: objectID, selector: kAudioProcessPropertyPID) else { return nil }
            let pid = pid_t(pidInt)
            let bundleID = AudioProperty.readString(objectID: objectID, selector: kAudioProcessPropertyBundleID)
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName
                ?? bundleID?.components(separatedBy: ".").last
                ?? "Process \(pid)"
            return AudioProcessSnapshot(objectID: objectID, pid: pid,
                                        bundleID: bundleID, processName: name)
        }
    }

    func currentAppSources() -> [SourceDescriptor] {
        appSources(from: processObjectSnapshots(), excludedBundleIDs: Self.excludedBundleIDs)
    }

    /// Input-capable devices as mic sources.
    func currentMicSources() -> [SourceDescriptor] {
        let devices = AudioProperty.readArray(of: AudioObjectID.self,
                                              objectID: AudioObjectID(kAudioObjectSystemObject),
                                              selector: kAudioHardwarePropertyDevices) ?? []
        return devices.compactMap { deviceID -> SourceDescriptor? in
            // device has input streams?
            let streamCount = AudioProperty.readArray(of: UInt32.self, objectID: deviceID,
                                                      selector: kAudioDevicePropertyStreams,
                                                      scope: kAudioObjectPropertyScopeInput)?.count ?? 0
            guard streamCount > 0,
                  let uid = AudioProperty.readString(objectID: deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = AudioProperty.readString(objectID: deviceID, selector: kAudioObjectPropertyName) else { return nil }
            return SourceDescriptor(id: uid, kind: .microphone, name: name,
                                    bundleIdentifier: nil, deviceUID: uid)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func deviceID(forUID uid: String) -> AudioObjectID? {
        let devices = AudioProperty.readArray(of: AudioObjectID.self,
                                              objectID: AudioObjectID(kAudioObjectSystemObject),
                                              selector: kAudioHardwarePropertyDevices) ?? []
        return devices.first {
            AudioProperty.readString(objectID: $0, selector: kAudioDevicePropertyDeviceUID) == uid
        }
    }
}

extension SourceRegistry {
    /// Resolve ANY app SourceDescriptor to its current process object IDs.
    /// Bundle-based sources match by bundle ID; name-grouped (bundle-less)
    /// sources match by display name.
    func processObjectIDs(for source: SourceDescriptor) -> [AudioObjectID] {
        let snapshots = processObjectSnapshots().filter {
            if let bundle = $0.bundleID, !bundle.isEmpty {
                return bundle == source.bundleIdentifier && bundle == source.id
            }
            return $0.processName == source.name
        }
        return snapshots.map { AudioObjectID($0.objectID) }
    }
}
