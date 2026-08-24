# Sapo Improvement Plan

## Overview
Major improvement pass: fix correctness bugs, add quick features, build medium features, and architect tab capture. Organized in phases so each is independently completable and testable.

---

## Phase 1: Bugs & Correctness (Critical)

### 1.1 Fix `ProcessTap.dispose()` destruction order
**Problem:** `dispose()` destroys the aggregate device first, then the process tap. If the CaptureChain's IOProc is still using the aggregate, this can cause a crash or hang.

**Fix:** Reverse the destruction order — destroy the tap first, then the aggregate.

```swift
// Current (WRONG):
AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
AudioHardwareDestroyProcessTap(tapID)

// Fixed:
AudioHardwareDestroyProcessTap(tapID)
AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
```

**Files:** `Sources/Sapo/Core/ProcessTap.swift`
**Tests:** Add a smoke test that creates and disposes a tap in a loop to verify no hangs.

---

### 1.2 Surface unresolvable sources to user
**Problem:** In `RecorderEngine.startSession`, `SourceResolver.resolve()` silently drops sources that can't be resolved (apps not playing audio). User clicks Record and nothing happens — no error, no indication of what went wrong.

**Fix:** Track which sources failed to resolve. After the resolution loop, if any sources were silently dropped, throw an error that AppModel surfaces as `lastError`.

```swift
// In RecorderEngine.startSession, after the resolution loop:
var unresolved: [String] = []
for (index, source) in sources.enumerated() {
    guard let resolved = SourceResolver.resolve(source: source, registry: registry) else {
        unresolved.append(source.name)
        continue
    }
    // ... existing resolution code ...
}

if !unresolved.isEmpty {
    throw SessionStartError.unresolvedSources(unresolved)
}
```

Add `SessionStartError.unresolvedSources([String])` case. AppModel catches it and sets `lastError`.

**Files:** `Sources/Sapo/Core/RecorderEngine.swift`, `Sources/Sapo/Core/Models.swift`, `Sources/Sapo/UI/AppModel.swift`
**Tests:** Add test in `AppModelTests.swift` that verifies error is set when sources are unresolvable.

---

### 1.3 Fix `observeAppTermination` race
**Problem:** The workspace observer is set up *after* all chains start. If a tapped app terminates between the last `chain.start()` and observer setup, that app's termination won't be caught — the tap stays active.

**Fix:** Set up the observer *before* starting chains.

```swift
// Current order (WRONG):
try item.chain.start()  // chains start first
observeAppTermination() // observer set up after

// Fixed order:
observeAppTermination() // observer set up first
try item.chain.start()  // then chains start
```

**Files:** `Sources/Sapo/Core/RecorderEngine.swift`
**Tests:** Hard to test without simulating app termination, but the fix is straightforward and the existing manual tests cover this path.

---

## Phase 2: Quick Improvements (1–2 hours each)

### 2.1 "End Recording" button — save early
**Problem:** Users must wait for the entire session to end. No way to stop recording and save the session early.

**Fix:** Add an "End Recording" button to the RecorderView when recording. Calls `engine.stopSession()` and `AppModel.stopRecording()`. Shows a confirmation dialog.

**UI changes:**
- Replace "Record" button with "Stop" button when recording
- Add a confirmation dialog: "End this recording? All selected stems will be saved."
- After stop, show the session in the Sessions tab

**Files:** `Sources/Sapo/UI/RecorderView.swift`, `Sources/Sapo/UI/AppModel.swift`
**Tests:** Add `AppModelTests` for `stopRecording` flow (already partially covered).

---

### 2.2 Export progress indicator
**Problem:** Long recordings take time to mix. UI just spins with no feedback.

**Fix:** Add a progress view during export. Mixer already processes stems sequentially — expose progress through a callback or `@Published` on ExportEngine.

**Design:**
- ExportEngine adds `@Published var progress: Float = 0`
- ExportEngine publishes progress after each stem is mixed
- Export dialog shows progress bar with "Cancel" button
- Add `ExportError.cancelled` case

**Files:** `Sources/Sapo/Export/ExportEngine.swift`, `Sources/Sapo/UI/SessionDetailView.swift`
**Tests:** Add progress test in `ExportEngineTests.swift`.

---

### 2.3 Per-source mute during recording
**Problem:** No way to mute an accidentally selected source during recording.

**Fix:** Add a mute toggle per source in the meter row. Muted sources have their chain's IOProc output set to zero (or remove the chain and recreate on unmute).

**Design:**
- Add `@Published var mutedSourceIDs: Set<String> = []` to AppModel
- Toggle button in meter row (speaker icon crosses out)
- Muting during recording: remove chain, add back on unmute
- Muting while idle: just deselect the source

