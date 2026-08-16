import Foundation

/// Normalizes a bundle path to the top-level application bundle:
/// the path up to and including the FIRST ".app" component. Chromium/Electron
/// helpers are nested .app bundles ("/Applications/Brave Browser.app/Contents/
/// Frameworks/.../Brave Browser Helper.app") — normalizing folds them onto
/// the parent app's identity. Returns nil when the path contains no .app
/// component (e.g. system framework paths).
func topLevelAppBundlePath(_ path: String) -> String? {
    let comps = path.split(separator: "/")
    guard let firstApp = comps.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
    return "/" + comps[...firstApp].joined(separator: "/")
}

struct AudioProcessSnapshot: Hashable {
    var objectID: UInt32
    var pid: pid_t
    var bundleID: String?
    var processName: String
    /// Path of the host .app bundle (e.g. "/Applications/Brave Browser.app").
    /// Helpers of an app share the parent's bundle path, so this is the true
    /// "same application" identity for grouping (Chromium/Electron render
    /// audio in helpers whose bundle IDs differ from the parent's).
    var appBundlePath: String? = nil
}

/// Groups audio-producing processes into one source per application.
/// Primary identity: the host .app bundle path (folds Chromium/Electron
/// helper processes into their parent app). Fallback: bundle ID, then
/// process name (for bundle-less system processes).
func appSources(from processes: [AudioProcessSnapshot], excludedBundleIDs: Set<String>) -> [SourceDescriptor] {
    var byPath: [String: [AudioProcessSnapshot]] = [:]
    var byBundle: [AudioProcessSnapshot] = []
    var byName: [String: [AudioProcessSnapshot]] = [:]

    for p in processes {
        if let bundle = p.bundleID, !bundle.isEmpty, excludedBundleIDs.contains(bundle) { continue }
        if let path = p.appBundlePath, let topLevel = topLevelAppBundlePath(path) {
            byPath[topLevel, default: []].append(p)
        } else if let bundle = p.bundleID, !bundle.isEmpty {
            byBundle.append(p)
        } else {
            byName[p.processName, default: []].append(p)
        }
    }

    // Fold bundle-only processes into a path group when their bundle ID is a
    // helper of any bundle in that group ("<parent>.helper…" convention).
    // Covers helpers with no NSRunningApplication record (nil path).
    var leftovers: [AudioProcessSnapshot] = []
    for p in byBundle {
        let matchesGroup: ([AudioProcessSnapshot]) -> Bool = { group in
            group.contains { member in
                guard let memberBundle = member.bundleID,
                      let pBundle = p.bundleID else { return false }
                return pBundle == memberBundle || pBundle.hasPrefix(memberBundle + ".")
            }
        }
        if let key = byPath.first(where: { matchesGroup($0.value) })?.key {
            byPath[key, default: []].append(p)
        } else {
            leftovers.append(p)
        }
    }

    // Merge path-less processes among themselves by the same helper
    // convention (e.g. Chrome + Chrome.helper when neither reports a path).
    var leftoverGroups: [[AudioProcessSnapshot]] = []
    for p in leftovers {
        let related: (AudioProcessSnapshot, AudioProcessSnapshot) -> Bool = { a, b in
            guard let aBundle = a.bundleID, let bBundle = b.bundleID else { return false }
            return aBundle == bBundle || aBundle.hasPrefix(bBundle + ".") || bBundle.hasPrefix(aBundle + ".")
        }
        if let gi = leftoverGroups.firstIndex(where: { group in group.contains { related(p, $0) } }) {
            leftoverGroups[gi].append(p)
        } else {
            leftoverGroups.append([p])
        }
    }

    var sources: [SourceDescriptor] = []

    for (path, group) in byPath {
        // Parent bundle ID = shortest in the group ("com.brave.Browser" vs
        // "com.brave.Browser.helper"); may be absent when only a helper runs.
        let parentBundle = group.compactMap(\.bundleID).min { $0.count < $1.count }
        // Prefer the parent process's own display name; a "helper"-ish name
        // means only helpers are present — fall back to the bundle's name.
        let pathName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let primaryName = parentBundle.flatMap { parent in
            group.first { $0.bundleID == parent }?.processName
        } ?? group.map(\.processName).min { $0.count < $1.count } ?? pathName
        let name = primaryName.lowercased().contains("helper") ? pathName : primaryName
        sources.append(SourceDescriptor(id: parentBundle ?? "app:\(path)", kind: .application,
                                        name: name, bundleIdentifier: parentBundle,
                                        deviceUID: nil, appBundlePath: path))
    }

    for group in leftoverGroups {
        let parentBundle = group.compactMap(\.bundleID).min { $0.count < $1.count }!
        let parentNames = group.filter { $0.bundleID == parentBundle }.map(\.processName)
        let name = parentNames.min { $0.count < $1.count } ?? parentBundle
        sources.append(SourceDescriptor(id: parentBundle, kind: .application, name: name,
                                        bundleIdentifier: parentBundle, deviceUID: nil, appBundlePath: nil))
    }

    for (name, group) in byName {
        let id = "pid:\(group.map(\.pid).min() ?? 0)"
        sources.append(SourceDescriptor(id: id, kind: .application, name: name,
                                        bundleIdentifier: nil, deviceUID: nil, appBundlePath: nil))
    }

    return sources.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
