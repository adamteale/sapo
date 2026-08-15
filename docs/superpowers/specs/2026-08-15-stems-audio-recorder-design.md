# Stems — Design Document

**Date:** 2026-08-15
**Status:** Approved (brainstorming complete)
**Target:** macOS 14.4+ (Sonoma), native Swift

## Purpose

A simple native macOS app for recording audio from multiple system sources —
individual applications (Chrome, Zoom, Spotify…) and the microphone — as
independent, aligned stems within one session, then mixing/exporting after the
session. Primary use case: friends and colleagues recording online meetings for
later transcription.

Existing tools (Audio Hijack, BlackHole-based setups) have cumbersome interfaces
and/or require virtual audio devices that reroute sound. Stems records
non-destructively — audio keeps playing normally — and defers all mixing
decisions to after the session, so nothing is lost at record time.

## Core Principles

1. **Record everything selected, decide later.** Every selected source is
   captured as its own stem file. Track selection, mixing, and grouping happen
   post-session at export time.
2. **Non-destructive capture.** Core Audio process taps copy audio; the system
   output path is untouched. No virtual devices, no rerouting, no silence.
3. **Pluggable sources and export targets.** Source capture and session export
   are bounded modules. Future browser-extension tab sources and transcription
   exports slot in without rewrites.

## Platform & Stack

- **macOS 14.4+** — the public Core Audio Process Tap API requires it.
- **Native Swift** app: SwiftUI main window, AppKit menu bar component.
- No third-party audio dependencies; Core Audio + AVFoundation only.
- Working name "Stems" (bundle/product name changeable later).

## Architecture

Five modules with clear boundaries:

| Module | Responsibility | Talks to |
|---|---|---|
| `RecorderEngine` | Owns process taps and capture chains; start/stop session with a set of sources. Writes stems to disk. | Core Audio taps/IO (the *only* module that captures audio) |
| `SourceRegistry` | Enumerates candidate sources: running audio-producing apps (grouped by app, not PID) + input devices (mic). Tracks app launch/quit. | NSWorkspace, Core Audio device *enumeration* (no capture) |
| `SessionStore` | Session folder layout, manifest read/write, session listing. | File system |
| `ExportEngine` | Reads stems, resamples/mixes selected tracks, encodes combined / individual / grouped output as M4A or WAV. | AVFoundation |
| UI: `MenuBarController` + `MainWindow` | Menu bar quick controls; full recorder + sessions + settings views. | The three engines above |

A source is an **application**, not a process. Browsers render audio in helper
processes; the engine taps every audio process belonging to the app and folds
them into one stem. This is also the seam for future source types (e.g., a
browser-extension tab stream).

## Recording Model

- One trigger starts all capture chains for the selected sources → stems are
  timestamp-aligned.
- Each stem records at its source's native sample rate in its own file.
- **Stem format:** ALAC (lossless) by default in a `.caf` container
  (stream-friendly → crash-recoverable), or 16-bit WAV — selectable in the app's
  settings. Format is recorded in the manifest, so the export engine reads each
  stem correctly regardless of the setting used at record time.
- Approximate sizes/hour at 48 kHz: WAV ≈ 345 MB (mono) / 690 MB (stereo);
  ALAC ≈ 40–60% of WAV.

## Sessions & Data Layout

`~/Music/Stems/<timestamped-session-folder>/`

- `manifest.json` — title, source list (name, type, sample rate, format), start
  and stop timestamps, per-stem stop events.
- One stem file per source.

## Export Model

Post-session, in the Sessions view:

- Track list with per-track play preview and checkboxes.
- **Scope:** combined mix of ticked tracks / individual files / grouped — one file per source type ("all app audio" mix, microphone mix).
- **Format:** M4A (AAC, default) or WAV. (MP3 intentionally excluded — no
  native encoder.)
- Mixdown resamples stems to a common rate; encode last.
- After a successful combined export, optional **stem cleanup** prompt
  ("delete stems?"). Behavior configurable: ask / always / never.

## UI

**Menu bar (always available):**

- Idle: neutral icon. Menu: Record (reuses last session's sources), Open Stems,
  Quit. If no prior source selection exists, Record opens the main window.
- Recording: red icon; click shows live timer + Stop.

**Main window:**

- **Recorder view:** source list — running apps + microphone (with input-device
  picker) — with checkboxes; record button; elapsed timer; live per-source
  level meters while recording; estimated disk usage.
- **Sessions view:** list of sessions (date, duration, sources, disk size);
  session detail = track list + export controls (scope, format, destination).
- **Settings:** stem format (ALAC/WAV), stem cleanup behavior, launch at login,
  default microphone.

**Permissions:** the first recording triggers the standard microphone privacy
prompt (required for both taps and mic). If denied: short explainer + button to
open System Settings.

## Edge Cases & Known Limitations

- **App quits mid-session** → its stem ends; event noted in manifest; session
  continues.
- **New app launches mid-session** → not captured (v1 limitation).
- **Sources with different sample rates** → native-rate stems; resampled at
  export.
- **Crash mid-session** → ALAC-in-CAF stems remain readable/playable; partial
  session is listable and exportable.
- **Low disk space** → check at session start; warn with a size estimate.
- **Sleep** → no special handling in v1 (meeting apps typically prevent sleep).
- **Per-tab audio** → not possible via system APIs; deferred to a v2
  browser-extension source streaming into `RecorderEngine`.

## Distribution

- **Now:** ad-hoc signed local builds shared directly (right-click → Open on
  first run).
- **Later:** build script ready to add Developer ID signing + notarization and
  produce a DMG once an Apple Developer account exists. No architecture impact.

## Future (explicitly out of scope for v1)

- Per-tab capture via a companion browser extension (source-type seam exists).
- Transcription export targets (local Whisper, services such as Fluid Voice, or
  our own tooling) — designed as just another export target.

## Testing Strategy

- **Unit tests:** `SessionStore` (manifest round-trip, partial-session
  recovery), `ExportEngine` (mixdown correctness with generated PCM fixtures,
  resampling, format conversion), source-grouping logic.
- **Manual checklist** for `RecorderEngine` (Core Audio can't be sanely
  unit-tested): record Chrome+Zoom+mic simultaneously; app quit mid-session;
  crash recovery; denied-mic path; format toggle between sessions.
- Verification on a real machine is required — Core Audio tap behavior cannot
  be faked in CI.
