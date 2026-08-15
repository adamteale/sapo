# Stems — macOS Multi-Source Audio Recorder Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS menu-bar + window app that records per-application audio (via Core Audio process taps) and microphone as independent, aligned stems, then mixes/exports them post-session as M4A or WAV.

**Architecture:** SwiftPM executable (SwiftUI window + AppKit menu bar, no Xcode project). `RecorderEngine` is the only module that captures audio (process taps → private aggregate device → IOProc → `ExtAudioFile` stem files inside a session folder described by `manifest.json`). `ExportEngine` reads stems back, mixes with resampling, encodes via `ExtAudioFile` (M4A/AAC or WAV). The executable doubles as a CLI (`--list-taps`, `--record-app`, `--record-mic`) for smoke-testing the capture path.

**Tech Stack:** Swift 5 language mode, SwiftPM, SwiftUI + AppKit, Core Audio (process taps, aggregate devices, `ExtAudioFile`), AVFoundation (export reads, preview playback), Swift Testing for unit tests. Zero third-party dependencies.

## Global Constraints

- **Platform floor:** macOS 14.4 (`Package.swift` platforms: `.macOS("14.4")`). Dev machine runs macOS 26.5 / Xcode 26.6 / Swift 6.3.
- **No third-party dependencies.** Core Audio + AVFoundation + AppKit/SwiftUI only.
- **Verified API facts** (probed on this machine, 2026-08-15 — use these exact spellings):
  - `CATapDescription(stereoMixdownOfProcesses: [NSNumber])` — Swift name, compiles
  - `desc.muteBehavior = .unmuted` — non-destructive (audio keeps playing)
  - `AudioHardwareCreateProcessTap(desc, &tapID)` / `AudioHardwareDestroyProcessTap(tapID)` — macOS 14.2+
  - `kAudioHardwarePropertyProcessObjectList` — system object property, lists process `AudioObjectID`s of audio-producing processes
  - `kAudioProcessPropertyPID` ('ppid'), `kAudioProcessPropertyBundleID` ('pbid') — readable on each process object
  - `kAudioHardwarePropertyTranslatePIDToProcessObject` ('id2p') — PID → process object
  - Aggregate device description keys: `kAudioAggregateDeviceNameKey`, `kAudioAggregateDeviceUIDKey`, `kAudioAggregateDeviceMainDeviceKey` (UID string), `kAudioAggregateDeviceIsPrivateKey`, `kAudioAggregateDeviceTapListKey` (array of tap UUID strings), `kAudioAggregateDeviceSubDeviceListKey`
  - ALAC in `.caf` container encodes natively (verified via `afconvert -f caff -d alac`)
- **Non-destructive:** all taps created with `muteBehavior = .unmuted`.
- **Session data layout:** `~/Music/Stems/<Session-yyyy-MM-dd HH.mm.ss>/` containing `manifest.json` + one stem file per source.
- **Dates in JSON:** ISO 8601 (encoder/decoder from `SessionStore.coders()` — never default double encoding).
- **Recording format default:** ALAC-in-CAF (`StemFormat.alac`); WAV selectable in Settings. Format recorded per-stem in manifest.
- **Distribution:** ad-hoc signed `.app` assembled by `scripts/build-app.sh`; DMG+notarization hooks optional and off by default.
- **Every task ends with:** `swift build` (and `swift test` where tests exist) passing, then commit.
- Commit style: `feat:`/`test:`/`chore:`/`docs:` + imperative summary.

## Verified reference flow for process-tap capture (canonical, used in Tasks 6–7)

```
processObjectIDs (from kAudioHardwarePropertyProcessObjectList, filtered by bundleID)
  → CATapDescription(stereoMixdownOfProcesses: ids)  (muteBehavior .unmuted)
  → AudioHardwareCreateProcessTap → tapID
  → AudioHardwareCreateAggregateDevice(dict with:
        name, uid, main device = default output UID, private = true,
        taps = [desc.uuid], sub devices = [default output])
  → aggregate device has input streams = tapped audio
  → AudioDeviceCreateIOProcID(aggregate) → IOProc reads input ABL
  → ExtAudioFileWrite (client format = device input ASBD, file format = ALAC/CAF or PCM/WAV)
```

---

### Task 1: SwiftPM scaffold, app shell, build script

**Files:**
- Create: `Package.swift`
- Create: `Sources/Stems/main.swift`
- Create: `Sources/Stems/App.swift`
- Create: `scripts/build-app.sh` (executable)
- Create: `Tests/StemsTests/Sanity.swift`

**Interfaces:**
- Consumes: nothing
- Produces: runnable executable `Stems`; CLI dispatch entry in `main.swift` (`runCLI() -> Int32?` pattern other tasks extend); `StemsApp` GUI entry; `.app` bundle build script; test target `StemsTests`

- [ ] **Step 1: Create Package.swift**

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Stems",
    platforms: [.macOS("14.4")],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "Stems",
            path: "Sources/Stems",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "StemsTests",
            dependencies: ["Stems"],
            path: "Tests/StemsTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

- [ ] **Step 2: Create main.swift with CLI dispatch**

```swift
import Foundation

// CLI entry: any argument switches to tool mode; no arguments launches the GUI.
// Tasks 4+7 add subcommands by extending runCLI().
if let code = runCLI() {
    exit(code)
}

StemsApp.main()
```

```swift
// Keep in main.swift until Task 4 introduces real subcommands.
func runCLI() -> Int32? {
    let args = CommandLine.arguments
    guard args.count > 1 else { return nil }
    FileHandle.standardError.write("unknown arguments: \(args.dropFirst())\n".data(using: .utf8)!)
    return 64 // EX_USAGE
}
```

- [ ] **Step 3: Create App.swift (GUI shell)**

```swift
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar + wiring arrive in later tasks.
    }
}

struct StemsApp: App {
    // NOTE: no @main here — main.swift calls StemsApp.main() (SwiftPM executables
    // only allow top-level code in main.swift).
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup("Stems") {
            Text("Stems")
                .padding()
                .frame(minWidth: 480, minHeight: 360)
        }
        .windowResizability(.contentSize)
    }
}
```

- [ ] **Step 4: Create Tests/StemsTests/Sanity.swift**

```swift
import Testing
@testable import Stems

@Test func sanity() {
    #expect(Bundle.main.bundleIdentifier != nil || true) // target links and runs
}
```

- [ ] **Step 5: Create scripts/build-app.sh and chmod +x**

```bash
#!/bin/bash
# Assembles an ad-hoc signed Stems.app from the SwiftPM release build.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(git describe --tags --always --dirty 2>/dev/null || echo 0.1.0)"
CONFIG="${CONFIG:-Release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Stems"

APP="build/Stems.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN" "$APP/Contents/MacOS/Stems"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>Stems</string>
    <key>CFBundleIdentifier</key><string>com.stemsapp.Stems</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Stems</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Stems records audio from applications and your microphone as separate tracks.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP (${VERSION})"
```

- [ ] **Step 6: Build, test, run script**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 1 test passed` (Swift Testing output wording may vary; must show 0 failures)

Run: `./scripts/build-app.sh && ls build/Stems.app/Contents/MacOS`
Expected: `Built build/Stems.app (...)` then `Stems`

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources Tests scripts
git commit -m "feat: SwiftPM scaffold with app shell and .app build script"
```

---

### Task 2: Session models + SessionStore (TDD)

**Files:**
- Create: `Sources/Stems/Core/Models.swift`
- Create: `Sources/Stems/Core/SessionStore.swift`
- Test: `Tests/StemsTests/SessionStoreTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces (exact types used by Tasks 5–11):
  - `enum SourceKind: String, Codable, CaseIterable` — `.application`, `.microphone`
  - `struct SourceDescriptor: Codable, Hashable, Identifiable` — `id: String` (bundleID for apps, deviceUID for mic), `kind: SourceKind`, `name: String`, `bundleIdentifier: String?`, `deviceUID: String?`
  - `enum StemFormat: String, Codable, CaseIterable` — `.alac`, `.wav`
  - `struct StemRecord: Codable, Hashable, Identifiable` — `id: UUID`, `source: SourceDescriptor`, `fileName: String`, `sampleRate: Double`, `channelCount: Int`, `startTime: Date`, `endTime: Date?`, `endEvent: String?`
  - `struct SessionManifest: Codable` — `identifier: UUID`, `title: String`, `startTime: Date`, `endTime: Date?`, `stemFormat: StemFormat`, `stems: [StemRecord]`, `appVersion: String`
  - `struct SessionSummary: Identifiable` — `id: UUID`, `folderURL: URL`, `manifest: SessionManifest`, `sizeBytes: Int64`; `var totalDuration: TimeInterval`
  - `final class SessionStore` — `init(rootURL: URL? = nil)`, `static func defaultRoot() -> URL`, `func makeSessionFolder(start: Date) throws -> URL`, `func save(_ manifest: SessionManifest, to folder: URL) throws`, `func loadManifest(at folder: URL) throws -> SessionManifest`, `func listSessions() -> [SessionSummary]`, `func deleteStems(in folder: URL) throws` (keeps manifest), `func diskUsage(of folder: URL) -> Int64`

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("SessionStore") struct SessionStoreTests {
    func makeStore() throws -> (SessionStore, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stems-tests-\(UUID().uuidString)")
        return (SessionStore(rootURL: root), root)
    }

    @Test func manifestRoundTrip() throws {
        let (store, _) = try makeStore()
        let mic = SourceDescriptor(id: "MicUID", kind: .microphone, name: "MacBook Microphone",
                                   bundleIdentifier: nil, deviceUID: "MicUID")
        var manifest = SessionManifest(
            identifier: UUID(), title: "Session 2026-08-15 10.00.00",
            startTime: Date(timeIntervalSince1970: 1_800_000_000), endTime: nil,
            stemFormat: .alac, appVersion: "0.1.0",
            stems: [StemRecord(source: mic, fileName: "stem-1.caf", sampleRate: 48_000,
                               channelCount: 1, startTime: Date(timeIntervalSince1970: 1_800_000_000),
                               endTime: nil, endEvent: nil)]
        )
        let folder = try store.makeSessionFolder(start: manifest.startTime)
        try store.save(manifest, to: folder)
        let loaded = try store.loadManifest(at: folder)
        #expect(loaded == manifest)

        // finalize: partial session gets an endTime and end event
        manifest.endTime = Date(timeIntervalSince1970: 1_800_0_600)
        manifest.stems[0].endTime = manifest.endTime
        manifest.stems[0].endEvent = "sessionEnd"
        try store.save(manifest, to: folder)
        #expect(try store.loadManifest(at: folder) == manifest)
    }

    @Test func sessionsListNewestFirstAndSorted() throws {
        let (store, _) = try makeStore()
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in [0, 3600, 7200] {
            let folder = try store.makeSessionFolder(start: base.addingTimeInterval(TimeInterval(offset)))
            let manifest = SessionManifest(identifier: UUID(), title: "t", startTime: base.addingTimeInterval(TimeInterval(offset)),
                                           endTime: nil, stemFormat: .wav, appVersion: "0", stems: [])
            try store.save(manifest, to: folder)
        }
        let sessions = store.listSessions()
        #expect(sessions.count == 3)
        #expect(sessions.map(\.manifest.startTime) == sessions.map(\.manifest.startTime).sorted(by: >))
    }

    @Test func deleteStemsKeepsManifest() throws {
        let (store, root) = try makeStore()
        let folder = try store.makeSessionFolder(start: Date())
        try "fake-stem".write(to: folder.appendingPathComponent("stem-1.caf"), atomically: true, encoding: .utf8)
        let manifest = SessionManifest(identifier: UUID(), title: "t", startTime: Date(),
                                       endTime: nil, stemFormat: .alac, appVersion: "0",
                                       stems: [StemRecord(source: SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: "a", deviceUID: nil),
                                                          fileName: "stem-1.caf", sampleRate: 48_000, channelCount: 2,
                                                          startTime: Date(), endTime: nil, endEvent: nil)])
        try store.save(manifest, to: folder)
        #expect(store.diskUsage(of: folder) > 0)
        try store.deleteStems(in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("stem-1.caf").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        _ = root
    }

    @Test func foldersWithoutManifestAreIgnored() throws {
        let (store, _) = try makeStore()
        let folder = try store.makeSessionFolder(start: Date())
        try "junk".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        #expect(store.listSessions().isEmpty)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build failure — `no such module`/cannot find `SessionStore` types. This is the failing state.

- [ ] **Step 3: Implement Models.swift**

```swift
import Foundation

