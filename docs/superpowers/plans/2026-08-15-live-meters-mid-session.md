# Stems — Live Meters & Mid-Session Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every source row shows a live VU meter while the Recorder window is visible (independent of selection), and checkboxes become live mid-session controls (tick = source joins the running session, untick = stem ends with `userRemoved`).

**Architecture:** Reuse the v0.1.0 capture machinery: a meter-only `MeterChain` (IOProc → RMS, no file) driven by a `MeterManager` that reconciles live meter taps against pure-computed targets (`rows − recording − window-gate`). `RecorderEngine` gains `addSource`/`removeSource` for live session mutation; tap disposal moves into `stemEnded` so mid-session removals free resources. A `SourceResolver` helper extracts device-resolution logic shared by recording and metering.

**Tech Stack:** Swift 5 mode, SwiftPM, Core Audio (existing proven spellings in the codebase), SwiftUI/AppKit, Swift Testing. Zero third-party dependencies.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-08-15-live-meters-mid-session-design.md` (authoritative).
- **Platform:** macOS 14.4+; **zero third-party deps**; Swift 5 language mode.
- **All taps `.unmuted`** (non-destructive) — copy the pattern from `Sources/Stems/Core/ProcessTap.swift`.
- **Realtime discipline (binding, from v0.1.0 review history):** no HAL property reads, allocation, or locks on the IOProc thread; teardown hops a serial queue; exactly-once end callbacks via check-and-set inside the serial block. Mirror `Sources/Stems/Core/CaptureChain.swift` — it is the working reference for SDK-exact IOProc signatures on this machine (inputData is a non-optional `UnsafePointer<AudioBufferList>`; HAL NULLs `mData` for disabled streams; throttle via `ProcessInfo.processInfo.systemUptime`; levels delivered via `DispatchQueue.main.async`).
- **Double-tap rule:** a source is never meter-tapped and recording-tapped simultaneously. Coordination owned by AppModel via `meterTargets(...)`.
- **Window gate:** meters run only while the Stems window is visible. The window HIDES on close (`orderOut` — see `Sources/Stems/App.swift` `HideOnCloseWindowDelegate`), so SwiftUI `onDisappear` is unreliable; gate on NSWindow/NSApplication notifications.
- **Errors surfaced, never swallowed:** user-facing failures go through `lastError` (inline red text + menu-bar alert, both existing). New error types conform `LocalizedError`.
- **No audio playback during verification except the single-finite-afplay protocol** (one `afplay <file> &`, kill after, remove temp file — the user was burned by a stray loop).
- Every task ends with `swift build` clean, `swift test` all-green, then commit (`feat:`/`fix:`/`docs:` + imperative).

## Interfaces produced (shared vocabulary)

- `SourceResolver.resolve(source:registry:) -> (deviceID: AudioObjectID, tap: ProcessTapSession?)?` (Task 1)
- `MeterChain.make(deviceID:scope:tap:) throws -> MeterChain`, `start() throws`, `stop()`, `onLevel: ((Float) -> Void)?` (Task 1)
- `meterTargets(rowIDs:windowVisible:recordingSourceIDs:) -> Set<String>` (pure), `MeterManager` (@MainActor, `@Published meterLevels: [String: Float]`, `reconcile(targets:sources:)`, `stopAll()`) (Task 2)
- `RecorderEngine.addSource(_:) throws`, `removeSource(id:)`, `recordingSourceIDs: Set<String>`, `EngineMutationError` (Task 3)
- `AppModel.level(for:) -> Float`, `@Published var metersOn: Bool` (Task 4)

---

### Task 1: SourceResolver + MeterChain + `--meter` CLI

**Files:**
- Create: `Sources/Stems/Core/SourceResolver.swift`
- Create: `Sources/Stems/Core/MeterChain.swift`
- Modify: `Sources/Stems/Core/CaptureChain.swift` (rename `private static func inputFormat` → `static func inputStreamFormat`, same body; update its one call site)
- Modify: `Sources/Stems/Core/RecorderEngine.swift` (use `SourceResolver` in `startSession` — behavior unchanged)
- Modify: `Sources/Stems/main.swift` + `Sources/Stems/Core/RecordCLI.swift` (`--meter`)

**Interfaces:**
- Consumes: `ProcessTapSession.create(processObjectIDs:name:)`, `CaptureChain.make`, `SourceRegistry.processObjectIDs(for:)`/`deviceID(forUID:)`, `AudioProperty.defaultInputDeviceID`
- Produces: `SourceResolver.resolve(source:registry:)`, `MeterChain` as above; CLI `Stems --meter <bundleID|pid:N|mic> --seconds N`

- [ ] **Step 1: Create SourceResolver.swift**

```swift
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
```

- [ ] **Step 2: Refactor CaptureChain.inputFormat → inputStreamFormat (internal)**

In `Sources/Stems/Core/CaptureChain.swift`: change `private static func inputFormat(deviceID:scope:)` to `static func inputStreamFormat(deviceID:scope:)` (same signature/body), update the call in `make()`. No behavior change; `swift build` + `swift test` must stay green (32 tests).

- [ ] **Step 3: Create MeterChain.swift**

```swift
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
    private var lastMeterAt: 0.0 = 0
    private var ended = false          // teardownQueue-confined (see stop())

    /// Owned tap session for application sources; nil for input devices.
    private var tap: ProcessTapSession?
    var onLevel: ((Float) -> Void)?    // ~10 Hz, delivered on main

    private init(deviceID: AudioObjectID, scope: AudioObjectPropertyScope, bytesPerFrame: Int, tap: ProcessTapSession?) {
        self.deviceID = deviceID
        self.scope = scope
        self.bytesPerFrame = bytesPerFrame
        self.tap = tap
    }

    static func make(deviceID: AudioObjectID, scope: AudioObjectPropertyScope, tap: ProcessTapSession?) throws -> MeterChain {
        guard let asbd = CaptureChain.inputStreamFormat(deviceID: deviceID, scope: scope) else {
            throw StemWriterError.status(paramErr, "no input stream format on meter device \(deviceID)")
        }
        return MeterChain(deviceID: deviceID, scope: scope, bytesPerFrame: Int(asbd.mBytesPerFrame), tap: tap)
    }

    func start() throws {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        // IOProc mirrors CaptureChain's shape exactly; only the meter block
        // and (no) write differ.
        let ioProc: AudioDeviceIOProc = { _, _, inputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let chain = Unmanaged<MeterChain>.fromOpaque(clientData).takeUnretainedValue()
            guard let input = inputData?.pointee, input.mNumberBuffers > 0,
                  let data = input.mBuffers.mData, input.mBuffers.mDataByteSize > 0 else { return noErr }
            let byteSize = Int(input.mBuffers.mDataByteSize)
            let frameCount = UInt32(byteSize / max(chain.bytesPerFrame, 1))
            _ = frameCount
            if ProcessInfo.processInfo.systemUptime - chain.lastMeterAt > 0.1 {
                chain.lastMeterAt = ProcessInfo.processInfo.systemUptime
                let samples = data.assumingMemoryBound(to: Float.self)
                var sum: Float = 0
                let n = byteSize / 4
                for i in 0..<n { let v = samples[i]; sum += v * v }
                let rms = n > 0 ? sqrt(sum / Float(n)) : 0
                if let onLevel = chain.onLevel {
                    DispatchQueue.main.async { onLevel(min(rms * 4, 1)) } // gain for visibility
                }
            }
            return noErr
        }
        let status = AudioDeviceCreateIOProcID(deviceID, ioProc, selfPtr, &ioProcID)
        guard status == noErr else {
            var localTap = tap
            localTap?.dispose()
            self.tap = nil
            throw StemWriterError.status(status, "AudioDeviceCreateIOProcID (meter)")
        }
        AudioDeviceStart(deviceID, ioProcID)
    }

    /// Idempotent; safe from any thread (teardown hops the serial queue).
    func stop() {
        teardownQueue.async { [self] in
            guard !ended else { return }
            ended = true
            if let ioProcID {
                AudioDeviceStop(deviceID, ioProcID)
                AudioDeviceDestroyIOProcID(deviceID, ioProcID)
            }
            ioProcID = nil
            tap?.dispose()
            tap = nil
        }
    }
}
```

NOTE: adapt the IOProc closure signature to whatever compiles against the current `CaptureChain.swift` (that file is the proven reference — read it first). The dispose-on-start-failure path must not double-dispose with `stop()` (both nil out `tap` on main/confined state — keep tap mutation confined to the same discipline CaptureChain uses).

- [ ] **Step 4: Use SourceResolver in RecorderEngine.startSession**

Replace the inline switch that resolves `deviceID`/`tap` per source with `guard let resolved = SourceResolver.resolve(source: source, registry: registry) else { continue }` (keep the skip-pruning semantics identical). Build + tests stay green.

- [ ] **Step 5: Add `--meter` CLI**

`main.swift` case: `--meter <id>` with `--seconds N` (default 5). In `RecordCLI.swift` add `static func meter(id: String, seconds: Double) -> Int32`: resolve id via SourceRegistry (bundleID match against `currentAppSources()`, else `"mic"` uses default input device), build MeterChain, print 10 Hz bars like the existing record commands (reuse the bar-padding style), stop after N seconds, exit 0. Unknown id → stderr line + exit 1.

- [ ] **Step 6: Verify**

`swift build && swift test` (32/32). Smoke with single-finite-afplay protocol: `say -o /tmp/t.aiff "meter smoke"`; `afplay /tmp/t.aiff &`; `swift run Stems --meter afplay --seconds 4`; `kill %1`; `rm /tmp/t.aiff`. Expect bars while playing. Also `swift run Stems --meter mic --seconds 3` (ambient is fine — bars or flat both prove the chain runs).

- [ ] **Step 7: Commit** — `feat: meter-only capture chain with shared source resolver and --meter CLI`

---

### Task 2: meterTargets + MeterManager (TDD)

**Files:**
- Create: `Sources/Stems/Core/MeterManager.swift` (contains pure function + class)
- Test: `Tests/StemsTests/MeterTargetsTests.swift`

**Interfaces:**
- Consumes: `MeterChain`, `SourceResolver`, `SourceDescriptor`
- Produces: `func meterTargets(rowIDs: [String], windowVisible: Bool, recordingSourceIDs: Set<String>) -> Set<String>`; `@MainActor final class MeterManager: ObservableObject` — `@Published private(set) var meterLevels: [String: Float]`, `func reconcile(targets: Set<String>, sources: [String: SourceDescriptor])`, `func stopAll()`

- [ ] **Step 1: Failing tests**

```swift
import Testing
@testable import Stems