**Files:** `Sources/Sapo/UI/AppModel.swift`, `Sources/Sapo/UI/RecorderView.swift`, `Sources/Sapo/UI/LevelMeterView.swift`
**Tests:** Add selection/mute toggle tests to `AppModelTests.swift`.

---

## Phase 3: Medium Features (half-day each)

### 3.1 Session retention / cleanup
**Problem:** Sessions accumulate with no automatic cleanup. `SettingsStore` has `stemCleanup` (ask/always/never) but only on export.

**Fix:** Add a retention policy setting. On app launch, check for sessions older than `N` days and prompt to delete (or auto-delete based on setting).

**Design:**
- Add `maxSessionAge: Int?` to SettingsStore (nil = no limit)
- On `AppModel.init`, scan for old sessions and offer cleanup
- Add a "Cleanup Sessions" button in Settings view
- Show session age in Sessions view

**Files:** `Sources/Sapo/UI/SettingsStore.swift`, `Sources/Sapo/UI/AppModel.swift`, `Sources/Sapo/UI/SettingsView.swift`, `Sources/Sapo/UI/SessionsView.swift`
**Tests:** Add `SessionStoreTests` for old session detection.

---

### 3.2 Portion export (trim)
**Problem:** Can only export entire sessions. Want to pull out a specific segment.

**Fix:** Add a time-range selector in the export dialog. Mixer reads stems with start/end offsets.

**Design:**
- Export dialog adds time range inputs (start/end or "from X to Y")
- Mixer adds `offset` and `duration` parameters to `mix()`
- StemReader already supports seeking — use it to skip to offset

**Files:** `Sources/Sapo/Export/Mixer.swift`, `Sources/Sapo/Export/StemReader.swift`, `Sources/Sapo/UI/SessionDetailView.swift`
**Tests:** Add portion export test in `ExportEngineTests.swift`.

---

### 3.3 Keyboard shortcuts
**Problem:** No keyboard shortcuts for power users.

**Fix:** Add common shortcuts:
- ⌘R: Toggle record/stop
- ⌘+M: Toggle microphone
- ⌘+1/2/3: Toggle first three sources
- ⌘+E: Export current session

**Design:**
- Add `KeyboardShortcuts` helper that registers shortcuts via AppKit
- Map shortcuts to AppModel actions
- Show shortcuts in UI labels (e.g., "Record ⌘R")

**Files:** `Sources/Sapo/UI/AppModel.swift`, `Sources/Sapo/UI/RecorderView.swift`, `Sources/Sapo/App.swift`
**Tests:** Add `AppModelTests` for shortcut-triggered actions.

---

## Phase 4: Tab Capture Architecture (Weeks)

### 4.1 Chrome Extension PoC (weekend validation)
**Goal:** Prove the approach works. Single Chrome extension + native messaging bridge.

**Components:**
1. `chrome-extension/` — Chrome extension that:
   - Uses `chrome.tabCapture` API to capture a tab's audio
   - Exposes captured audio via Native Messaging host
   - Lists available tabs for capture

2. `SapoNativeHost/` — Swift native messaging host:
   - Listens for tab capture requests from extension
   - Receives audio stream data
   - Sends it to Sapo via a local TCP socket

3. `TabCaptureSession` — New source type in Sapo:
   - Connects to local TCP socket
   - Receives tab audio as a Core Audio input stream
   - Integrates with existing CaptureChain pipeline

**Validation:** If this works, we know the architecture is sound. Then invest in full extension + Firefox.

---

### 4.2 Full Tab Capture (if PoC succeeds)
**Scope:**
- Chrome extension (all tabs, multi-tab capture)
- Firefox extension (MediaSourceRecorder API)
- Native messaging bridge (cross-browser)
- Sapo integration (new source type, UI for tab selection)
- Settings UI for tab capture configuration

**Estimated effort:** 1–2 months

---

## Execution Order

1. **Phase 1 bugs** — critical, no risk, immediate value
2. **Phase 2 quick fixes** — each is independent, testable, high user value
3. **Phase 3 medium features** — build on top of Phase 2
4. **Phase 4 tab capture** — validate PoC first, then commit

## Testing Strategy

- **Unit tests** for all logic (AppModel, ExportEngine, Mixer, StemWriter, SessionStore)
- **Smoke tests** for UI flows (manual via launcher)
- **Integration tests** for recording lifecycle (existing RecorderEngineMutationTests)
- **Tab capture PoC** validated by end-to-end test (capture tab audio, export, verify)

## Risk Assessment

| Item | Risk | Mitigation |
|---|---|---|
| Bug fixes | Low | Straightforward, existing tests cover |
| Quick fixes | Low-Medium | Each is isolated, testable |
| Medium features | Medium | UI changes need manual testing |
| Tab capture | High | PoC validates before full build |
