import Foundation

struct AudioProcessSnapshot: Hashable {
    var objectID: UInt32
    var pid: pid_t
    var bundleID: String?
    var processName: String
}

/// Groups audio-producing processes into one source per application
/// (bundle ID merges helpers; name merges bundle-less processes).
func appSources(from processes: [AudioProcessSnapshot], excludedBundleIDs: Set<String>) -> [SourceDescriptor] {
    var byBundle: [String: [AudioProcessSnapshot]] = [:]
    var byName: [String: [AudioProcessSnapshot]] = [:]

    for p in processes {
        if let bundle = p.bundleID, !bundle.isEmpty {
            guard !excludedBundleIDs.contains(bundle) else { continue }
            byBundle[bundle, default: []].append(p)
        } else {
            byName[p.processName, default: []].append(p)
        }
    }

    var sources: [SourceDescriptor] = byBundle.map { bundle, group in
        // Prefer a non-helper process name when available (longest matching app name heuristic: use NSRunningApplication at call site via processName passed in).
        let name = group.map(\.processName).sorted { $0.count < $1.count }.first ?? bundle
        return SourceDescriptor(id: bundle, kind: .application, name: name,
                                bundleIdentifier: bundle, deviceUID: nil)
    }

    for (name, group) in byName {
        let id = "pid:\(group.map(\.pid).min() ?? 0)"
        sources.append(SourceDescriptor(id: id, kind: .application, name: name,
                                        bundleIdentifier: nil, deviceUID: nil))
    }

    return sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
