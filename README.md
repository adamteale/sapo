# Sapo

> Record every app on your Mac as separate, aligned tracks — mix and export after.

![macOS 14.4+](https://img.shields.io/badge/macOS-14.4%2B-000000?logo=apple&logoColor=white)
![Swift 5](https://img.shields.io/badge/Swift-5-F05138?logo=swift)
![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)

Sapo is a native macOS audio recorder that captures audio from every running application and your microphone as **independent, time-aligned stems**. You record the whole session, then decide which sources to keep, export as a combined mix, grouped stems, or individual tracks — in M4A or WAV.

## Why Sapo

Meeting recordings should capture everything, not just what you remembered to unmute. Virtual audio routers (BlackHole, Loopback) reroute audio and mute your original output — Sapo uses macOS's native process-tap API to **listen without interfering**. Your apps keep playing normally; Sapo records in the background.

## Features

- **Per-application capture** — Chrome, Zoom, Slack, Spotify… one click each
- **Microphone capture** — built-in or external mic
- **Live VU meters** on every source — see what's making sound before you record
- **Record everything, decide later** — stems are saved independently and time-aligned
- **Export after the fact** — combined mix, grouped (apps vs mic), or individual tracks
- **Non-destructive** — audio keeps playing normally; no virtual devices, no silence
- **Works mid-session** — join or leave sources while recording
- **Menu-bar control** — quick Record/Stop with elapsed time, even from any app
- **Window-gated meters** — VU meters only run while the window is visible (battery-friendly)

## Requirements

- macOS 14.4 (Sonoma) or later
- Microphone access (granted on first launch)

## Install

Download the latest `.dmg` from [Releases](../../releases).

**First launch:** right-click the app → **Open** → click **Open** in the dialog (this is macOS Gatekeeper protecting you from unsigned apps — it only happens once). Then approve the microphone permission when prompted.

## Building from source

```bash
git clone https://github.com/<you>/sapo.git
cd sapo
swift build -c release
./scripts/build-app.sh
```

### Running dev builds

On some macOS configurations (particularly MDM-managed Macs), apps launched normally through Finder or the Dock may receive silent process taps — microphone capture works, but per-application taps deliver silence. The same binary launched as a Terminal child receives tap audio normally.

The launcher script starts Sapo in the working context:

```bash
open scripts/run-sapo.command
```

This opens a Terminal window, launches Sapo, and detaches — you can close the Terminal window once Sapo is running.

## How it works

Sapo uses macOS's native Core Audio process-tap API (available since macOS 14.4) to create private aggregate devices for each source. Audio flows through these taps into per-source ALAC or WAV files, all time-aligned to the session start. A `manifest.json` tracks which sources were active, their format, and any mid-session joins/leaves.

Export happens post-session: Sapo reads the manifest and the individual stem files, then mixes them into the format you choose (combined, grouped by source type, or individual) using only native AVFoundation codecs.

## Limitations

- **Safari audio** is shared via WebKit's GPU process — Sapo labels it clearly in the UI so you know what you're capturing
- **No transcription** — Sapo produces audio files; transcription is left to dedicated tools (export stems and feed them to Whisper, otter.ai, etc.)

## Tab Capture (PoC)

Sapo can capture audio from a single browser tab (Chrome or Brave) via a browser extension and native messaging host. Per-app capture works in any browser; tab capture adds per-tab precision.

### Setup

1. Build the native messaging host:
   ```bash
   swift build -c release --product SapoTabHost
   ```

2. Register the native host:
   ```bash
   ./scripts/register-native-host.sh
   ```

3. Load the browser extension:
   - Open your browser's extensions page (Brave: `brave://extensions`, Chrome: `chrome://extensions`)
   - Enable **Developer mode** (top right toggle)
   - Click **Load unpacked** and select the `chrome-extension/` directory
   - The extension ID is deterministic (`nhglbplanbiljndnbkaadecapgbbcdcb` — pinned via a `key` in the extension manifest), so no manual ID configuration is needed

4. Start recording:
   - Open Sapo
   - Go to the Recorder tab
   - Enable tab capture in Settings if it's off
   - Click **Start Capture** on the tab you want in the extension popup
   - Start recording in Sapo — the tab audio arrives as a stem

### Architecture

```
Chrome Extension → Native Messaging → Swift Host → TCP → Sapo
```

- **Browser extension**: Captures per-tab audio via `chrome.tabCapture`, processes via `AudioContext` → `AudioWorklet`, sends via native messaging; pushes live tab lists (title + audible state) so Sapo can show every tab as a source
- **Swift native host** (`SapoTabHost`): Reads JSON from stdin, forwards tab audio over TCP 5678 and tab lists over TCP 5679
- **Sapo**: `TabCaptureRouter` demultiplexes the audio stream by tab ID into one stem per selected tab — record multiple tabs at once

### Limitations

- DRM-protected sites (Widevine) produce silent audio
- Browser extension must be loaded in Developer mode (not from a Web Store)
- Tab rows refresh on browser events + a 1-minute heartbeat (MV3 service workers sleep); a quiet browser may lag a minute behind
- PoC only — no Firefox support, no auto-start

## Roadmap

- [ ] Per-app volume sliders during recording
- [ ] Transcription export (Whisper, AssemblyAI)
- [ ] Notarized distribution (Developer ID)
- [ ] Firefox tab capture support
- [ ] Multi-tab capture

## License

MIT — see [LICENSE](LICENSE). Sapo is free for personal and commercial use.

## Privacy

**Audio never leaves your Mac.** Sapo has no network access, no analytics, no telemetry. Everything is stored locally in `~/Music/Sapo/`.