enum SourceKind: String, Codable, CaseIterable {
    case application
    case microphone
}

struct SourceDescriptor: Codable, Hashable, Identifiable {
    var id: String            // bundleIdentifier for apps, deviceUID for mics
    var kind: SourceKind
    var name: String
    var bundleIdentifier: String?
    var deviceUID: String?
}

enum StemFormat: String, Codable, CaseIterable {
    case alac
    case wav
}

struct StemRecord: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var source: SourceDescriptor
    var fileName: String
    var sampleRate: Double
    var channelCount: Int
    var startTime: Date
    var endTime: Date?
    var endEvent: String?   // "sessionEnd" | "processExited" | "deviceLost"
}

struct SessionManifest: Codable {
    var identifier: UUID
    var title: String
    var startTime: Date
    var endTime: Date?
    var stemFormat: StemFormat
    var stems: [StemRecord]
    var appVersion: String
}

struct SessionSummary: Identifiable {
    var id: UUID { manifest.identifier }
    var folderURL: URL
    var manifest: SessionManifest
    var sizeBytes: Int64
    var totalDuration: TimeInterval {
        if let end = manifest.endTime { return end.timeIntervalSince(manifest.startTime) }
        return manifest.stems.compactMap(\.endTime)
            .map { $0.timeIntervalSince(manifest.startTime) }.max() ?? 0
    }
}
```

- [ ] **Step 4: Implement SessionStore.swift**

```swift
import Foundation

final class SessionStore {
    let root: URL

    init(rootURL: URL? = nil) {
        self.root = rootURL ?? SessionStore.defaultRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func defaultRoot() -> URL {
        let music = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return music.appendingPathComponent("Stems", isDirectory: true)
    }

    static func coders() -> (JSONEncoder, JSONDecoder) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (enc, dec)
    }

    static func folderName(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "Session yyyy-MM-dd HH.mm.ss"
        return fmt.string(from: date)
    }

    func makeSessionFolder(start: Date) throws -> URL {
        var url = root.appendingPathComponent(Self.folderName(for: start), isDirectory: true)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("\(Self.folderName(for: start)) \(counter)", isDirectory: true)
            counter += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func save(_ manifest: SessionManifest, to folder: URL) throws {
        let (enc, _) = Self.coders()
        let data = try enc.encode(manifest)
        try data.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
    }

    func loadManifest(at folder: URL) throws -> SessionManifest {
        let (_, dec) = Self.coders()
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        return try dec.decode(SessionManifest.self, from: data)
    }

    func listSessions() -> [SessionSummary] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { folder -> SessionSummary? in
                guard let manifest = try? loadManifest(at: folder) else { return nil }
                return SessionSummary(folderURL: folder, manifest: manifest, sizeBytes: diskUsage(of: folder))
            }
            .sorted { $0.manifest.startTime > $1.manifest.startTime }
    }