@Suite("meterTargets") struct MeterTargetsTests {
    @Test func windowClosedMeansNoTargets() {
        #expect(meterTargets(rowIDs: ["a", "b"], windowVisible: false, recordingSourceIDs: []) == [])
    }
    @Test func subtractsRecordingSources() {
        #expect(meterTargets(rowIDs: ["a", "b", "c"], windowVisible: true, recordingSourceIDs: ["b"]) == ["a", "c"])
    }
    @Test func rowsNotListedAreNeverTargets() {
        #expect(meterTargets(rowIDs: ["a"], windowVisible: true, recordingSourceIDs: []) == ["a"])
        #expect(meterTargets(rowIDs: [], windowVisible: true, recordingSourceIDs: []) == [])
    }
}
```

- [ ] **Step 2: Run, verify failure** (`cannot find 'meterTargets' in scope`).

- [ ] **Step 3: Implement**

```swift
import Foundation
import Combine
import CoreAudio

/// Pure coordination: which row ids get meter taps right now.
/// The double-tap rule lives here — recording sources are never metered.
func meterTargets(rowIDs: [String], windowVisible: Bool, recordingSourceIDs: Set<String>) -> Set<String> {
    guard windowVisible else { return [] }
    return Set(rowIDs).subtracting(recordingSourceIDs)
}

