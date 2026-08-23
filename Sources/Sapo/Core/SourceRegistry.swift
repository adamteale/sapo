import Foundation
import AppKit
import CoreAudio

/// Discovers recordable sources (apps producing audio + input devices) from Core Audio.
final class SourceRegistry {
    static let excludedBundleIDs: Set<String> = [
        "com.sapomac.Sapo",            // never record ourselves
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
            let appPath = NSRunningApplication(processIdentifier: pid)?.bundleURL?.path
            return AudioProcessSnapshot(objectID: objectID, pid: pid,
                                        bundleID: bundleID, processName: name,
                                        appBundlePath: appPath)
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
    /// Primary match: host .app bundle path (folds Chromium/Electron helpers
    /// into the parent app's tap — they share the parent's bundle path).
    /// Legacy descriptors (v0.1.0 manifests, no path): bundle ID equality plus
    /// the helper convention prefix ("<parent>.helper…"), then name matching
    /// for bundle-less sources.
    func processObjectIDs(for source: SourceDescriptor) -> [AudioObjectID] {
        let snapshots = processObjectSnapshots()
        let matched: [AudioProcessSnapshot]
        if let sourcePath = source.appBundlePath {
            // Compare on normalized top-level paths: nested helper .app paths
            // fold onto the parent app's identity.
            let byPath = snapshots.filter {
                $0.appBundlePath.flatMap(topLevelAppBundlePath) == sourcePath
            }
            if !byPath.isEmpty {
                // ALSO fold in path-less helpers (nil bundleURL from
                // NSRunningApplication) whose bundle ID is a helper of any
                // path-group member — grouping already treats them as the
                // same application; resolution must match.
                let groupBundles = Set(byPath.compactMap(\.bundleID))
                var matchedAll = byPath
                for snap in snapshots where snap.appBundlePath == nil {
                    if let bundle = snap.bundleID,
                       groupBundles.contains(where: { bundle.hasPrefix($0 + ".") }) {
                        matchedAll.append(snap)
                    }
                }
                matched = matchedAll
            } else {
                matched = snapshots.filter(legacyBundleMatch(source: source))
            }
        } else {
            matched = snapshots.filter(legacyBundleMatch(source: source))
        }
        return matched.map { AudioObjectID($0.objectID) }
    }

    private func legacyBundleMatch(source: SourceDescriptor) -> (AudioProcessSnapshot) -> Bool {
        { snapshot in
            if let bundle = snapshot.bundleID, !bundle.isEmpty {
                guard let parent = source.bundleIdentifier, parent == source.id else { return false }
                return bundle == parent || bundle.hasPrefix(parent + ".")
            }
            return snapshot.processName == source.name
        }
    }
}