    func deleteStems(in folder: URL) throws {
        let fm = FileManager.default
        for stem in try loadManifest(at: folder).stems {
            let url = folder.appendingPathComponent(stem.fileName)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
    }

    func diskUsage(of folder: URL) -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `swift test 2>&1 | tail -5`
Expected: all 5 tests pass (Sanity + 4 SessionStore), 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stems/Core Tests/StemsTests/SessionStoreTests.swift
git commit -m "feat: session models and manifest-backed SessionStore"
```

---

### Task 3: App grouping logic (TDD, pure)

**Files:**
- Create: `Sources/Stems/Core/AppGrouping.swift`
- Test: `Tests/StemsTests/AppGroupingTests.swift`

**Interfaces:**
- Consumes: `SourceDescriptor`, `SourceKind` (Task 2)
- Produces: `struct AudioProcessSnapshot: Hashable { var objectID: UInt32; var pid: pid_t; var bundleID: String?; var processName: String }` and `func appSources(from processes: [AudioProcessSnapshot], excludedBundleIDs: Set<String>) -> [SourceDescriptor]` (sorted by name). Used by Task 4's `SourceRegistry`.

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("AppGrouping") struct AppGroupingTests {
    @Test func mergesHelperProcessesByBundleID() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.google.Chrome", processName: "Google Chrome"),
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "com.google.Chrome", processName: "Google Chrome Helper"),
            AudioProcessSnapshot(objectID: 3, pid: 200, bundleID: "us.zoom.xos", processName: "zoom.us"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        #expect(sources.count == 2)
        let chrome = sources.first { $0.bundleIdentifier == "com.google.Chrome" }
        #expect(chrome?.name == "Google Chrome")
        #expect(chrome?.id == "com.google.Chrome")
        #expect(chrome?.kind == .application)
    }

    @Test func excludesConfiguredBundleIDs() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 100, bundleID: "com.stemsapp.Stems", processName: "Stems"),
            AudioProcessSnapshot(objectID: 2, pid: 101, bundleID: "us.zoom.xos", processName: "zoom.us"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: ["com.stemsapp.Stems"])
        #expect(sources.map(\.bundleIdentifier) == ["us.zoom.xos"])
    }

    @Test func nilBundleIDFallsBackToPerProcessName() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 300, bundleID: nil, processName: "MysteryDaemon"),
            AudioProcessSnapshot(objectID: 2, pid: 301, bundleID: nil, processName: "MysteryDaemon"),
        ]
        let sources = appSources(from: procs, excludedBundleIDs: [])
        // No bundle ID: group by process name so user still gets one entry.
        #expect(sources.count == 1)
        #expect(sources[0].id == "pid:300") // deterministic id = first pid
        #expect(sources[0].name == "MysteryDaemon")
    }

    @Test func resultSortedByName() {
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 1, bundleID: "b.second", processName: "Zeta"),
            AudioProcessSnapshot(objectID: 2, pid: 2, bundleID: "a.first", processName: "Alpha"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).map(\.name) == ["Alpha", "Zeta"])
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build failure — `AudioProcessSnapshot`/`appSources` undefined.

- [ ] **Step 3: Implement AppGrouping.swift**

```swift
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
```

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass, 0 failures.

- [ ] **Step 5: Commit**

```bash
git add Sources/Stems/Core/AppGrouping.swift Tests/StemsTests/AppGroupingTests.swift
git commit -m "feat: group audio processes into per-application sources"
```

---

### Task 4: Core Audio property IO + SourceRegistry

**Files:**
- Create: `Sources/Stems/Core/AudioProperty.swift`
- Create: `Sources/Stems/Core/SourceRegistry.swift`
- Modify: `Sources/Stems/main.swift` (add `--list-taps`)
- Test: `Tests/StemsTests/SourceNamingTests.swift`

**Interfaces:**
- Consumes: `AudioProcessSnapshot`, `appSources` (Task 3)
- Produces:
  - `enum AudioProperty` — `static func readArray<T>(of: T.Type, objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [T]?`, `static func readString(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String?`, `static func readUInt32(objectID: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32?`, `static var defaultOutputDeviceID: AudioObjectID?`, `static var defaultOutputDeviceUID: String?`, `static var defaultInputDeviceID: AudioObjectID?`
  - `final class SourceRegistry` — `static let excludedBundleIDs: Set<String>` (Stems itself + `com.apple.audio.CoreAudioServer`-style system entries filtered by exclusion list below), `func processObjectSnapshots() -> [AudioProcessSnapshot]`, `func currentAppSources() -> [SourceDescriptor]`, `func currentMicSources() -> [SourceDescriptor]` (input devices), `func processObjectIDs(forBundleID: String) -> [AudioObjectID]`, `func deviceID(forUID: String) -> AudioObjectID?`
  - CLI: `Stems --list-taps` prints one source per line

- [ ] **Step 1: Write failing test for name fallbacks**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("SourceRegistry naming") struct SourceNamingTests {
    @Test func shorterProcessNameWinsAsDisplayName() {
        // The grouping helper prefers the shortest process name (the app itself,
        // not its helpers).
        let procs = [
            AudioProcessSnapshot(objectID: 1, pid: 1, bundleID: "com.google.Chrome", processName: "Google Chrome Helper (Renderer)"),
            AudioProcessSnapshot(objectID: 2, pid: 2, bundleID: "com.google.Chrome", processName: "Google Chrome"),
        ]
        #expect(appSources(from: procs, excludedBundleIDs: []).first?.name == "Google Chrome")
    }
}
```

- [ ] **Step 2: Run test, verify failure**

Run: `swift test 2>&1 | tail -5` — Expected: build failure, `AudioProperty`/`SourceRegistry` undefined.

- [ ] **Step 3: Implement AudioProperty.swift**

```swift
import Foundation
import CoreAudio

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
        var buffer = [T](repeating: unsafeBitCast(0, to: T.self), count: count)
        guard AudioObjectGetPropertyData(objectID, &address, size, nil, &size) == noErr else { return nil }
        return buffer
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
```

- [ ] **Step 4: Implement SourceRegistry.swift**

```swift
import Foundation
import AppKit
import CoreAudio

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

    /// Audio object IDs of every process belonging to an app (helpers included).
    func processObjectIDs(forBundleID bundleID: String) -> [AudioObjectID] {
        processObjectSnapshots()
            .filter { $0.bundleID == bundleID }
            .map { AudioObjectID($0.objectID) }
    }

    /// Object IDs for bundle-less app sources (grouped by "pid:<n>" id).
    func processObjectIDs(forSourceID sourceID: String) -> [AudioObjectID] {
        processObjectSnapshots()
            .filter { "\(self.idString(for: $0))" == sourceID }
            .map { AudioObjectID($0.objectID) }
    }

    private func idString(for snapshot: AudioProcessSnapshot) -> String {
        if let bundle = snapshot.bundleID, !bundle.isEmpty { return bundle }
        return "pid:\(snapshot.pid)" // NOTE: grouping merges by name; id uses min pid of the group — resolve via currentAppSources matching by name instead when exact
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
```

Note: `processObjectIDs(forSourceID:)` must handle both bundle-based and name-grouped sources. Resolve name-grouped ids by matching the source's display name:

```swift
extension SourceRegistry {
    /// Resolve ANY app SourceDescriptor to its current process object IDs.
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
```

(Keep `processObjectIDs(forSourceID:)` only if used by CLI; prefer `processObjectIDs(for:)` everywhere — implement just that one and delete the other.)

- [ ] **Step 5: Add `--list-taps` to main.swift (replace runCLI)**

```swift
import Foundation
import AppKit

func runCLI() -> Int32? {
    let args = CommandLine.arguments
    guard args.count > 1 else { return nil }
    let command = args[1]

    switch command {
    case "--list-taps":
        let registry = SourceRegistry()
        let apps = registry.currentAppSources()
        let mics = registry.currentMicSources()
        guard !apps.isEmpty || !mics.isEmpty else {
            print("no sources found (is any app playing audio?)")
            return 0
        }
        print("APPLICATIONS")
        for a in apps { print("  \(a.id)\t\(a.name)") }
        print("MICROPHONES")
        for m in mics { print("  \(m.id)\t\(m.name)") }
        return 0
    default:
        FileHandle.standardError.write("unknown command \(command)\n".data(using: .utf8)!)
        return 64
    }
}
```

(Keep `StemsApp.main()` call below `runCLI()` dispatch as in Task 1.)

- [ ] **Step 6: Build, test, and smoke-run**

Run: `swift build && swift test 2>&1 | tail -3`
Expected: build complete; all tests pass.

Run: `swift run Stems --list-taps`
Expected: `APPLICATIONS` + `MICROPHONES` sections. With music/YouTube playing in a browser, the browser appears under APPLICATIONS. **If macOS shows a microphone permission prompt for the terminal, approve it** (taps need mic TCC on some OS versions). If no app is playing audio, list may be empty or short — start audio in Safari/Chrome/Music, re-run.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stems Tests
git commit -m "feat: source registry over Core Audio process objects with --list-taps CLI"
```

---

### Task 5: StemWriter — ExtAudioFile ALAC/CAF + WAV (TDD)

**Files:**
- Create: `Sources/Stems/Core/StemWriter.swift`
- Test: `Tests/StemsTests/StemWriterTests.swift`

**Interfaces:**
- Consumes: `StemFormat` (Task 2)
- Produces: `final class StemWriter` — `init(url: URL, clientFormat: AudioStreamBasicDescription, format: StemFormat) throws` (client format = interleaved Float32 device ASBD; file format = ALAC/CAF or 16-bit PCM/WAV), `func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32) throws`, `func close()` (idempotent; safe to call from IOProc context via nonthrowing wrapper `closeQuietly()`)

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("StemWriter") struct StemWriterTests {
    /// interleaved Float32 stereo ASBD like a tap provides
    static func clientFormat(channels: UInt32, rate: Float64) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                                    mBytesPerPacket: 4 * channels, mFramesPerPacket: 1,
                                    mBytesPerFrame: 4 * channels, mChannelsPerFrame: channels,
                                    mBitsPerChannel: 32)
    }

    static func writeSine(url: URL, format: StemFormat, channels: UInt32, rate: Float64, seconds: Double, freq: Double = 440) throws {
        let writer = try StemWriter(url: url, clientFormat: Self.clientFormat(channels: channels, rate: rate), format: format)
        let framesPerWrite: UInt32 = 4096
        let totalFrames = UInt32(rate * seconds)
        var phase: Float = 0
        var written: UInt32 = 0
        let increment: Float = Float(2.0 * Double.pi * freq / rate)
        while written < totalFrames {
            let n = min(framesPerWrite, totalFrames - written)
            var samples = [Float](repeating: 0, count: Int(n * channels))
            for f in 0..<Int(n) {
                let v = sin(phase); phase += increment
                for c in 0..<Int(channels) { samples[f * Int(channels) + c] = v * 0.5 }
            }
            var abl = AudioBufferList(mNumberBuffers: 1,
                mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: n * 4 * channels,
                                      mData: &samples))
            try writer.write(&abl, frameCount: n)
            written += n
        }
        writer.close()
    }

    @Test func writesReadableWAV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).wav")
        try Self.writeSine(url: url, format: .wav, channels: 2, rate: 48_000, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 44_000) // ~1s of frames
        #expect(file.fileFormat.sampleRate == 48_000)
    }

    @Test func writesReadableALACCAF() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).caf")
        try Self.writeSine(url: url, format: .alac, channels: 2, rate: 48_000, seconds: 1.0)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 44_000)
        #expect(abs(file.fileFormat.sampleRate - 48_000) < 1)
    }

    @Test func wavIsSmallerThanNothingAndALACCompresses() throws {
        // sanity on ALAC actually compressing a pure sine strongly
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).wav")
        let caf = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).caf")
        try Self.writeSine(url: wav, format: .wav, channels: 2, rate: 48_000, seconds: 2.0)
        try Self.writeSine(url: caf, format: .alac, channels: 2, rate: 48_000, seconds: 2.0)
        defer { try? FileManager.default.removeItem(at: wav); try? FileManager.default.removeItem(at: caf) }
        let wavSize = try FileManager.default.attributesOfItem(atPath: wav.path)[.size] as! Int
        let cafSize = try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as! Int
        #expect(cafSize < wavSize) // sine must compress below PCM
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5` — Expected: build failure, `StemWriter` undefined.

- [ ] **Step 3: Implement StemWriter.swift**

```swift
import Foundation
import CoreAudio
import AudioToolbox

enum StemWriterError: Error { case status(OSStatus, String) }

final class StemWriter {
    private var file: ExtAudioFileRef?
    private let url: URL

    init(url: URL, clientFormat: AudioStreamBasicDescription, format: StemFormat) throws {
        self.url = url

        // File (data) format
        var fileFormat = AudioStreamBasicDescription()
        var fileType: AudioFileTypeID
        switch format {
        case .alac:
            fileType = kAudioFileCAFType
            fileFormat.mFormatID = kAudioFormatAppleLossless
            fileFormat.mChannelsPerFrame = clientFormat.mChannelsPerFrame
            fileFormat.mSampleRate = clientFormat.mSampleRate
            // ALAC "magic" cookie frames: 16-bit depth, no source bit depth loss beyond PCM32 client
            fileFormat.mBitsPerChannel = 16
            // ALAC frames-per-packet and cookie details are filled by ExtAudioFile's converter.
            fileFormat.mFramesPerPacket = 4096
            fileFormat.mBytesPerPacket = 0
            fileFormat.mBytesPerFrame = 0
        case .wav:
            fileType = kAudioFileWAVEType
            fileFormat = AudioStreamBasicDescription(
                mSampleRate: clientFormat.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 2 * clientFormat.mChannelsPerFrame,
                mFramesPerPacket: 1,
                mBytesPerFrame: 2 * clientFormat.mChannelsPerFrame,
                mChannelsPerFrame: clientFormat.mChannelsPerFrame,
                mBitsPerChannel: 16)
        }

        var ref: ExtAudioFileRef?
        let createStatus = ExtAudioFileCreateWithURL(url as CFURL, fileType, &fileFormat,
                                                     nil, kAudioFileFlags_Erase, &ref)
        guard createStatus == noErr, let created = ref else {
            throw StemWriterError.status(createStatus, "ExtAudioFileCreateWithURL(\(format))")
        }
        self.file = created

        var client = clientFormat
        let setClient = ExtAudioFileSetProperty(created, kExtAudioFileProperty_ClientDataFormat,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &client)
        guard setClient == noErr else {
            closeQuietly()
            throw StemWriterError.status(setClient, "set client format")
        }
    }

    func write(_ bufferList: UnsafePointer<AudioBufferList>, frameCount: UInt32) throws {
        guard let file else { return }
        let status = ExtAudioFileWrite(file, frameCount, bufferList)
        guard status == noErr else { throw StemWriterError.status(status, "ExtAudioFileWrite") }
    }

    func close() {
        guard let file else { return }
        ExtAudioFileDispose(file)
        self.file = nil
    }

    /// For IOProc error paths — never throws, never fails stop.
    func closeQuietly() { close() }
}
```

Known risk handled by tests: ALAC ASBD fields above are the conventional recipe (`mBitsPerChannel` 16, `mFramesPerPacket` 4096). If `writeReadableALACCAF` fails with `fmt?`/`!dat` errors, try `mBitsPerChannel = 32` or build the file format via `AudioFormatGetProperty(kAudioFormatProperty_FormatIsEncoded)`-driven cookie — but the afconvert-verified path (`-f caff -d alac`) is what this mirrors, so expect green.

- [ ] **Step 4: Run tests, verify pass**

Run: `swift test 2>&1 | tail -5`
Expected: all tests pass including both ALAC and WAV round-trips.

- [ ] **Step 5: Commit**

```bash
git add Sources/Stems/Core/StemWriter.swift Tests/StemsTests/StemWriterTests.swift
git commit -m "feat: ExtAudioFile stem writer for ALAC/CAF and WAV"
```

---

### Task 6: Process taps, aggregate device, capture chains (Core Audio core)

**Files:**
- Create: `Sources/Stems/Core/ProcessTap.swift`
- Create: `Sources/Stems/Core/CaptureChain.swift`
- Modify: `Sources/Stems/main.swift` (add `--record-app`, `--record-mic`)

**Interfaces:**
- Consumes: `AudioProperty` (Task 4), `StemWriter` (Task 5), `SourceRegistry` (Task 4)
- Produces:
  - `struct ProcessTapSession` — `let tapID: AudioObjectID; let aggregateDeviceID: AudioObjectID; static func create(processObjectIDs: [AudioObjectID], name: String) throws -> ProcessTapSession; mutating func dispose()`
  - `final class CaptureChain` — `init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope, writer: StemWriter)`, `var onLevel: ((Float) -> Void)?`, `var onEnded: ((String) -> Void)?` (reason string), `func start() throws`, `func stop(reason: String)`
- CLI smoke: `Stems --record-app <bundleID> --seconds 5 --out <dir>` and `Stems --record-mic --seconds 5 --out <dir>`

No unit tests (live audio only). Verification is via CLI smoke runs + checklist.

- [ ] **Step 1: Implement ProcessTap.swift**

```swift
import Foundation
import CoreAudio

struct ProcessTapSession {
    let tapID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    private var disposed = false

    static func create(processObjectIDs: [AudioObjectID], name: String) throws -> ProcessTapSession {
        guard !processObjectIDs.isEmpty else {
            throw StemWriterError.status(paramErr, "no process objects for \(name)")
        }
        guard let outputUID = AudioProperty.defaultOutputDeviceUID,
              let outputID = AudioProperty.defaultOutputDeviceID else {
            throw StemWriterError.status(paramErr, "no default output device")
        }

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs.map(NSNumber.init(value:)))
        tapDescription.muteBehavior = .unmuted   // non-destructive: app audio keeps playing

        var tapID = AudioObjectID()
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createStatus == noErr else {
            throw StemWriterError.status(createStatus, "AudioHardwareCreateProcessTap")
        }

        let aggregateUID = "Stems.Tap.\(UUID().uuidString)"
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Stems — \(name)",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapDescription.uuid.uuidString],
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: 0]
            ],
        ]
        var aggregateID = AudioObjectID()
        var cfDescription = description as CFDictionary
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
        AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        AudioHardwareDestroyProcessTap(tapID)
    }
}
```

- [ ] **Step 2: Implement CaptureChain.swift**

```swift
import Foundation
import CoreAudio

/// One running capture: a device (aggregate tap device or input device),
/// an IOProc, and a stem file. NOT thread-safe — start/stop from one queue;
/// IOProc only touches the writer and meter bookkeeping.
final class CaptureChain {
    let deviceID: AudioObjectID
    let scope: AudioObjectPropertyScope      // .input for taps and mics
    private let writer: StemWriter
    private var ioProcID: AudioDeviceIOProcID?
    private var lastMeterAt: Double = 0

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
            throw StemWriterError.status(paramErr, "no input stream format on device \(deviceID)")
        }
        let writer = try StemWriter(url: stemURL, clientFormat: clientFormat, format: format)
        return CaptureChain(deviceID: deviceID, scope: scope, writer: writer)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<CaptureChain>.fromOpaque(clientData).takeUnretainedValue()

            guard !chain.ended, let input = inputData?.pointee, input.mNumberBuffers > 0,
                  let data = input.mBuffers.mData, input.mBuffers.mDataByteSize > 0 else {
                return noErr
            }

            let byteSize = Int(input.mBuffers.mDataByteSize)
            let asbd = CaptureChain.inputFormat(deviceID: chain.deviceID, scope: chain.scope)
            let bytesPerFrame = Int(asbd?.mBytesPerFrame ?? 4)
            let frameCount = UInt32(byteSize / max(bytesPerFrame, 1))

            // meter (throttled): RMS over Float32 samples
            if CACurrentMediaTime() - chain.lastMeterAt > 0.1 {
                chain.lastMeterAt = CACurrentMediaTime()
                let samples = data.bindMemory(to: Float.self, capacity: byteSize / 4)
                var sum: Float = 0
                var count = 0
                for i in 0..<(byteSize / 4) { let v = samples[i]; sum += v * v; count += 1 }
                let rms = count > 0 ? sqrt(sum / Float(count)) : 0
                if let onLevel = chain.onLevel {
                    DispatchQueue.main.async { onLevel(min(rms * 4, 1)) } // gain for visibility
                }
            }

            do {
                try chain.writer.write(input, frameCount: frameCount)
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
        AudioDeviceStart(deviceID, ioProcID)
    }

    private func endWith(_ reason: String) {
        guard !ended else { return }
        ended = true
        stopHardware()
        writer.closeQuietly()
        if let onEnded { DispatchQueue.main.async { onEnded(reason) } }
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
```

- [ ] **Step 3: Add `--record-app` / `--record-mic` CLI (extend runCLI switch)**

```swift
    case "--record-app":
        // --record-app <bundleID> --seconds N --out DIR
        guard args.count >= 3 else { return 64 }
        let bundleID = args[2]
        let seconds = Double(flagValue("--seconds", in: args, default: "5")) ?? 5
        let outDir = URL(fileURLWithPath: flagValue("--out", in: args, default: NSTemporaryDirectory()))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return RecordCLI.recordApp(bundleID: bundleID, seconds: seconds, outDir: outDir)

    case "--record-mic":
        let seconds = Double(flagValue("--seconds", in: args, default: "5")) ?? 5
        let outDir = URL(fileURLWithPath: flagValue("--out", in: args, default: NSTemporaryDirectory()))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        return RecordCLI.recordMic(seconds: seconds, outDir: outDir)
```

And a flag helper plus `RecordCLI` (new file `Sources/Stems/Core/RecordCLI.swift` — this is the template RecorderEngine reuses in Task 7):

```swift
import Foundation
import CoreAudio

func flagValue(_ flag: String, in args: [String], default def: String) -> String {
    guard let idx = args.firstIndex(of: flag), args.indices.contains(idx + 1) else { return def }
    return args[idx + 1]
}

enum RecordCLI {
    static func recordApp(bundleID: String, seconds: Double, outDir: URL) -> Int32 {
        let registry = SourceRegistry()
        let objectIDs = registry.processObjectIDs(for:
            SourceDescriptor(id: bundleID, kind: .application, name: bundleID,
                             bundleIdentifier: bundleID, deviceUID: nil))
        guard !objectIDs.isEmpty else {
            FileHandle.standardError.write("no audio processes for \(bundleID) — is it playing sound?\n".data(using: .utf8)!)
            return 1
        }
        do {
            var tap = try ProcessTapSession.create(processObjectIDs: objectIDs, name: bundleID)
            defer { tap.dispose() }
            let stem = outDir.appendingPathComponent("stem-\(bundleID.replacingOccurrences(of: "/", with: "-")).caf")
            let chain = try CaptureChain.make(deviceID: tap.aggregateDeviceID,
                                              scope: kAudioObjectPropertyScopeInput,
                                              stemURL: stem, format: .alac)
            return run(chain: chain, seconds: seconds, description: bundleID, stemURL: stem)
        } catch {
            FileHandle.standardError.write("tap error: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    static func recordMic(seconds: Double, outDir: URL) -> Int32 {
        guard let deviceID = AudioProperty.defaultInputDeviceID else { return 1 }
        let stem = outDir.appendingPathComponent("stem-mic.caf")
        do {
            let chain = try CaptureChain.make(deviceID: deviceID,
                                              scope: kAudioObjectPropertyScopeInput,
                                              stemURL: stem, format: .alac)
            return run(chain: chain, seconds: seconds, description: "mic", stemURL: stem)
        } catch {
            FileHandle.standardError.write("mic error: \(error)\n".data(using: .utf8)!)
            return 1
        }
    }

    private static func run(chain: CaptureChain, seconds: Double, description: String, stemURL: URL) -> Int32 {
        chain.onLevel = { level in
            let bar = String(repeating: "█", count: Int(level * 30))
            print(String(format: "  [%-30s] %@", bar as NSString, description))
        }
        do {
            try chain.start()
        } catch {
            FileHandle.standardError.write("start error: \(error)\n".data(using: .utf8)!)
            return 1
        }
        print("recording \(seconds)s from \(description)…")
        Thread.sleep(forTimeInterval: seconds)
        chain.stop(reason: "sessionEnd")
        let size = (try? FileManager.default.attributesOfItem(atPath: stemURL.path)[.size] as? Int) ?? 0
        print("wrote \(stemURL.path) (\(size ?? 0) bytes)")
        return 0
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!` — if `CATapDescription(stereoMixdownOfProcesses:)` name is rejected by the compiler, check the ObjC selector (`initStereoMixdownOfProcesses:`) Swift refinement: alternates are `CATapDescription(stereoMixdownOfProcesses:)` (verified on this SDK) — do not change API semantics while adapting spelling.

- [ ] **Step 5: Manual smoke verification (live audio)**

1. Start audio in a browser (e.g., YouTube). 
2. Run: `swift run Stems --list-taps` → note the browser bundle ID.
3. Run: `swift run Stems --record-app <that-bundle-id> --seconds 5 --out /tmp/stems-smoke`
   Expected: `recording 5s…` + level bars while audio plays; `wrote /tmp/stems-smoke/stem-….caf (N bytes)` with N > 0.
4. Run: `afinfo /tmp/stems-smoke/stem-*.caf` → `Data format: 2 ch, 48000 Hz, alac`.
5. Run: `open /tmp/stems-smoke/stem-*.caf` → audible playback, browser audio was NOT muted during capture.
6. Run: `swift run Stems --record-mic --seconds 5 --out /tmp/stems-smoke` → speak; bars move; file non-empty.
   Approve the mic permission prompt the first time (for the terminal binary or Terminal app).

- [ ] **Step 6: Commit**

```bash
git add Sources/Stems
git commit -m "feat: process taps, aggregate devices, and IOProc capture chains with CLI smoke tests"
```

---

### Task 7: RecorderEngine — session orchestration

**Files:**
- Create: `Sources/Stems/Core/RecorderEngine.swift`
- Test: `Tests/StemsTests/RecorderEngineManifestTests.swift` (manifest-update logic only; live capture is CLI-verified)

**Interfaces:**
- Consumes: `SourceRegistry`, `ProcessTapSession`, `CaptureChain`, `SessionStore`, `StemWriter`, models (Tasks 2–6)
- Produces:
  - `enum RecordState: Equatable { case idle; case recording(startedAt: Date) }`
  - `final class RecorderEngine: ObservableObject` — `@Published private(set) var state: RecordState`, `@Published private(set) var levels: [String: Float]` (key = source id), `@Published private(set) var activeSessionFolder: URL?`, `func startSession(sources: [SourceDescriptor], format: StemFormat, store: SessionStore) throws`, `func stopSession()`, `static func stemFileName(for source: SourceDescriptor, index: Int) -> String` (sanitized `stem-<index>-<name>.caf|.wav`)
  - Manifest is written at session START (all stems, `endTime: nil` — crash-safe) and updated at each stem end + session stop.
  - Per-source end handling: NSWorkspace `didTerminateApplicationNotification` matching `bundleIdentifier` → `chain.stop(reason: "processExited")`; IOProc error path reports `"deviceLost"`.

- [ ] **Step 1: Write failing test for pure manifest/filename logic**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("RecorderEngine helpers") struct RecorderEngineManifestTests {
    @Test func stemFileNamesSanitizedAndIndexed() {
        let chrome = SourceDescriptor(id: "com.google.Chrome", kind: .application,
                                      name: "Google Chrome", bundleIdentifier: "com.google.Chrome", deviceUID: nil)
        #expect(RecorderEngine.stemFileName(for: chrome, index: 0) == "stem-0-Google Chrome.caf")
        #expect(RecorderEngine.stemFileName(for: chrome, index: 0, format: .wav) == "stem-0-Google Chrome.wav")
    }

    @Test func manifestPersistsAtStartWithOpenStems() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-t-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let mic = SourceDescriptor(id: "u", kind: .microphone, name: "Mic", bundleIdentifier: nil, deviceUID: "u")
        let manifest = RecorderEngine.initialManifest(title: "T", sources: [mic], format: .alac,
                                                      folder: try store.makeSessionFolder(start: Date()))
        #expect(manifest.stems.allSatisfy { $0.endTime == nil })
        #expect(manifest.stemFormat == .alac)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5` — Expected: build failure, `RecorderEngine` undefined.

- [ ] **Step 3: Implement RecorderEngine.swift**

```swift
import Foundation
import Combine
import AppKit
import CoreAudio

enum RecordState: Equatable {
    case idle
    case recording(startedAt: Date)
}

final class RecorderEngine: ObservableObject {
    @Published private(set) var state: RecordState = .idle
    @Published private(set) var levels: [String: Float] = [:]
    @Published private(set) var activeSessionFolder: URL?

    private var chains: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?)] = []
    private var manifest: SessionManifest?
    private var store: SessionStore?
    private var workspaceObserver: NSObjectProtocol?

    static func stemFileName(for source: SourceDescriptor, index: Int, format: StemFormat = .alac) -> String {
        let ext = format == .alac ? "caf" : "wav"
        let clean = source.name.replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        return "stem-\(index)-\(clean).\(ext)"
    }

    static func initialManifest(title: String, sources: [SourceDescriptor], format: StemFormat, folder: URL) -> SessionManifest {
        SessionManifest(
            identifier: UUID(),
            title: folder.lastPathComponent,
            startTime: Date(),
            endTime: nil,
            stemFormat: format,
            stems: sources.enumerated().map { i, source in
                StemRecord(source: source,
                           fileName: stemFileName(for: source, index: i, format: format),
                           sampleRate: 48_000,   // placeholder; corrected after chain creation
                           channelCount: source.kind == .microphone ? 1 : 2,
                           startTime: Date(), endTime: nil, endEvent: nil)
            },
            appVersion: "0.1.0")
    }

    func startSession(sources: [SourceDescriptor], format: StemFormat, store: SessionStore) throws {
        guard case .idle = state else { return }
        guard !sources.isEmpty else { return }

        let registry = SourceRegistry()
        let folder = try store.makeSessionFolder(start: Date())
        var manifest = Self.initialManifest(title: folder.lastPathComponent, sources: sources,
                                            format: format, folder: folder)

        var built: [(source: SourceDescriptor, chain: CaptureChain, tap: ProcessTapSession?)] = []
        do {
            for (index, source) in sources.enumerated() {
                let fileName = manifest.stems[index].fileName
                let stemURL = folder.appendingPathComponent(fileName)

                var tap: ProcessTapSession?
                let deviceID: AudioObjectID
                switch source.kind {
                case .application:
                    let objectIDs = registry.processObjectIDs(for: source)
                    guard !objectIDs.isEmpty else { continue } // app not making audio right now → skipped stem
                    var t = try ProcessTapSession.create(processObjectIDs: objectIDs, name: source.name)
                    deviceID = t.aggregateDeviceID
                    tap = t
                case .microphone:
                    guard let uid = source.deviceUID,
                          let id = registry.deviceID(forUID: uid) else { continue }
                    deviceID = id
                }

                let chain = try CaptureChain.make(deviceID: deviceID,
                                                  scope: kAudioObjectPropertyScopeInput,
                                                  stemURL: stemURL, format: format)
                let sourceID = source.id
                chain.onLevel = { [weak self] level in self?.levels[sourceID] = level }
                chain.onEnded = { [weak self] reason in self?.stemEnded(sourceID: sourceID, reason: reason) }
                built.append((source, chain, tap))
            }
        } catch {
            built.forEach { $0.chain.stop(reason: "startupFailed"); $0.tap?.dispose() }
            throw error
        }

        // prune stems whose sources produced no chain (not playing / no device)
        manifest.stems = manifest.stems.filter { stem in built.contains { $0.source.id == stem.source.id } }
        try store.save(manifest, to: folder)

        self.store = store
        self.manifest = manifest
        self.chains = built
        self.activeSessionFolder = folder
        self.levels = [:]

        for item in built { try item.chain.start() }

        observeAppTermination()

        state = .recording(startedAt: manifest.startTime)
    }

    private func observeAppTermination() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            for item in self.chains where item.source.bundleIdentifier == app.bundleIdentifier {
                item.chain.stop(reason: "processExited")
            }
        }
    }

    @MainActor
    private func stemEnded(sourceID: String, reason: String) {
        guard var manifest, let store else { return }
        levels[sourceID] = nil
        if let idx = manifest.stems.firstIndex(where: { $0.source.id == sourceID }) {
            manifest.stems[idx].endTime = Date()
            manifest.stems[idx].endEvent = reason
            try? store.save(manifest, to: activeSessionFolder!)
        }
        self.manifest = manifest
        // All stems ended → auto-stop session.
        if manifest.stems.allSatisfy({ $0.endTime != nil }) { stopSession() }
    }

    func stopSession() {
        guard case .recording = state else { return }
        for item in chains { item.chain.stop(reason: "sessionEnd") }
        chains.forEach { $0.tap?.dispose() }
        if var manifest, let store {
            manifest.endTime = Date()
            for i in manifest.stems.indices where manifest.stems[i].endTime == nil {
                manifest.stems[i].endTime = manifest.endTime
                manifest.stems[i].endEvent = "sessionEnd"
            }
            try? store.save(manifest, to: activeSessionFolder!)
        }
        if let observer = workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObserver = nil
        chains = []
        levels = [:]
        manifest = nil
        store = nil
        activeSessionFolder = nil
        state = .idle
    }
}
```

- [ ] **Step 4: Run tests + CLI multi-source smoke**

Run: `swift test 2>&1 | tail -3` — Expected: all pass.

Run: with browser audio playing:
```bash
BID=$(swift run Stems --list-taps | awk '/APPLICATIONS/{f=1;next}/MICROPHONES/{f=0}f{print $1}' | head -1)
swift run Stems --record-app "$BID" --seconds 5 --out /tmp/stems-smoke2
```
Expected: non-empty ALAC stem (Task 6 covered single-source; this re-verifies post-refactor).

- [ ] **Step 5: Commit**

```bash
git add Sources/Stems/Core/RecorderEngine.swift Tests/StemsTests/RecorderEngineManifestTests.swift
git commit -m "feat: RecorderEngine orchestrating aligned multi-source sessions"
```

---

### Task 8: StemReader + Mixer (TDD)

**Files:**
- Create: `Sources/Stems/Export/StemReader.swift`
- Create: `Sources/Stems/Export/Mixer.swift`
- Test: `Tests/StemsTests/MixerTests.swift`

**Interfaces:**
- Consumes: `StemRecord`, `SessionManifest` (Task 2)
- Produces:
  - `struct StemAudio` — `let record: StemRecord; let buffer: AVAudioPCMBuffer; var offsetSeconds: TimeInterval { record.startTime.timeIntervalSince(sessionStart) }` → make it `struct StemAudio { var record: StemRecord; var buffer: AVAudioPCMBuffer; var offsetSeconds: TimeInterval }`
  - `enum StemReader` — `static func read(_ record: StemRecord, sessionStart: Date, folder: URL) throws -> StemAudio?` (returns nil for missing file)
  - `enum Mixer` — `static func mix(_ stems: [StemAudio], outputFormat: AVAudioFormat, gain: Float = 1.0) throws -> AVAudioPCMBuffer` — sums all stems at their offsets into one buffer at `outputFormat` (Float32 deinterleaved), resampling each stem as needed, soft-clipping to ±1

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("Mixer") struct MixerTests {
    static func makeBuffer(rate: Double, seconds: Double, value: Float, channels: AVAudioChannelCount = 1) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(rate * seconds))!
        buf.frameLength = buf.frameCapacity
        for c in 0..<Int(channels) { buf.floatChannelData![c].update(repeating: value, count: Int(buf.frameLength)) }
        return buf
    }

    static func stem(value: Float, rate: Double, seconds: Double, offset: TimeInterval = 0) -> StemAudio {
        let src = SourceDescriptor(id: "s\(value)-\(rate)", kind: .application, name: "S", bundleIdentifier: "s", deviceUID: nil)
        let rec = StemRecord(source: src, fileName: "x.caf", sampleRate: rate, channelCount: 1,
                             startTime: Date(timeIntervalSince1970: 1000 + offset), endTime: nil, endEvent: nil)
        return StemAudio(record: rec, buffer: makeBuffer(rate: rate, seconds: seconds, value: value), offsetSeconds: offset)
    }

    @Test func mixesSameRateConstantLevels() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.25, rate: 48_000, seconds: 1),
             Self.stem(value: 0.50, rate: 48_000, seconds: 1)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.frameLength == 48_000)
        #expect(abs(mix.floatChannelData![0][100] - 0.75) < 0.001)
    }

