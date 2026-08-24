# Chrome Extension Tab Capture PoC — Design Spec

## Goal

Validate that Chrome tab audio can be captured and recorded as a stem in Sapo — proving the architecture before committing to a full extension + Firefox build.

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
- Matches Sapo's internal format; Chrome delivers Float32 natively
- Mono is correct — tab audio is already a mixed stereo bus
- Chrome almost always delivers 48kHz natively; if not, Sapo's Mixer resamples

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
    chain = session.chain          // CaptureChain wrapping the stem writer
    tap = nil                      // no Core Audio tap
```

`TabCaptureSession` holds a `CaptureChain` internally and connects the TCP stream to it.

## File Structure

```
chrome-extension/
  manifest.json        # manifest v3, permissions: tabCapture, tabs, nativeMessaging
  background.js        # service worker: tabCapture + AudioContext + Native Messaging
  popup.html           # UI: tab list, select, start/stop
  popup.js             # popup UI logic

Sources/SapoNativeHost/
  main.swift           # Native Messaging stdin → TCP relay

Sources/Sapo/
  Core/TabCaptureSession.swift   # TCP server + stem writer
  Core/Models.swift              # SourceKind.tabCapture
  UI/RecorderView.swift          # tab source row
  UI/SettingsView.swift          # port config + enable toggle
```

## Protocol Details

### Native Messaging (Chrome → Swift Host)
- Standard Chrome Native Messaging protocol: 4-byte big-endian JSON message length, then JSON
- Message format:
  ```json
  {"type":"audio","tabId":"123","data":"base64..."}
  {"type":"silence","tabId":"123"}
  {"type":"error","tabId":"123","message":"..."}
  ```
- `audio`: 4096 Float32 samples (16384 bytes raw → ~22KB base64)
- `silence`: sent when no audio is detected (saves CPU)

### TCP (Swift Host → Sapo)
- Connection string: `localhost:5678` (configurable)
- Each message: JSON header + raw bytes
  ```json
  {"tabId":"123","sampleRate":48000,"frameCount":4096}
  ```
  followed by `frameCount × 4` bytes of Float32 PCM (little-endian)

## Error Handling

- **Chrome terminates**: `onended` on MediaStream → send disconnect → Sapo ends stem with `"tabDisconnected"`
- **TCP disconnect**: Swift host closes connection → Sapo ends stem with `"tcpDisconnected"`
- **Missing tab capture permission**: Extension popup shows error, source unavailable
- **Sapo not running**: Swift host retries TCP connection (exponential backoff, max 5s)

## UI Changes

### RecorderView
- New row type for tab sources: speaker icon + tab title + badge "Tab"
- Same mute/selection controls as app sources

### SettingsView
- "Tab Capture" section:
  - Toggle: Enable tab capture
  - TCP port: default 5678 (configurable)
  - Status indicator: "Connected" / "Disconnected"

### Popup UI
- Lists available tabs with titles
- "Start capture" / "Stop capture" buttons
- Shows which tabs are currently captured

## Testing

### Manual Validation (PoC goal)
1. Install Chrome extension from `chrome-extension/`
2. Launch Sapo via `run-sapo.command`, open Settings, enable tab capture
3. Play audio in a Chrome tab (e.g., YouTube, Spotify web)
4. Select the tab source in Sapo and start recording
5. Verify stem file exists and plays back correctly
6. Stop recording, export, verify tab audio is in the exported file

### Automated Tests
- `TabCaptureSessionTests` — TCP server starts, receives data, writes file
- `NativeHostTests` — stdin JSON → TCP relay correctness
- No unit tests for Chrome extension (browser automation out of scope)

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
- Auto-start on Chrome launch
- Tab selection UI inside Sapo (popup UI is external)
- Per-source gain/volume controls

## Risk Assessment

| Risk | Likelihood | Mitigation |
|---|---|---|
| Chrome tabCapture permissions | Low | Manifest v3 standard API, well-documented |
| AudioContext latency/jitter | Low | 4096 buffer size is standard, Chrome handles scheduling |
| TCP connection drops | Medium | Swift host retries, Sapo handles disconnect gracefully |
| Native Messaging stdio blocking | Low | Swift host reads async, non-blocking |
| Chrome terminates during recording | Medium | `onended` handler → clean stem end |