@MainActor
final class MeterManager: ObservableObject {
    @Published private(set) var meterLevels: [String: Float] = [:]
    private var chains: [String: MeterChain] = [:]
    private let registry = SourceRegistry()

    /// Idempotent: start meter chains for added targets, stop for removed.
    /// Sources whose chain fails to start (app quit between enumerate and
    /// resolve) are simply absent — no error surfaced; the row sits flat.
    func reconcile(targets: Set<String>, sources: [String: SourceDescriptor]) {
        for (id, chain) in chains where !targets.contains(id) {
            chain.stop()
            chains[id] = nil
            meterLevels[id] = nil
        }
        for id in targets where chains[id] == nil {
            guard let source = sources[id],
                  let resolved = SourceResolver.resolve(source: source, registry: registry),
                  let chain = try? MeterChain.make(deviceID: resolved.deviceID,
                                                   scope: kAudioObjectPropertyScopeInput,
                                                   tap: resolved.tap) else { continue }
            chain.onLevel = { [weak self] level in self?.meterLevels[id] = level }
            do { try chain.start(); chains[id] = chain }
            catch { chain.stop() }
        }
    }

    func stopAll() { reconcile(targets: [], sources: [:]) }
}

extension Array where Element == SourceDescriptor {
    subscript(id id: String) -> SourceDescriptor? {
        first { $0.id == id }
    }
}
extension Dictionary where Key == String, Value == SourceDescriptor {
    // sources dict is built by callers via Dictionary(uniqueKeysWithValues:)
}
```

Delete the `Dictionary` extension stub if unused; `sources[id]` in the reconcile loop should be `sources.first(where: { $0.key == id })?.value` if a plain dictionary subscript reads awkwardly — keep it simple, AppModel passes `[String: SourceDescriptor]`.

- [ ] **Step 4: Green, full suite (35 tests)**

- [ ] **Step 5: Commit** — `feat: meter manager with pure target coordination`

---

### Task 3: RecorderEngine live mutation (TDD)

**Files:**
- Modify: `Sources/Stems/Core/RecorderEngine.swift`
- Test: `Tests/StemsTests/RecorderEngineMutationTests.swift`

**Interfaces:**
- Consumes: `SourceResolver`, `CaptureChain.make` (clientFormat), existing stem/manifest plumbing
- Produces: `EngineMutationError` (LocalizedError: `.notRecording`, `.unresolvableSource(String)`), `func addSource(_ source: SourceDescriptor) throws`, `func removeSource(id: String)`, `var recordingSourceIDs: Set<String>` (computed from `chains`), and **tap disposal moves into `stemEnded`** (see below)

- [ ] **Step 1: Failing tests**

```swift
import Foundation
import Testing
@testable import Stems

