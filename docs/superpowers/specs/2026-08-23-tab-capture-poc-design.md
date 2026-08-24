# Chrome Extension Tab Capture PoC — Design Spec

## Goal

Validate that Chrome tab audio can be captured and recorded as a stem in Sapo — proving the architecture before committing to a full extension + Firefox build.

## Chrome Extension Architecture

Chrome 116+ requires an **offscreen document** for tab audio capture. Service workers cannot use `AudioContext` or `getUserMedia` directly. The architecture:

```
Extension popup (MV3) → chrome.tabCapture.getMediaStreamId()
                       → offscreen document → AudioContext → AudioWorklet
                       → main thread → chrome.runtime.connectNative()
                       → native messaging host (Swift)
                       → TCP → Sapo
```

**Offscreen document** — required because:
- Service workers have no DOM / no `AudioContext`
- `chrome.tabCapture.getMediaStreamId()` returns an ID (not a stream), usable only in an offscreen document via `getUserMedia()`
- AudioWorklet runs on a dedicated audio rendering thread (vs. deprecated `ScriptProcessorNode` on main thread)

**AudioWorklet** — chosen over deprecated `ScriptProcessorNode`:
- Runs on dedicated audio thread, no main-thread throttling
- VS Code's `pcmCaptureWorklet` pattern: batch mono frames to 4096 samples, transfer via `port.postMessage()` with transferable `ArrayBuffer`
- Worklet module loaded from blob URL (CSP-safe)

**Native messaging host** — separate Swift executable:
- Chrome spawns it via `connectNative()`, keeps it running until the port is destroyed
- Reads length-prefixed JSON from stdin, writes responses to stdout
- Relays audio to Sapo via TCP `localhost:5678`
- Built as a separate SwiftPM target (`SapoTabHost`)

## Architecture

```
Chrome Extension → Native Messaging → Swift Host → TCP → Sapo
```

Three independent pieces:

1. **Chrome extension** — captures tab audio via `chrome.tabCapture` API, reads PCM from `AudioContext`, sends data to native host
2. **Swift native messaging host** — reads JSON messages from Chrome's stdin, forwards raw Float32 PCM over TCP to Sapo
3. **Sapo `TabCaptureSession`** — listens on TCP, receives PCM, writes stem files via `StemWriter`

The Sapo side integrates with the existing `RecorderEngine` as a new `SourceKind.tabCapture`. No changes to Mixer or ExportEngine — tab stems are just files in the session folder.

## Audio Format

- **32-bit float PCM, 48kHz, mono**
- Matches Sapo's internal format; Chrome delivers Float32 natively from `getUserMedia()`
- Mono is correct — tab audio is already a mixed stereo bus
- AudioWorklet batches 4096 mono samples per chunk
- Chrome almost always delivers 48kHz natively; Sapo's Mixer resamples if different

## Data Flow

### Chrome Extension
1. User selects a tab in the popup UI
2. `chrome.tabCapture.capture()` gets a `MediaStream`
3. `AudioContext.createMediaStreamSource(stream)` → `ScriptProcessorNode(bufferSize=4096)`
4. On `onaudioprocess`: read Float32 samples, encode as base64
5. Send JSON to native host: `{"type":"audio","tabId":"123","data":"base64..."}`
6. If no tab audio (silence), send: `{"type":"silence","tabId":"123"}`

### Swift Native Messaging Host
1. Reads JSON from stdin (Native Messaging protocol)
2. Decodes base64, sends raw Float32 PCM over TCP to `localhost:5678`
3. Messages: `{"tabId":"123","sampleRate":48000,"frameCount":4096}` + raw bytes

### Sapo TabCaptureSession
1. Listens on TCP port 5678 (configurable)
2. Receives header + PCM stream
3. Writes to stem file via `StemWriter` (same as `CaptureChain`)
4. Exposes audio level to `RecorderEngine` via callback
5. Handles disconnect → marks stem as ended with reason `"tabDisconnected"`

## Source Kind

Add `case tabCapture` to `SourceKind` in `Models.swift`.

`SourceDescriptor` for tab sources:
- `id`: `tab-<chromeProcessID>-<tabID>` — unique per tab
- `kind`: `.tabCapture`
- `name`: tab title (from `chrome.tabs.get()`)
- `bundleIdentifier`: `"com.google.Chrome"`
- `deviceUID`: `nil`

Tab sources appear alongside app and mic sources. They are resolved to the Chrome process object ID so Sapo can detect when Chrome terminates.

## Integration with RecorderEngine

No changes to the recording pipeline core. `RecorderEngine.startSession()` already iterates sources and builds chains. For `.tabCapture` sources:

```swift
case .tabCapture:
    let session = try TabCaptureSession.make(stemURL: stemURL, format: format)
    chain = session.captureChain   // CaptureChain wrapping the stem writer
    tap = nil                      // no Core Audio tap (tab has no Core Audio process)
```

`TabCaptureSession` holds a `CaptureChain` internally and connects the TCP stream to it.

## File Structure

