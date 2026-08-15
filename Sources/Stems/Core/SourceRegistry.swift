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
            let name = Self.displayName(pid: pid, bundleID: bundleID)
            return AudioProcessSnapshot(objectID: objectID, pid: pid,
                                        bundleID: bundleID, processName: name)
        }
    }

    /// Human-readable process name: localized app name → bundle ID tail →
    /// executable file name → "Process <pid>". Empty strings are treated as
    /// absent: bundle-less CLI processes (e.g. `afplay`) expose "" for both
    /// localizedName and bundleID, which otherwise collapsed into nameless
    /// groups (Task 6 smoke protocol requires afplay to show by name).
    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let localized = app.localizedName, !localized.isEmpty {
            return localized
        }
        if let bundle = bundleID, !bundle.isEmpty,
           let tail = bundle.components(separatedBy: ".").last, !tail.isEmpty {
            return tail
        }
        if let exec = executableName(pid: pid) {
            return exec
        }
        return "Process \(pid)"
    }

    private static func executableName(pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4096) is a C macro unavailable to Swift.
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let fullPath = String(cString: path)
        guard let last = fullPath.split(separator: "/").last, !last.isEmpty else { return nil }
        return String(last)
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