@Suite("RecorderEngine mutation") struct RecorderEngineMutationTests {
    @Test func addSourceThrowsWhenIdle() {
        let engine = RecorderEngine()
        #expect(throws: EngineMutationError.self) {
            try engine.addSource(SourceDescriptor(id: "x", kind: .microphone, name: "X", bundleIdentifier: nil, deviceUID: "no-such-uid"))
        }
    }

    @Test func addSourceThrowsAndLeavesNoDebrisWhenUnresolvable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stems-m-\(UUID().uuidString)")
        let store = SessionStore(rootURL: root)
        let engine = RecorderEngine()
        // A fake app source resolves to no process objects → zero-stem session.
        let fakeApp = SourceDescriptor(id: "no.such.app", kind: .application, name: "Ghost", bundleIdentifier: "no.such.app", deviceUID: nil)
        try engine.startSession(sources: [fakeApp], format: .alac, store: store)
        defer { engine.stopSession() }
        #expect(engine.recordingSourceIDs.isEmpty)

        let ghostMic = SourceDescriptor(id: "no-such-uid", kind: .microphone, name: "Ghost Mic", bundleIdentifier: nil, deviceUID: "no-such-uid")
        #expect(throws: EngineMutationError.self) { try engine.addSource(ghostMic) }

        // No stem added, no files created, manifest unchanged.
        let sessions = store.listSessions()
        #expect(sessions.count == 1)
        #expect(sessions[0].manifest.stems.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: sessions[0].folderURL.path)
        #expect(files.filter { $0 != "manifest.json" }.isEmpty)
    }
}
```

- [ ] **Step 2: Run, verify failure** (`EngineMutationError` undefined).

- [ ] **Step 3: Implement in RecorderEngine.swift**

```swift
enum EngineMutationError: LocalizedError {
    case notRecording
    case unresolvableSource(String)

    var errorDescription: String? {
        switch self {
        case .notRecording: return "No recording session is running."
        case .unresolvableSource(let name):
            return "\(name) isn’t producing audio right now — start audio in it and try again."
        }
    }
}
```

Add to the class:

```swift
var recordingSourceIDs: Set<String> { Set(chains.map(\.source.id)) }