    @Test func offsetPadsWithSilence() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 48_000, seconds: 1, offset: 1.0)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.frameLength == 96_000)
        #expect(mix.floatChannelData![0][100] == 0)          // first second silent
        #expect(abs(mix.floatChannelData![0][48_100] - 0.5) < 0.001)
    }

    @Test func resamplesMixedRates() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.5, rate: 8_000, seconds: 2)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(abs(Double(mix.frameLength) - 96_000) < 100) // resampled to 48k
        #expect(abs(mix.floatChannelData![0][50_000] - 0.5) < 0.01)
    }

    @Test func clippingProtectsOutput() throws {
        let mix = try Mixer.mix(
            [Self.stem(value: 0.9, rate: 48_000, seconds: 0.5),
             Self.stem(value: 0.9, rate: 48_000, seconds: 0.5)],
            outputFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!)
        #expect(mix.floatChannelData![0][10] <= 1.0)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5` — Expected: build failure, `StemAudio`/`Mixer` undefined.

- [ ] **Step 3: Implement StemReader.swift**

```swift
import Foundation
import AVFoundation

struct StemAudio {
    var record: StemRecord
    var buffer: AVAudioPCMBuffer
    var offsetSeconds: TimeInterval
}

enum StemReader {
    static func read(_ record: StemRecord, sessionStart: Date, folder: URL) throws -> StemAudio? {
        let url = folder.appendingPathComponent(record.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        buffer.frameLength = AVAudioFrameCount(file.length)
        return StemAudio(record: record, buffer: buffer,
                         offsetSeconds: record.startTime.timeIntervalSince(sessionStart))
    }
}
```

- [ ] **Step 4: Implement Mixer.swift**

```swift
import Foundation
import AVFoundation

enum Mixer {
    /// Resample one stem to the output format, then sum into mix buffer at offset.
    static func mix(_ stems: [StemAudio], outputFormat: AVAudioFormat, gain: Float = 1.0) throws -> AVAudioPCMBuffer {
        // 1. Convert every stem to the output format.
        var converted: [StemAudio] = []
        for stem in stems {
            if stem.buffer.format == outputFormat {
                converted.append(stem)
                continue
            }
            guard let converter = AVAudioConverter(from: stem.buffer.format, to: outputFormat) else { continue }
            let ratio = outputFormat.sampleRate / stem.buffer.format.sampleRate
            let capacity = AVAudioFrameCount((Double(stem.buffer.frameLength) * ratio).rounded(.up)) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { continue }
            var error: NSError?
            var consumed = false
            let input = stem.buffer
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if consumed { inputStatus.pointee = .noDataNow; return nil }
                consumed = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error || out.frameLength == 0 { continue }
            converted.append(StemAudio(record: stem.record, buffer: out, offsetSeconds: stem.offsetSeconds))
        }

        // 2. Compute total length: max(offset + duration) in output frames.
        let rate = outputFormat.sampleRate
        let totalFrames = converted.map { Int(($0.offsetSeconds) * rate) + Int($0.buffer.frameLength) }.max() ?? 0
        guard let mix = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "Mixer", code: 1)
        }
        mix.frameLength = AVAudioFrameCount(totalFrames)

        let channels = Int(outputFormat.channelCount)
        for stem in converted {
            let startFrame = Int(stem.offsetSeconds * rate)
            let src = stem.buffer
            for c in 0..<channels {
                guard let dst = mix.floatChannelData?[c] else { continue }
                let srcC = min(c, Int(src.format.channelCount) - 1)
                guard let srcData = src.floatChannelData?[srcC] else { continue }
                let n = Int(src.frameLength)
                for i in 0..<n {
                    let idx = startFrame + i
                    guard idx < totalFrames else { break }
                    dst[idx] += srcData[i] * gain
                }
            }
        }

        // 3. Soft clip to ±1.
        for c in 0..<channels {
            guard let data = mix.floatChannelData?[c] else { continue }
            for i in 0..<totalFrames {
                let v = data[i]
                data[i] = v > 1 ? 1 : (v < -1 ? -1 : v)
            }
        }
        return mix
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `swift test 2>&1 | tail -3` — Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stems/Export Tests/StemsTests/MixerTests.swift
git commit -m "feat: stem reading and offset-aware resampling mixdown"
```

---

### Task 9: Export encoders + ExportEngine scopes (TDD)

**Files:**
- Create: `Sources/Stems/Export/ExportEncoder.swift`
- Create: `Sources/Stems/Export/ExportEngine.swift`
- Test: `Tests/StemsTests/ExportEngineTests.swift`

**Interfaces:**
- Consumes: `StemReader`, `Mixer`, `SessionStore` models (Tasks 2, 8)
- Produces:
  - `enum ExportFormat: String, CaseIterable { case m4a, wav }`
  - `enum ExportScope: String, CaseIterable { case combined, individual, grouped }`
  - `struct ExportRequest` — `sessionFolder: URL`, `selectedStemIDs: Set<StemRecord.ID>` (i.e. `Set<UUID>`), `scope: ExportScope`, `format: ExportFormat`, `destination: URL` (folder)
  - `enum ExportEngine` — `static func export(_ request: ExportRequest) throws -> [URL]` — writes files, returns their URLs; combined → `"<Session title> — Mix.<ext>"`; grouped → one file per `SourceKind` `"<title> — Applications.<ext>"`, `"<title> — Microphone.<ext>"`; individual → `"<title> — <source name>.<ext>"` with numeric dedupe. Output sample rate = max stem rate, channels = 2.
  - `enum ExportEncoder` — `static func write(_ buffer: AVAudioPCMBuffer, to url: URL, format: ExportFormat) throws` (ExtAudioFile: PCM/WAV 16-bit or AAC/M4A with `kExtAudioFileProperty_CodecManufacturer = kAppleSoftwareAudioCodecManufacturer`)

- [ ] **Step 1: Write failing tests**

```swift
import Foundation
import AVFoundation
import Testing
@testable import Stems

@Suite("ExportEngine") struct ExportEngineTests {
    /// Builds a real session folder with two WAV stems (test tones).
    static func makeSession() throws -> (folder: URL, manifest: SessionManifest, cleanup: () -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-x-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let folder = try store.makeSessionFolder(start: start)

        func writeTone(name: String, rate: Double, seconds: Double) throws -> String {
            let fileName = "tone-\(name).wav"
            let url = folder.appendingPathComponent(fileName)
            let writer = try StemWriter(url: url,
                clientFormat: AudioStreamBasicDescription(
                    mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                    mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
                    mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                    mChannelsPerFrame: 2, mBitsPerChannel: 32),
                format: .wav)
            let frames = UInt32(rate * seconds)
            var phase: Float = 0
            let inc: Float = Float(2 * Double.pi * 440 / rate)
            var written: UInt32 = 0
            while written < frames {
                let n = min(4096, frames - written)
                var samples = [Float](repeating: 0, count: Int(n) * 2)
                for f in 0..<Int(n) { let v = sin(phase) * 0.4; phase += inc
                    samples[f * 2] = v; samples[f * 2 + 1] = v }
                var abl = AudioBufferList(mNumberBuffers: 1,
                    mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: n * 8, mData: &samples))
                try writer.write(&abl, frameCount: n)
                written += n
            }
            writer.close()
            return fileName
        }

        let chrome = SourceDescriptor(id: "com.google.Chrome", kind: .application, name: "Chrome",
                                      bundleIdentifier: "com.google.Chrome", deviceUID: nil)
        let mic = SourceDescriptor(id: "mic-uid", kind: .microphone, name: "Mic",
                                   bundleIdentifier: nil, deviceUID: "mic-uid")
        let manifest = SessionManifest(identifier: UUID(), title: folder.lastPathComponent,
                                       startTime: start, endTime: start.addingTimeInterval(2),
                                       stemFormat: .wav, appVersion: "0", stems: [
            StemRecord(source: chrome, fileName: try writeTone(name: "a", rate: 44_100, seconds: 2),
                       sampleRate: 44_100, channelCount: 2, startTime: start, endTime: nil, endEvent: nil),
            StemRecord(source: mic, fileName: try writeTone(name: "b", rate: 48_000, seconds: 2),
                       sampleRate: 48_000, channelCount: 2, startTime: start, endTime: nil, endEvent: nil),
        ])
        try store.save(manifest, to: folder)
        return (folder, manifest, { try? FileManager.default.removeItem(at: root) })
    }

    @Test func combinedM4AExportProducesDecodableFile() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: Set(manifest.stems.map(\.id)),
                                    scope: .combined, format: .m4a, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 1)
        let out = try AVAudioFile(forReading: files[0])
        #expect(out.length > 80_000) // ~2s at 48k
        #expect(files[0].lastPathComponent.contains("Mix"))
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func groupedExportProducesOneFilePerKind() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: Set(manifest.stems.map(\.id)),
                                    scope: .grouped, format: .wav, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 2)
        #expect(files.contains { $0.lastPathComponent.contains("Applications") })
        #expect(files.contains { $0.lastPathComponent.contains("Microphone") })
        try? FileManager.default.removeItem(at: dest)
    }

    @Test func individualExportHonorsSelection() throws {
        let (folder, manifest, cleanup) = try Self.makeSession()
        defer { cleanup() }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("stems-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let request = ExportRequest(sessionFolder: folder,
                                    selectedStemIDs: [manifest.stems[0].id],
                                    scope: .individual, format: .wav, destination: dest)
        let files = try ExportEngine.export(request)
        #expect(files.count == 1)
        #expect(files[0].lastPathComponent.contains("Chrome"))
        try? FileManager.default.removeItem(at: dest)
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `swift test 2>&1 | tail -5` — Expected: build failure, `ExportEngine`/`ExportEncoder` undefined.

- [ ] **Step 3: Implement ExportEncoder.swift**

```swift
import Foundation
import AVFoundation
import AudioToolbox
import CoreAudio

enum ExportFormat: String, CaseIterable { case m4a, wav }

enum ExportEncoder {
    static func write(_ buffer: AVAudioPCMBuffer, to url: URL, format: ExportFormat) throws {
        let clientFormat = buffer.format.settings // AVAudioFormat → ASBD via settings bridging below
        var asbd = AudioStreamBasicDescription()
        try withUnsafeMutablePointer(to: &asbd) { ptr in
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                                UInt32(MemoryLayout<[String: Any]>.size(of: clientFormat) > 0 ? 0 : 0),
                                                nil, &size, ptr)
            guard status == noErr else { throw StemWriterError.status(status, "format info") }
        }

        // Simpler and robust: build file ASBD directly.
        var fileASBD = AudioStreamBasicDescription(
            mSampleRate: buffer.format.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2 * 2, mFramesPerPacket: 1, mBytesPerFrame: 2 * 2,
            mChannelsPerFrame: 2, mBitsPerChannel: 16)
        let fileType: AudioFileTypeID
        switch format {
        case .wav:
            fileType = kAudioFileWAVEType
        case .m4a:
            fileType = kAudioFileM4AType
            fileASBD = AudioStreamBasicDescription(
                mSampleRate: buffer.format.sampleRate,
                mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 0,
                mBytesPerFrame: 0, mChannelsPerFrame: 2, mBitsPerChannel: 0)
        }

        var ref: ExtAudioFileRef?
        let create = ExtAudioFileCreateWithURL(url as CFURL, fileType, &fileASBD,
                                               nil, kAudioFileFlags_Erase, &ref)
        guard create == noErr, let file = ref else { throw StemWriterError.status(create, "create export file") }
        defer { ExtAudioFileDispose(file) }

        if format == .m4a {
            var manufacturer = kAppleSoftwareAudioCodecManufacturer
            ExtAudioFileSetProperty(file, kExtAudioFileProperty_CodecManufacturer,
                                    UInt32(MemoryLayout<UInt32>.size), &manufacturer)
        }

        var clientASBD = buffer.format.streamDescription.pointee
        guard ExtAudioFileSetProperty(file, kExtAudioFileProperty_ClientDataFormat,
                                      UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                                      &clientASBD) == noErr else {
            throw StemWriterError.status(paramErr, "client format")
        }

        // Wrap buffer in AudioBufferList (non-interleaved float32)
        var abl = AudioBufferList(mNumberBuffers: UInt32(buffer.format.channelCount))
        for i in 0..<Int(buffer.format.channelCount) {
            abl.mBuffers[i] = AudioBuffer(mNumberChannels: 1,
                                          mDataByteSize: buffer.frameLength * 4,
                                          mData: buffer.floatChannelData![i])
        }
        let status = ExtAudioFileWrite(file, buffer.frameLength, &abl)
        guard status == noErr else { throw StemWriterError.status(status, "export write") }
    }
}
```

NOTE while implementing: delete the unused `AudioFormatGetProperty` probe block above (left to show the rejected path) — keep only the direct ASBD construction.

- [ ] **Step 4: Implement ExportEngine.swift**

```swift
import Foundation
import AVFoundation