```
chrome-extension/
  manifest.json        # manifest v3, permissions: tabCapture, tabs, offscreen, storage
  background.js        # service worker: orchestrates popup ↔ offscreen ↔ native host
  popup.html           # UI: tab list, select, start/stop
  popup.js             # popup UI logic
  offscreen.html       # required host for getUserMedia in MV3
  offscreen.js         # tab audio capture: getUserMedia → AudioContext → AudioWorklet → port
  pcm-capture.worklet.js  # AudioWorklet processor: batches 4096 mono Float32 frames

Sources/Sapo/
  Core/TabCaptureSession.swift   # TCP server + stem writer
  Core/Models.swift              # SourceKind.tabCapture
  UI/RecorderView.swift          # tab source row
  UI/SettingsView.swift          # port config + enable toggle
```

**No separate `SapoNativeHost` directory** — the native messaging host is a SwiftPM executable target within the Sapo project, built alongside the app. This keeps the host and Sapo in sync (same version, same repo).

## Protocol Details

### Native Messaging (Chrome → Swift Host)
- Standard Chrome Native Messaging protocol: **4-byte native-endian** (little-endian on macOS) JSON message length, then UTF-8 JSON body
- Chrome keeps the host process alive while `connectNative()` port is open
- The first argument to the host process is the calling extension's origin
- Message format:
  ```json
  {"type":"audio","tabId":"123","data":"base64..."}
  {"type":"silence","tabId":"123"}
  {"type":"error","tabId":"123","message":"..."}
  ```
- `audio`: 4096 Float32 samples (16384 bytes raw → ~22KB base64)
- `silence`: sent when no audio is detected (saves CPU)
- Max message size: 1 MB from native host, 4 GB from Chrome

### TCP (Swift Host → Sapo)
- Connection string: `localhost:5678` (configurable)
- Each message: JSON header + raw bytes
  ```json
  {"tabId":"123","sampleRate":48000,"frameCount":4096}
  ```
  followed by `frameCount × 4` bytes of Float32 PCM (little-endian)

### Native Messaging Host Registration (macOS)
- Host manifest placed at: `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.sapomac.sapo-tab-capture.json`
- Host name: `com.sapomac.sapo-tab-capture` (lowercase alphanumeric, underscores, dots)
- Manifest includes the extension ID in `allowed_origins` (known at build time from the extension manifest)

## Error Handling

- **Chrome terminates**: `onended` on MediaStream → send disconnect → Sapo ends stem with `"tabDisconnected"`
- **TCP disconnect**: Swift host closes connection → Sapo ends stem with `"tcpDisconnected"`
- **Missing tab capture permission**: Extension popup shows error, source unavailable
- **Sapo not running**: Swift host retries TCP connection (exponential backoff, max 5s)

## UI Changes

### RecorderView
- New row type for tab sources: speaker icon + tab title + badge "Tab"
- Same mute/selection controls as app sources
- Tab sources show a small indicator that audio comes from Chrome

### SettingsView
- "Tab Capture" section:
  - Toggle: Enable tab capture
  - TCP port: default 5678 (configurable)
  - Status indicator: "Native host registered" / "Not registered"
  - Note: "Install the Chrome extension from chrome://extensions → Developer mode → Load unpacked"

### Popup UI (Chrome extension)
- Lists available tabs with titles (via `chrome.tabs.query`)
- "Start capture" / "Stop capture" buttons
- Shows which tabs are currently captured (via `chrome.tabCapture.getCapturedTabs()`)
- Status: "Connecting..." / "Recording" / "Disconnected"

## Testing

### Manual Validation (PoC goal)
1. Install Chrome extension from `chrome-extension/` (Developer mode → Load unpacked)
2. Register native messaging host: `SapoTabHost` writes its manifest to Chrome's `NativeMessagingHosts` directory
3. Launch Sapo via `run-sapo.command`, open Settings, enable tab capture
4. Play audio in a Chrome tab (e.g., YouTube, Spotify web)
5. Click extension icon → select tab → "Start capture"
6. Select the tab source in Sapo and start recording
7. Verify stem file exists and plays back correctly
8. Stop recording, export, verify tab audio is in the exported file

### Automated Tests
- `TabCaptureSessionTests` — TCP server starts, receives data, writes file
- No unit tests for Chrome extension (browser automation out of scope for PoC)

## Success Criteria

1. ✅ Chrome extension captures tab audio → native messaging works
2. ✅ Swift host relays PCM over TCP → Sapo receives data
3. ✅ Tab audio writes to valid stem file (CAF/WAV)
4. ✅ Can record a session with a tab source → full pipeline works
5. ✅ Exported session contains tab audio mixed correctly

## Out of Scope for PoC

- Firefox extension (separate project)
- Multi-tab capture (single tab only)
- Video-only tabs (no audio → skip)
- Full extension store submission
- Auto-start on Chrome launch (manual load unpacked)
- Tab selection UI inside Sapo (popup UI is external)
- Per-source gain/volume controls
- DRM-protected sites (fundamental Chrome limitation — Widevine encrypts audio)

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Chrome tabCapture permissions | Low | Manifest v3 standard API, well-documented |
| AudioContext latency/jitter | Low | 4096 buffer size is standard, Chrome handles scheduling |
| TCP connection drops | Medium | Swift host retries, Sapo handles disconnect gracefully |
| Native Messaging stdio blocking | Low | Swift host reads async, non-blocking |
| Chrome terminates during recording | Medium | `onended` handler → clean stem end |