func addSource(_ source: SourceDescriptor) throws {
    guard case .recording = state, let store, let manifest, let folder = activeSessionFolder else {
        throw EngineMutationError.notRecording
    }
    guard let resolved = SourceResolver.resolve(source: source, registry: registry) else {
        throw EngineMutationError.unresolvableSource(source.name)
    }
    let fileName = Self.stemFileName(for: source, index: manifest.stems.count, format: manifest.stemFormat)
    let chain = try CaptureChain.make(deviceID: resolved.deviceID, scope: kAudioObjectPropertyScopeInput,
                                      stemURL: folder.appendingPathComponent(fileName), format: manifest.stemFormat)
    let sourceID = source.id
    chain.onLevel = { [weak self] level in self?.levels[sourceID] = level }
    chain.onEnded = { [weak self] reason in self?.stemEnded(sourceID: sourceID, reason: reason) }
    var updated = manifest
    updated.stems.append(StemRecord(source: source, fileName: fileName,
                                    sampleRate: chain.clientFormat.mSampleRate,
                                    channelCount: Int(chain.clientFormat.mChannelsPerFrame),
                                    startTime: Date(), endTime: nil, endEvent: nil))
    try store.save(updated, to: folder)
    self.manifest = updated
    chains.append((source, chain, resolved.tap))
    do { try chain.start() } catch {
        // Mirror startSession's failure cleanup for this one chain.
        chain.stop(reason: "startupFailed")
        resolved.tap?.dispose()
        chains.removeAll { $0.source.id == sourceID }
        throw error
    }
}

func removeSource(id: String) {
    guard let item = chains.first(where: { $0.source.id == id }) else { return }
    item.chain.stop(reason: "userRemoved")
}
```

**Tap disposal moves into `stemEnded`** (so mid-session removals free the tap): in `stemEnded(sourceID:reason:)`, after updating the manifest, add:

```swift
if let idx = chains.firstIndex(where: { $0.source.id == sourceID }) {
    chains[idx].tap?.dispose()
    chains.remove(at: idx)
    levels[sourceID] = nil
}
```

Then `stopSession()` drops its own `chains.forEach { $0.tap?.dispose() }` loop (chains are already removed as their `onEnded("sessionEnd")` callbacks land; chains that never deliver onEnded — none, by the exactly-once contract — are covered by `chains = []`). Verify the `registry` property is reachable from `addSource` (hoist `SourceRegistry()` to a stored `private let registry = SourceResolver... ` — reuse the existing instantiation; if `startSession` creates its own today, hoist it to a stored property in this task).

- [ ] **Step 4: Green, full suite (37 tests)**

- [ ] **Step 5: Commit** — `feat: live mid-session add/remove with engine mutation errors`

---

### Task 4: UI wiring — window gate, meter column, live toggles

**Files:**
- Modify: `Sources/Stems/UI/AppModel.swift`
- Modify: `Sources/Stems/UI/RecorderView.swift`
- Modify: `Sources/Stems/UI/LevelMeterView.swift`
- Modify: `Sources/Stems/App.swift` (window-visibility notifications)

**Interfaces:**
- Consumes: `MeterManager`, `meterTargets`, `RecorderEngine.addSource/removeSource/recordingSourceIDs`, `engine.levels`
- Produces: `AppModel.meters` (MeterManager), `AppModel.metersOn: Bool`, `AppModel.level(for:) -> Float`, `AppModel.reconcileMeters()`; visible meter column; live checkbox branch

- [ ] **Step 1: AppModel additions**

```swift
let meters = MeterManager()
@Published var metersOn = false   // window-visibility gate, driven by notifications

/// Display level for a row: recording chains win; otherwise meter taps.
func level(for id: String) -> Float {
    engine.levels[id] ?? meters.meterLevels[id] ?? 0
}

