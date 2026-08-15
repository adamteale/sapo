import Foundation
import CoreAudio

/// Resolves a source to a capturable device: process tap + aggregate for
/// applications, input device for microphones. Returns nil when the source
/// cannot be resolved right now (app not producing audio / device absent).
enum SourceResolver {
    static func resolve(source: SourceDescriptor, registry: SourceRegistry) -> (deviceID: AudioObjectID, tap: ProcessTapSession?)? {
        switch source.kind {
        case .application:
            let objectIDs = registry.processObjectIDs(for: source)
            guard !objectIDs.isEmpty,
                  let tap = try? ProcessTapSession.create(processObjectIDs: objectIDs, name: source.name) else { return nil }
            return (tap.aggregateDeviceID, tap)
        case .microphone:
            guard let uid = source.deviceUID,
                  let deviceID = registry.deviceID(forUID: uid) else { return nil }
            return (deviceID, nil)
        }
    }
}