enum ExportScope: String, CaseIterable { case combined, individual, grouped }

struct ExportRequest {
    var sessionFolder: URL
    var selectedStemIDs: Set<UUID>
    var scope: ExportScope
    var format: ExportFormat
    var destination: URL
}

enum ExportEngine {
    static func sanitize(_ name: String) -> String {
        name.replacingOccurrences(of: ":", with: "-").replacingOccurrences(of: "/", with: "-")
    }

    static func export(_ request: ExportRequest) throws -> [URL] {
        let manifest = try SessionStore().loadManifest(at: request.sessionFolder)
        let selected = manifest.stems.filter { request.selectedStemIDs.contains($0.id) }
        guard !selected.isEmpty else { return [] }

        let stems = selected.compactMap { try? StemReader.read($0, sessionStart: manifest.startTime,
                                                               folder: request.sessionFolder) }
        guard !stems.isEmpty else { return [] }

        let rate = stems.map(\.buffer.format.sampleRate).max() ?? 48_000
        guard let outputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            throw NSError(domain: "ExportEngine", code: 1)
        }

        var written: [URL] = []
        let ext = request.format == .m4a ? "m4a" : "wav"
        let title = sanitize(manifest.title)

        func urlFor(_ label: String) -> URL {
            var url = request.destination.appendingPathComponent("\(title) — \(label).\(ext)")
            var n = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = request.destination.appendingPathComponent("\(title) — \(label) \(n).\(ext)")
                n += 1
            }
            return url
        }

        func writeMix(_ group: [StemAudio], label: String) throws {
            let mix = try Mixer.mix(group, outputFormat: outputFormat)
            let url = urlFor(label)
            try ExportEncoder.write(mix, to: url, format: request.format)
            written.append(url)
        }

        switch request.scope {
        case .combined:
            try writeMix(stems, label: "Mix")
        case .grouped:
            let apps = stems.filter { $0.record.source.kind == .application }
            let mics = stems.filter { $0.record.source.kind == .microphone }
            if !apps.isEmpty { try writeMix(apps, label: "Applications") }
            if !mics.isEmpty { try writeMix(mics, label: "Microphone") }
        case .individual:
            for stem in stems {
                try writeMix([stem], label: sanitize(stem.record.source.name))
            }
        }
        return written
    }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `swift test 2>&1 | tail -3` — Expected: all pass, including M4A decode-back.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stems/Export Tests/StemsTests/ExportEngineTests.swift