func reconcileMeters() {
    guard metersOn else { meters.stopAll(); return }
    let rows = (appSources + micSources)
    let sources = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    meters.reconcile(targets: meterTargets(rowIDs: rows.map(\.id),
                                           windowVisible: metersOn,
                                           recordingSourceIDs: engine.recordingSourceIDs),
                     sources: sources)
}
```

`toggleSource` branches: if `engine.state` is `.recording` → tick: `do { try engine.addSource(source); selectedSourceIDs.insert(id) } catch { lastError = error.localizedDescription }`; untick: `engine.removeSource(id: id); selectedSourceIDs.remove(id)`. Idle path unchanged. After any toggle/refresh/record-stop, call `reconcileMeters()`.

Mic permission before meters: in the notification handler that turns `metersOn` true, call `requestMicPermission { [weak self] granted in guard let self else { return }; self.metersOn = granted; if granted { self.reconcileMeters() } }` (denial keeps existing permission bar; meters stay off).

- [ ] **Step 2: Window-visibility gate (App.swift)**

In `AppDelegate`, after installing `HideOnCloseWindowDelegate`, observe (main queue):
`NSWindow.didBecomeKeyNotification`, `NSWindow.didResignKeyNotification`, `NSApplication.didChangeOcclusionStateNotification`. Handler sets `AppModel.shared.metersOn = <any NSApp window titled "Stems" is visible: NSApp.windows.contains { $0.title == "Stems" && $0.isVisible }>` then `AppModel.shared.reconcileMeters()`. Store the observer tokens; remove in `applicationWillTerminate`. (Hide-on-close keeps the window in `NSApp.windows` but `isVisible == false` while hidden — that's the signal.)

- [ ] **Step 3: RecorderView meter column**

Every row renders `LevelMeterView(level: model.level(for: source.id)).frame(width: 90)` in a trailing column — **unconditionally** (idle and recording; recording rows read engine levels through `level(for:)`). Remove the old `if isRecording` meter condition. Keep the estimate/timer behavior unchanged. Rows dim their meter (`opacity(0.25)`) when `model.metersOn == false`.

- [ ] **Step 4: LevelMeterView peak-hold**

Bump `frame(height: 4)` usage to 6 in RecorderView; add `@State private var peak: Float = 0` and decay it on the view's existing timer tick (peak = max(peak * 0.85, level)); render peak as a 2pt tick at `width * peak`. Pure view change.

- [ ] **Step 5: Verify**

`swift build && swift test` (37/37); `./scripts/build-app.sh` succeeds; `swift run Stems --list-taps` headless sanity. No audio playback. GUI behavior lands on the manual checklist (Task 5).

- [ ] **Step 6: Commit** — `feat: all-row VU meters with window gate and live mid-session toggles`

---

### Task 5: Docs, checklist, tag prep

**Files:**
- Modify: `docs/manual-test-checklist.md`
- Modify: `README.md`

- [ ] **Step 1: Checklist additions (17–21)**

```markdown
17. Idle meters: with the window open and nothing recording, play audio in a
    browser — its row's meter bounces; stop playback — it falls flat.
18. Window gate: close (hide) the window — no meter processes remain
    (`--list-taps` still fine, CPU drops); reopen — meters resume.
19. Mid-session add: start recording mic only; tick a playing browser — a new
    stem appears in the session folder; manifest shows its later startTime.
20. Mid-session remove: untick the browser mid-recording — its stem ends with
    endEvent "userRemoved"; mic keeps recording; combined export aligns both.
21. Meter permission: fresh install, first window open triggers the mic prompt
    once; deny → permission bar; grant via Settings + Retry → meters start.
```

- [ ] **Step 2: README** — Recorder window section gains: all-row live meters (window-gated), live checkboxes mid-session (`userAdded`/`userRemoved` events in manifest), `--meter` CLI example.

- [ ] **Step 3: Full verify + commit** — `swift build && swift test` (37/37), `./scripts/build-app.sh`; commit `docs: live meters and mid-session controls documentation`. NO tag (human tags after checklist).

---

## Plan Self-Review

- **Spec coverage:** all-row meters gated on visibility (T1–T2, T4), double-tap rule (`meterTargets` subtracts recording ids; reconcile runs on record start/stop via AppModel hooks — wire `reconcileMeters()` calls into `startRecording` success and the engine-state subscription from v0.1.0 so record transitions reconcile automatically — added to T4 Step 1 as an explicit instruction), live add/remove (T3), manifest events (T3 — free-form `endEvent`), permission prompt move (T4), refresh mid-session (already works; checklist 19), metered-app-quit edge (reconcile's absent-chain tolerance + checklist), auto-stop unchanged (T3 keeps `stemEnded` all-ended rule).
- **Placeholders:** none; T1 Step 3's IOProc carries an explicit "adapt signatures to current CaptureChain" note (codebase is the proven reference — that's interface consumption, not TBD).
- **Type consistency:** `MeterChain.make(deviceID:scope:tap:)` used by T2; `SourceResolver.resolve` used by T2/T3; `EngineMutationError` thrown in T3, surfaced via existing `lastError` in T4; `recordingSourceIDs` consumed by `meterTargets` in T4; test counts 32→35→37 tracked per task.
- **Known risk flagged in-plan:** T3's stemEnded tap-disposal restructure touches the v0.1.0 teardown path — implementer must verify `stopSession` still leaves no undisposed taps after the change (its chains array is now drained by stemEnded; `chains = []` remains the final safety).
