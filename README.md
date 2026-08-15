# Stems

A simple native macOS app for recording audio from multiple system sources —
individual applications (Chrome, Zoom, Spotify…) and the microphone — as
independent, aligned stems within one session, then mixing and exporting after
the session. Primary use case: recording online meetings for later
transcription.

Stems records **non-destructively**: Core Audio process taps copy audio while it
keeps playing normally. No virtual audio devices, no rerouting, no silence.

## Requirements

- macOS 14.4+ (Sonoma) — the public Core Audio Process Tap API requires it.
- Xcode command-line tools (`xcode-select --install`) for building from source.

## Build

```bash
# Plain build (debug)
swift build

# Ad-hoc signed .app bundle in build/
./scripts/build-app.sh

# App bundle + distributable DMG in build/
DMG=1 ./scripts/build-app.sh
```

## First run

1. Launch `Stems.app` (or run `swift run`).
2. **Ad-hoc builds are not notarized**: on first launch macOS will block the
   app — right-click the app in Finder and choose **Open**, then **Open** again
   in the confirmation dialog.
3. Approve the microphone permission prompt the first time you record. If you
   deny it, use the banner in the app to jump to System Settings → Privacy &
   Security → Microphone and enable Stems, then hit **Retry**.
4. Start playing audio in an app you want to record (a browser, a call, music),
   then press **Refresh** so its name appears under *Applications*.

## Usage

- **Menu bar icon** — quick access: start/stop recording (a red icon shows
  while recording) and open the window. If no sources are selected, Record
  opens the main window so you can pick them.
- **Main window (Recorder)** — select any combination of apps and the
  microphone, then press **Record**. Live level meters move while recording;
  the timer counts up. **Stop** ends the session.
- **Sessions** — every recording is saved as its own session folder under
  `~/Music/Stems`:

  ```
  ~/Music/Stems/
  └── Session 2026-08-15 16.30.00/
      ├── manifest.json        # session metadata (crash-safe: written at start)
      ├── stem-0-Google Chrome.caf   # per-source ALAC stem
      └── stem-1-MacBook Pro Mic.caf
  ```

  Stems are written as ALAC (`.caf`) by default; switch to WAV (`.wav`) in
  Settings. Sessions survive app crashes and app quits mid-recording.

- **Export** — open a session, preview any stem, and export:
  - *Combined* — every stem mixed into one file (M4A or WAV).
  - *Grouped* — one file for Applications, one for Microphone.
  - *Individual* — one file per source.
  Export runs after the session, so you can pick tracks and levels without
  losing anything at record time.

- **CLI** — headless capture for scripting:

  ```bash
  # List what is capturable right now (apps must be playing audio)
  ./Stems --list-taps

  # Record 5 seconds from one app into /tmp
  ./Stems --record-app com.google.Chrome --seconds 5 --out /tmp

  # Record 10 seconds from the default microphone
  ./Stems --record-mic --seconds 10 --out /tmp
  ```

## Troubleshooting

- **No sources listed** — apps appear under *Applications* only while they are
  actually producing audio. Start playback first, then press **Refresh*.
- **A selected app records nothing** — if the app stops making sound mid-session
  its stem ends (marked `processExited` in the manifest) while the rest of the
  session continues.
- **Low disk space** — Stems estimates the session's size (up to 2 hours per
  source) before starting and refuses to record if the volume can't hold it;
  the reason is shown in red under the controls.
- **Microphone missing** — check System Settings → Privacy & Security →
  Microphone, and that the input device is present in Audio MIDI Setup.

## Roadmap

Design doc (spec, roadmap, module boundaries):
[`docs/superpowers/specs/2026-08-15-stems-audio-recorder-design.md`](docs/superpowers/specs/2026-08-15-stems-audio-recorder-design.md)

Planned follow-ups include browser-extension tab sources and transcription
export.