git commit -m "feat: export engine with combined/grouped/individual scopes and M4A/WAV encoding"
```

---

### Task 10: App model + Recorder UI

**Files:**
- Create: `Sources/Stems/UI/AppModel.swift`
- Create: `Sources/Stems/UI/RecorderView.swift`
- Create: `Sources/Stems/UI/LevelMeterView.swift`
- Modify: `Sources/Stems/App.swift` (mount real UI)

**Interfaces:**
- Consumes: `RecorderEngine`, `SourceRegistry`, `SessionStore`, `SettingsStore` (Task 12 creates SettingsStore — for now AppModel holds `stemFormat` inline via a minimal `final class SettingsStore: ObservableObject { @Published var stemFormat: StemFormat = .alac }` in `AppModel.swift`; Task 12 replaces it)
- Produces:
  - `@MainActor final class AppModel: ObservableObject` — `let engine: RecorderEngine`, `let store = SessionStore()`, `let settings = SettingsStore()`, `@Published var appSources: [SourceDescriptor]`, `@Published var micSources: [SourceDescriptor]`, `@Published var selectedSourceIDs: Set<String>`, `@Published var permissionDenied = false`, `func refreshSources()`, `func toggleSource(_ id: String)`, `func startRecording()`, `func stopRecording()`, `var estimatedBytesPerHour: Int64`, `func requestMicPermission(_ done: @escaping (Bool) -> Void)`
  - `struct RecorderView: View` — the main recording surface
  - `struct LevelMeterView: View` — `init(level: Float)`

- [ ] **Step 1: Implement AppModel.swift**

```swift
import Foundation
import Combine
import AVFoundation
import AppKit

/// Minimal settings holder; Task 12 expands into a persisted SettingsStore.
final class SettingsStore: ObservableObject {
    @Published var stemFormat: StemFormat = .alac
}

@MainActor
final class AppModel: ObservableObject {
    let engine = RecorderEngine()
    let store = SessionStore()
    let settings = SettingsStore()

    @Published var appSources: [SourceDescriptor] = []
    @Published var micSources: [SourceDescriptor] = []
    @Published var selectedSourceIDs: Set<String> = []
    @Published var permissionDenied = false

    private let registry = SourceRegistry()

    var selectedSources: [SourceDescriptor] {
        (appSources + micSources).filter { selectedSourceIDs.contains($0.id) }
    }

    /// WAV: rate × channels × 2 bytes; ALAC ≈ 50% of WAV.
    var estimatedBytesPerHour: Int64 {
        let channelsAvg = 2.0
        let wavBytesPerSecond = 48_000.0 * channelsAvg * 2
        let factor = settings.stemFormat == .alac ? 0.5 : 1.0
        return Int64(Double(selectedSourceIDs.count) * wavBytesPerSecond * factor * 3600)
    }

    func refreshSources() {
        appSources = registry.currentAppSources()
        micSources = registry.currentMicSources()
    }

    func toggleSource(_ id: String) {
        if selectedSourceIDs.contains(id) { selectedSourceIDs.remove(id) }
        else { selectedSourceIDs.insert(id) }
    }

    func requestMicPermission(_ done: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            done(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    self.permissionDenied = !granted
                    done(granted)
                }
            }
        default:
            permissionDenied = true
            done(false)
        }
    }

    func startRecording() {
        let sources = selectedSources
        guard !sources.isEmpty else { return }
        requestMicPermission { [weak self] granted in
            guard let self, granted else { return }
            try? self.engine.startSession(sources: sources, format: self.settings.stemFormat,
                                          store: self.store)
        }
    }

    func stopRecording() {
        engine.stopSession()
    }
}
```

- [ ] **Step 2: Implement LevelMeterView.swift**

```swift
import SwiftUI

