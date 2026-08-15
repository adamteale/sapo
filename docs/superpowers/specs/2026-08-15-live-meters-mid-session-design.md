# Stems — Live Meters & Mid-Session Controls Design

**Date:** 2026-08-15
**Status:** Approved in conversation; spec for review
**Base:** v0.1.0 (`main` @ 9b448e4)

## Purpose

Two UX upgrades for the Recorder window, both flowing from real usage:

1. **Always-on VU meters** — every row in the source list shows a live
   horizontal level bar whenever the Recorder window is visible, so the user
   can see *which* apps are actually making sound before (and while) recording.
   Meters are decoupled from checkboxes: a meter answers "is audio flowing?",
   a checkbox answers "record this?".
2. **Live mid-session controls** — checkboxes become live during recording.
   Ticking a source adds it to the running session; unticking ends that
   source's stem (e.g., the meeting ends but you keep talking on the mic).
   The session manifest already records per-stem start/stop timestamps and
   the mixer already offsets-aligns stems — this feature activates that
   existing capability from the UI.

## Design

### 1. All-row VU meters

- **Gate: window visibility.** Meters for all listed rows run only while the
  Recorder window is open and visible; they tear down when it closes. This
  bounds cost: a menu-bar app idles with zero live taps.
  *Implementation note:* the main window hides on close (`orderOut`, not
  destroy — v0.1.0 reopenability fix), so SwiftUI `onDisappear` is not a
  reliable signal; gate on NSWindow notifications (`didBecomeKey`/
  `didResignKey`/occlusion) instead.
- **Meter-only capture:** a lightweight `MeterChain` (Core Audio IOProc that
  computes RMS and nothing else — no `StemWriter`, no file) attached to a
  `ProcessTapSession` (apps) or input device (mics). Reuses the existing tap
  machinery; mute behavior stays `.unmuted` (non-destructive).
- **Level plumbing:** `MeterManager` publishes `@Published meterLevels:
  [String: Float]` on the main thread (10 Hz throttle, same as recording
  meters). A row's displayed level is `engine.levels[id]` while recording
  that source, else `meterLevels[id]`.
- **Double-tap avoidance:** a source must never have a meter tap and a
  recording tap simultaneously. Coordination rule (owned by `AppModel`):
  meter targets = all listed rows MINUS sources the engine is currently
  recording. Re-evaluated on: window visibility change, record start/stop,
  selection change, stem add/remove mid-session, refresh.
- **`LevelMeterView` upgrade:** taller capsule, optional peak-hold tick —
  visible bounce at a glance. Shown in a new "meter" column on every row,
  dimmed (flat) when the window-gate is off.
- **Permission:** enabling meters can trigger the microphone TCC prompt once
  (first time any tap is created). `AppModel` requests mic permission before
  starting meters; denial shows the existing permission bar and meters stay
  off (recording flow unchanged).

### 2. Live mid-session add/remove

- **Engine API** (RecorderEngine):
  - `addSource(_ source: SourceDescriptor) throws` — resolves process
    objects / device, creates tap + chain, appends a `StemRecord`
    (`startTime = now`, `endEvent = nil`), saves manifest, starts chain.
    Throws with a friendly `LocalizedError` message if the source cannot be
    resolved (e.g., app not currently producing audio).
  - `removeSource(id: String)` — stops that chain with reason
    `"userRemoved"`; the existing `stemEnded` path updates the manifest.
    After the stem ends, the engine disposes its tap and drops the chain
    (mid-session resource hygiene; today taps are only disposed at
    `stopSession`).
- **UI:** `AppModel.toggleSource` branches — at idle it only toggles the
  selection set (unchanged); while recording it calls `addSource`/
  `removeSource` and updates the selection to match. Failures surface via
  the existing `lastError` path (inline red text + menu-bar alert).
- **Manifest events:** no model change — `StemRecord.endEvent` is already a
  free-form string. New vocabulary: `"userAdded"` is implied by a stem whose
  `startTime` post-dates the session start; `"userRemoved"` is the endEvent
  for user-initiated ends. `manifest.json` continues to be the authoritative
  "JSON of all tracks, their files, and when they were added/ended."
- **Refresh mid-session:** re-enumerates the source list; newly launched
  apps appear (unticked) and can be ticked to join live.
- **Auto-stop semantics unchanged:** if the user removes every source
  mid-session, the session ends (existing all-stems-ended rule).

## Edge cases

- **Metered app quits** → NSWorkspace termination notice drops its meter tap;
  the row goes flat and disappears on next Refresh.
- **Source skipped at record start** (not playing audio) can still be added
  later by ticking it once it plays — `addSource` re-resolves process
  objects at call time.
- **Menu-bar Record with window closed** → meters off (gate), recording
  chains unaffected — meters are purely additive.
- **Recording chain provides levels** for recorded sources; MeterManager
  never taps them (double-tap rule above).
- **Meter tap on silent app** → flat bar; correct signal ("no audio
  flowing"), indistinguishable from off — acceptable.

## Testing

- **Unit:** meter-target coordination as a pure function
  (`meterTargets(rows:visible:isRecording:recordingSourceIDs:)`); manifest
  round-trip with mid-session `userRemoved` stems; engine `addSource`
  failure path (unresolvable source throws, nothing created — no folder or
  manifest debris).
- **Manual checklist additions** (live audio): all-row meters bounce at
  idle; meters stop when window closes; tick-during-recording adds a stem
  (`userAdded` timing visible in manifest); untick ends it
  (`userRemoved`); refresh mid-session reveals a newly launched app.

## Out of scope

- Per-tab sources (browser extension) — future source type, unchanged seam.
- Metering when the window is closed (tray-icon mini-meter etc.).
- Any export/mixer changes — offsets already handle late-joining stems.
