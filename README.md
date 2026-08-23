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
- **Per-tab capture** would require browser extensions — a future feature
- **No transcription** — Sapo produces audio files; transcription is left to dedicated tools (export stems and feed them to Whisper, otter.ai, etc.)

## Roadmap

- [ ] Per-app volume sliders during recording
- [ ] Transcription export (Whisper, AssemblyAI)
- [ ] Tab-level capture via browser extensions
- [ ] Notarized distribution (Developer ID)

## License

MIT — see [LICENSE](LICENSE). Sapo is free for personal and commercial use.

## Privacy

**Audio never leaves your Mac.** Sapo has no network access, no analytics, no telemetry. Everything is stored locally in `~/Music/Sapo/`.