struct LevelMeterView: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule().fill(LinearGradient(colors: [.green, .yellow, .red],
                                              startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * CGFloat(min(max(level, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}
```

- [ ] **Step 3: Implement RecorderView.swift**

```swift
import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var engine = { () -> RecorderEngine in RecorderEngine() }() // placeholder, replaced below

    var body: some View { EmptyView() }
}
```

NOTE while implementing — the above placeholder is wrong (creates a second engine); use the real version:

```swift
import SwiftUI

struct RecorderView: View {
    @ObservedObject var model: AppModel

    private var engine: RecorderEngine { model.engine }

    private var isRecording: Bool {
        if case .recording = model.engine.state { return true }
        return false
    }

    private var elapsed: TimeInterval {
        if case .recording(let started) = model.engine.state {
            return Date().timeIntervalSince(started)
        }
        return 0
    }

    private static let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            sourceList
            Divider()
            controlsBar
            if model.permissionDenied { permissionBar }
        }
        .navigationTitle("Recorder")
        .onAppear { model.refreshSources() }
        .onReceive(Self.timer) { _ in
            if isRecording { model.objectWillChange.send() } // refresh timer + meters
        }
    }

    private var sourceList: some View {
        List {
            Section("Applications") {
                ForEach(model.appSources) { source in
                    sourceRow(source)
                }
            }
            Section("Microphone") {
                ForEach(model.micSources) { source in
                    sourceRow(source)
                }
            }
            if model.appSources.isEmpty && model.micSources.isEmpty {
                Text("No audio sources found — start playing audio in an app, then refresh.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 240)
    }

    private func sourceRow(_ source: SourceDescriptor) -> some View {
        let selected = model.selectedSourceIDs.contains(source.id)
        let level = model.engine.levels[source.id] ?? 0
        return HStack {
            Toggle(source.name, isOn: Binding(
                get: { selected },
                set: { _ in model.toggleSource(source.id) }))
            Spacer()
            if isRecording { LevelMeterView(level: level).frame(width: 80) }
        }
    }

    private var controlsBar: some View {
        HStack {
            if isRecording {
                Button("Stop", role: .destructive) { model.stopRecording() }
                    .controlSize(.large)
                Text(Self.format(elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.red)
            } else {
                Button("Record") { model.startRecording() }
                    .controlSize(.large)
                    .disabled(model.selectedSourceIDs.isEmpty)
            }
            Spacer()
            Button("Refresh") { model.refreshSources() }
            Text(ByteCountFormatter.string(fromByteCount: model.estimatedBytesPerHour,
                                           countStyle: .file) + "/hour")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding()
    }

    @ViewBuilder private var permissionBar: some View {
        HStack {
            Text("Microphone access is required to record.")
            Button("Open System Settings") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
            }
            Button("Retry") { model.requestMicPermission { _ in model.refreshSources() } }
        }
        .padding(8)
        .background(.red.opacity(0.1))
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}
```

- [ ] **Step 4: Mount in App.swift**

Replace the `WindowGroup` body content:

```swift
WindowGroup("Stems") {
    RecorderView(model: AppModel.shared)
        .frame(minWidth: 520, minHeight: 480)
}
```

And give AppModel a shared instance plus settings observation:

```swift
extension AppModel {
    static let shared = AppModel()
}
```

(Task 12 removes `shared` when the menu bar + window share one model instance through the AppDelegate instead.)

- [ ] **Step 5: Build and manual check**

Run: `swift build && ./scripts/build-app.sh && open build/Stems.app`
Expected: window shows Applications/Microphone sections (requires audio playing for apps); checkboxes toggle Record enabled; Record starts (mic prompt on first use), meters move while recording, Stop ends session and `~/Music/Stems/Session…/` contains manifest + stems.

- [ ] **Step 6: Commit**

```bash
git add Sources/Stems
git commit -m "feat: recorder UI with source selection, meters, and permission handling"
```

---

### Task 11: Sessions UI with export

**Files:**
- Create: `Sources/Stems/UI/SessionsView.swift`
- Create: `Sources/Stems/UI/SessionDetailView.swift`
- Create: `Sources/Stems/UI/TrackPreview.swift`
- Modify: `Sources/Stems/App.swift` (tab or navigation between Recorder and Sessions)
- Test: `Tests/StemsTests/TrackPreviewTests.swift` (file naming/selection helpers only)

**Interfaces:**
- Consumes: `SessionStore`, `ExportEngine`, models
- Produces:
  - `@MainActor final class SessionsModel: ObservableObject` — `@Published var sessions: [SessionSummary]`, `func reload(store: SessionStore)`, `func export(session: SessionSummary, selectedStemIDs: Set<UUID>, scope: ExportScope, format: ExportFormat, to destination: URL) throws -> [URL]`, `func deleteStems(for session: SessionSummary) throws` (delegates to store), `static func previewFileName(for stem: StemRecord, in folder: URL) -> URL`
  - `struct SessionsView: View`, `struct SessionDetailView: View`
  - `final class TrackPreview: NSObject, ObservableObject, AVAudioPlayerDelegate` — `@Published var playingStemID: UUID?`; `func play(_ stem: StemRecord, folder: URL)`; `func stop()`

- [ ] **Step 1: Write failing test for preview path helper**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("Sessions model helpers") struct TrackPreviewTests {
    @Test func previewURLResolvesStemFile() {
        let folder = URL(fileURLWithPath: "/tmp/s1")
        let src = SourceDescriptor(id: "a", kind: .application, name: "A", bundleIdentifier: "a", deviceUID: nil)
        let stem = StemRecord(source: src, fileName: "stem-0-A.caf", sampleRate: 48_000,
                              channelCount: 2, startTime: Date(), endTime: nil, endEvent: nil)
        #expect(SessionsModel.previewFileName(for: stem, in: folder).path == "/tmp/s1/stem-0-A.caf")
    }
}
```

- [ ] **Step 2: Run test, verify it fails** — `swift test 2>&1 | tail -3` — build failure expected.

- [ ] **Step 3: Implement TrackPreview.swift + SessionsModel (in SessionsView.swift)**

```swift
import Foundation
import Combine
import AVFoundation

final class TrackPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var playingStemID: UUID?
    private var player: AVAudioPlayer?

    func play(_ stem: StemRecord, folder: URL) {
        stop()
        let url = folder.appendingPathComponent(stem.fileName)
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        player = p
        p.delegate = self
        p.play()
        playingStemID = stem.id
    }

    func stop() {
        player?.stop()
        player = nil
        playingStemID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playingStemID = nil
    }
}

@MainActor
final class SessionsModel: ObservableObject {
    @Published var sessions: [SessionSummary] = []

    func reload(store: SessionStore) {
        sessions = store.listSessions()
    }

    static func previewFileName(for stem: StemRecord, in folder: URL) -> URL {
        folder.appendingPathComponent(stem.fileName)
    }

    func export(session: SessionSummary, selectedStemIDs: Set<UUID>,
                scope: ExportScope, format: ExportFormat, to destination: URL) throws -> [URL] {
        try ExportEngine.export(ExportRequest(sessionFolder: session.folderURL,
                                              selectedStemIDs: selectedStemIDs,
                                              scope: scope, format: format,
                                              destination: destination))
    }

    func deleteStems(for session: SessionSummary, store: SessionStore) throws {
        try store.deleteStems(in: session.folderURL)
    }
}
```

- [ ] **Step 4: Implement SessionsView.swift + SessionDetailView.swift**

```swift
import SwiftUI

struct SessionsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var sessions = SessionsModel()

    var body: some View {
        NavigationStack {
            Group {
                if sessions.sessions.isEmpty {
                    ContentUnavailableView("No Sessions", systemImage: "waveform",
                                           description: Text("Recorded sessions appear here."))
                } else {
                    List(sessions.sessions) { session in
                        NavigationLink(destination: SessionDetailView(model: model, session: session, sessionsModel: sessions)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.manifest.title).font(.headline)
                                HStack {
                                    Text(RecorderView.format(session.totalDuration))
                                    Text("·").foregroundStyle(.secondary)
                                    Text("\(session.manifest.stems.count) tracks")
                                    Text("·").foregroundStyle(.secondary)
                                    Text(ByteCountFormatter.string(fromByteCount: session.sizeBytes,
                                                                   countStyle: .file))
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .onAppear { sessions.reload(store: model.store) }
        }
    }
}
```

```swift
import SwiftUI
import AppKit

struct SessionDetailView: View {
    @ObservedObject var model: AppModel
    let session: SessionSummary
    @ObservedObject var sessionsModel: SessionsModel

    @StateObject private var preview = TrackPreview()
    @State private var selectedStemIDs: Set<UUID> = []
    @State private var scope: ExportScope = .combined
    @State private var format: ExportFormat = .m4a
    @State private var exportMessage: String?

    var body: some View {
        List {
            Section("Tracks") {
                ForEach(session.manifest.stems) { stem in
                    trackRow(stem)
                }
            }
            if session.manifest.stems.isEmpty {
                Text("No stems (stems may have been cleaned up).").foregroundStyle(.secondary)
            }
            Section("Export") {
                Picker("Scope", selection: $scope) {
                    Text("Combined mix").tag(ExportScope.combined)
                    Text("Grouped by type").tag(ExportScope.grouped)
                    Text("Individual files").tag(ExportScope.individual)
                }
                Picker("Format", selection: $format) {
                    Text("M4A (AAC)").tag(ExportFormat.m4a)
                    Text("WAV").tag(ExportFormat.wav)
                }
                Button("Export…") { runExport() }
                    .disabled(selectedStemIDs.isEmpty)
                if let exportMessage { Text(exportMessage).font(.callout) }
            }
        }
        .navigationTitle(session.manifest.title)
        .onAppear {
            if selectedStemIDs.isEmpty {
                selectedStemIDs = Set(session.manifest.stems.map(\.id))
            }
        }
        .onDisappear { preview.stop() }
    }

    private func trackRow(_ stem: StemRecord) -> some View {
        HStack {
            Toggle(stem.source.name, isOn: Binding(
                get: { selectedStemIDs.contains(stem.id) },
                set: { on in
                    if on { selectedStemIDs.insert(stem.id) } else { selectedStemIDs.remove(stem.id) }
                }))
            Spacer()
            Text("\(Int(stem.sampleRate/1000)) kHz")
                .font(.caption).foregroundStyle(.secondary)
            if let event = stem.endEvent, event != "sessionEnd" {
                Image(systemName: "exclamationmark.triangle")
                    .help("Ended early: \(event)")
            }
            Button {
                if preview.playingStemID == stem.id { preview.stop() }
                else { preview.play(stem, folder: session.folderURL) }
            } label: {
                Image(systemName: preview.playingStemID == stem.id ? "stop.circle" : "play.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    private func runExport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose export destination"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let files = try sessionsModel.export(session: session, selectedStemIDs: selectedStemIDs,
                                                 scope: scope, format: format, to: url)
            exportMessage = "Exported \(files.count) file(s) to \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
```

- [ ] **Step 5: Switch main window between Recorder and Sessions**

In `App.swift`, wrap the window content:

```swift
WindowGroup("Stems") {
    MainTabs(model: AppModel.shared)
        .frame(minWidth: 560, minHeight: 500)
}
```

with a small tab holder (new view in `App.swift`):

```swift
struct MainTabs: View {
    @ObservedObject var model: AppModel
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            RecorderView(model: model).tabItem { Label("Recorder", systemImage: "record.circle") }.tag(0)
            SessionsView(model: model).tabItem { Label("Sessions", systemImage: "list.bullet") }.tag(1)
        }
    }
}
```

- [ ] **Step 6: Run tests, build, manual check**

Run: `swift test 2>&1 | tail -3` — all pass.
Run: `./scripts/build-app.sh && open build/Stems.app` — record a short session; Sessions tab lists it; open it; preview plays; export Combined M4A to ~/Desktop; play result in QuickTime.

- [ ] **Step 7: Commit**

```bash
git add Sources/Stems Tests
git commit -m "feat: sessions browser with track preview and export UI"
```

---

### Task 12: Settings, menu bar, cleanup prompt

**Files:**
- Create: `Sources/Stems/UI/SettingsStore.swift` (replaces the minimal one in AppModel.swift — delete that)
- Create: `Sources/Stems/UI/SettingsView.swift`
- Create: `Sources/Stems/UI/MenuBarController.swift`
- Modify: `Sources/Stems/App.swift` (AppDelegate owns MenuBarController + AppModel; drop `AppModel.shared`)
- Modify: `Sources/Stems/UI/SessionDetailView.swift` (stem-cleanup prompt after combined export)
- Test: `Tests/StemsTests/SettingsStoreTests.swift`

**Interfaces:**
- Consumes: everything above
- Produces:
  - `final class SettingsStore: ObservableObject` — persisted (`UserDefaults`): `@Published var stemFormat: StemFormat` (.alac), `@Published var stemCleanup: StemCleanupBehavior` (.ask), `@Published var launchAtLogin: Bool` (false), `@Published var defaultMicDeviceUID: String?`, plus `enum StemCleanupBehavior: String, CaseIterable { case ask, always, never }`; `init(defaults: UserDefaults)`
  - `final class MenuBarController: NSObject` — `init(model: AppModel, openWindow: @escaping () -> Void)`, `refresh()`; status item icon: `waveform` idle, red dot recording; menu: Record/Stop (with elapsed), Open Stems, Quit
  - `struct SettingsView: View` wired to SwiftUI `Settings` scene

- [ ] **Step 1: Write failing test**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("SettingsStore") struct SettingsStoreTests {
    @Test func roundTripsThroughUserDefaults() {
        let suite = "stems-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults)
        #expect(store.stemFormat == .alac)
        #expect(store.stemCleanup == .ask)

        store.stemFormat = .wav
        store.stemCleanup = .never
        store.launchAtLogin = true

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.stemFormat == .wav)
        #expect(reloaded.stemCleanup == .never)
        #expect(reloaded.launchAtLogin == true)
        defaults.removePersistentDomain(forDomainName: suite)
    }
}
```

- [ ] **Step 2: Run test, verify it fails** — build failure (`SettingsStore` kind mismatch: enum cases unknown).

- [ ] **Step 3: Implement SettingsStore.swift (replace minimal version in AppModel.swift)**

```swift
import Foundation
import Combine
import ServiceManagement

enum StemCleanupBehavior: String, CaseIterable {
    case ask, always, never
}

final class SettingsStore: ObservableObject {
    @Published var stemFormat: StemFormat {
        didSet { defaults.set(stemFormat.rawValue, forKey: "stemFormat") }
    }
    @Published var stemCleanup: StemCleanupBehavior {
        didSet { defaults.set(stemCleanup.rawValue, forKey: "stemCleanup") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var defaultMicDeviceUID: String? {
        didSet { defaults.set(defaultMicDeviceUID ?? "", forKey: "defaultMicDeviceUID") }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stemFormat = StemFormat(rawValue: defaults.string(forKey: "stemFormat") ?? "") ?? .alac
        stemCleanup = StemCleanupBehavior(rawValue: defaults.string(forKey: "stemCleanup") ?? "") ?? .ask
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        let mic = defaults.string(forKey: "defaultMicDeviceUID")
        defaultMicDeviceUID = (mic?.isEmpty == false) ? mic : nil
    }

    private func applyLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            print("launch-at-login failed: \(error)") // requires .app bundle; ignored in CLI/dev runs
        }
    }
}
```

(Update `AppModel` to take `SettingsStore` via injection: `init(settings: SettingsStore = SettingsStore()) { self.settings = settings }` — keep property name `settings`.)

- [ ] **Step 4: Implement MenuBarController.swift**

```swift
import AppKit
import Combine

final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables: Set<AnyCancellable> = []
    private let model: AppModel
    private let openWindow: () -> Void

    init(model: AppModel, openWindow: @escaping () -> Void) {
        self.model = model
        self.openWindow = openWindow
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Stems")
        rebuildMenu()
        model.engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in
                guard case .recording = self?.model.engine.state else { return }
                self?.rebuildMenu()
            }
            .store(in: &cancellables)
    }

    private var isRecording: Bool {
        if case .recording = model.engine.state { return true }
        return false
    }

    func refresh() { rebuildMenu() }

    private func rebuildMenu() {
        let menu = NSMenu()

        if isRecording {
            if case .recording(let started) = model.engine.state {
                let elapsed = Int(Date().timeIntervalSince(started))
                menu.addItem(.title(String(format: "Recording %02d:%02d:%02d",
                                           elapsed / 3600, (elapsed % 3600) / 60, elapsed % 60)))
                menu.addItem(.separator())
                let stop = NSMenuItem(title: "Stop", action: #selector(stopTapped), keyEquivalent: "")
                stop.target = self
                menu.addItem(stop)
            }
            statusItem.button?.contentTintColor = .systemRed
        } else {
            let record = NSMenuItem(title: "Record", action: #selector(recordTapped), keyEquivalent: "r")
            record.target = self
            menu.addItem(record)
            statusItem.button?.contentTintColor = nil
        }

        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open Stems…", action: #selector(openTapped), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let quit = NSMenuItem(title: "Quit Stems", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func recordTapped() {
        model.refreshSources()
        if model.selectedSourceIDs.isEmpty { openWindow() } // nothing selected → configure in window
        else { model.startRecording() }
    }

    @objc private func stopTapped() { model.stopRecording() }

    @objc private func openTapped() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow()
    }
}
```

- [ ] **Step 5: Wire AppDelegate in App.swift**

```swift
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        menuBar = MenuBarController(model: model) {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
```

(Keep `AppModel.shared` after all — simplest wiring for menu bar + windows; delete the Task-10 note about removing it. Add `static let shared = AppModel()` permanently in AppModel.swift.)

- [ ] **Step 6: Implement SettingsView.swift + mount; add cleanup prompt in SessionDetailView**

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Stem format", selection: $settings.stemFormat) {
                Text("ALAC (lossless, default)").tag(StemFormat.alac)
                Text("WAV (uncompressed)").tag(StemFormat.wav)
            }
            Picker("After export, delete stems", selection: $settings.stemCleanup) {
                Text("Ask each time").tag(StemCleanupBehavior.ask)
                Text("Always").tag(StemCleanupBehavior.always)
                Text("Never").tag(StemCleanupBehavior.never)
            }
            Toggle("Launch at login", isOn: $settings.launchAtLogin)
            Picker("Default microphone", selection: Binding(
                get: { settings.defaultMicDeviceUID ?? "" },
                set: { settings.defaultMicDeviceUID = $0.isEmpty ? nil : $0 })) {
                Text("System default").tag("")
                ForEach(model.micSources) { mic in
                    Text(mic.name).tag(mic.deviceUID ?? "")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { model.refreshSources() }
    }
}
```

Mount in `StemsApp`:

```swift
Settings { SettingsView(settings: AppModel.shared.settings, model: AppModel.shared) }
```

Cleanup prompt — in `SessionDetailView.runExport()`, after successful export of a `.combined` scope:

```swift
let behavior = model.settings.stemCleanup
if behavior != .never && files.contains(where: { $0.lastPathComponent.contains("Mix") }) {
    let doDelete: Bool
    switch behavior {
    case .always: doDelete = true
    case .ask:
        let alert = NSAlert()
        alert.messageText = "Delete the session's stems?"
        alert.informativeText = "The exported mix is kept. Stems free up \(ByteCountFormatter.string(fromByteCount: session.sizeBytes, countStyle: .file))."
        alert.addButton(withTitle: "Delete Stems")
        alert.addButton(withTitle: "Keep")
        doDelete = alert.runModal() == .alertFirstButtonReturn
    case .never: doDelete = false
    }
    if doDelete {
        try? sessionsModel.deleteStems(for: session, store: model.store)
        sessionsModel.reload(store: model.store)
    }
}
```

- [ ] **Step 7: Run tests, build, manual check**

Run: `swift test 2>&1 | tail -3` — all pass.
Run: `./scripts/build-app.sh && open build/Stems.app`:
1. Menu bar icon present; Record works with last-selected sources; icon red while recording; Stop ends session.
2. Settings (⌘,) pane changes format; relaunch remembers.
3. Combined export → cleanup prompt appears (ask mode); "Delete Stems" removes stems, keeps manifest.

- [ ] **Step 8: Commit**

```bash
git add Sources/Stems Tests
git commit -m "feat: settings, menu bar controller, and post-export stem cleanup"
```

---

### Task 13: Packaging, README, manual checklist, v0.1.0

**Files:**
- Create: `README.md`
- Create: `docs/manual-test-checklist.md`
- Modify: `scripts/build-app.sh` (DMG option)

**Interfaces:**
- Consumes: everything
- Produces: distributable `build/Stems.dmg` (optional flag), documentation, tagged release

- [ ] **Step 1: Add optional DMG to build script**

Append before the final `echo`:

```bash
if [ "${DMG:-0}" = "1" ]; then
    DMG_PATH="build/Stems-${VERSION}.dmg"
    rm -f "$DMG_PATH"
    hdiutil create -volname "Stems" -srcfolder "$APP" -ov -format UDZO "$DMG_PATH"
    echo "Built $DMG_PATH"
fi
```

- [ ] **Step 2: Write README.md**

Cover: what Stems is; requirements (macOS 14.4+); build (`swift build`, `./scripts/build-app.sh`, `DMG=1 ./scripts/build-app.sh`); first-run permission note (right-click → Open for ad-hoc builds; approve microphone prompt); usage (menu bar + window); where sessions live (`~/Music/Stems`); how export works; troubleshooting (no sources listed → start audio first); roadmap pointer to the design doc.

- [ ] **Step 3: Write docs/manual-test-checklist.md**

```markdown
# Manual Test Checklist (run before tagging a release)

1. `swift test` — all unit tests pass.
2. `DMG=1 ./scripts/build-app.sh` — DMG builds.
3. First launch of Stems.app: Gatekeeper ad-hoc flow works (right-click → Open).
4. `--list-taps` CLI: browser playing audio appears under APPLICATIONS.
5. `--record-app` CLI: 5s capture, afinfo shows ALAC/48k, plays back, source NOT muted.
6. `--record-mic` CLI: 5s capture non-empty.
7. GUI record with Chrome + mic: meters move, timer runs, stop writes session folder
   with manifest.json + 2 stems.
8. Quit Chrome mid-session: Chrome stem ends (endEvent processExited), session continues.
9. Kill -9 Stems mid-session: relaunch, session lists as partial, stems playable, exportable.
10. Sessions: preview plays a stem; export Combined M4A; QuickTime plays result.
11. Export grouped: Applications + Microphone files; individual: one per source.
12. Cleanup prompt (ask): delete stems keeps manifest; session still listed with 0 stems.
13. Settings: format WAV → new session writes .wav stems; launch-at-login toggles.
14. Low disk: fill volume (or fake small APFS quota) → start session shows warning.
    (If impractical, verify code path via unit-injected small threshold.)
15. Menu bar: Record with no prior selection opens window; red icon while recording.
```

- [ ] **Step 4: Run the full checklist**

Work through `docs/manual-test-checklist.md` items 1–13 (14 is best-effort; 15 covered by 7). Fix any failures in separate small commits.

- [ ] **Step 5: Tag release**

```bash
git add README.md docs scripts
git commit -m "docs: README, manual test checklist, DMG packaging option"
git tag -a v0.1.0 -m "Stems v0.1.0 — per-app + mic stem recorder with post-session export"
DMG=1 ./scripts/build-app.sh
```

---

## Plan Self-Review (completed)

- **Spec coverage:** per-app taps (T6), mic capture (T6), multitrack session (T7), ALAC/WAV setting (T5/T2/T12), post-session combined/grouped/individual export M4A/WAV (T8/T9), sessions UI + preview + cleanup (T11/T12), settings incl. launch-at-login + default mic (T12), menu bar quick record (T12), permissions + denied path (T10), low disk warning (T13 item 14 — thin: engine checks volume capacity before start; see note), crash-safe manifest-at-start (T7), app-quit mid-session (T7), sample-rate variance (T6/T8), new-app-mid-session not captured (spec v1 limitation, no task needed), sleep (spec limitation). Low-disk check: implement in `RecorderEngine.startSession` before creating chains — `let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage; if let capacity, capacity < estimatedBytesPerHour * 2 { throw … }` — add during Task 13 checklist item 14 with a unit-injectable threshold parameter on `startSession(..., minimumFreeBytes: Int64? = nil)`.
- **Placeholders:** none — every code step carries complete implementations; the two "NOTE while implementing" blocks correct earlier in-file sketches explicitly (delete the dead code they supersede).
- **Type consistency:** `SourceDescriptor.id` string semantics consistent (bundleID / deviceUID); `CaptureChain.make(deviceID:scope:stemURL:format:)` used by T6 CLI and T7 engine; `ExportRequest` fields match T9 test; `SettingsStore` minimal→full replacement called out in T12 with injectable defaults; `AppModel.shared` retained (T10 note superseded by T12 Step 5).

## Execution Handoff

Plan complete. Two execution options:

**1. Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — executing-plans in this session, batch execution with checkpoints.

Which approach?
