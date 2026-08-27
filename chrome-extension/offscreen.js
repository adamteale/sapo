// Offscreen document: per-tab capture graphs + one shared native messaging
// port for audio. Each captured tab gets its own AudioContext → worklet;
// every worklet chunk is tagged with its tabId before going to the host.
//
// Sapo-side (TabCaptureRouter) demultiplexes by tabId into per-tab stems.

const captures = new Map(); // tabId(String) -> {ctx, stream, sourceNode, workletNode}
let nativePort = null;

const WORKLET_CODE = `
class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() { super(); this.bufferSize = 4096; this.buffer = new Float32Array(this.bufferSize); this.writeIndex = 0; }
  process(inputs, outputs) {
    const input = inputs[0];
    if (!input || input.length === 0) return true;
    const channelData = input[0];
    if (!channelData || channelData.length === 0) return true;
    const available = channelData.length;
    const spaceLeft = this.bufferSize - this.writeIndex;
    if (available >= spaceLeft && spaceLeft > 0) {
      this.buffer.set(channelData.subarray(0, spaceLeft), this.writeIndex);
      this.flushBuffer();
      this.writeIndex = 0;
      const rest = available - spaceLeft;
      if (rest > 0) this.buffer.set(channelData.subarray(spaceLeft, available), 0), this.writeIndex = rest;
    } else if (available < spaceLeft) {
      this.buffer.set(channelData.subarray(0, available), this.writeIndex);
      this.writeIndex += available;
    }
    return true;
  }
  flushBuffer() {
    if (this.writeIndex === 0 && this.bufferSize !== 4096) return;
    const chunk = this.buffer.slice(0, this.writeIndex > 0 ? this.writeIndex : this.bufferSize);
    if (this.writeIndex === 0) this.writeIndex = this.bufferSize;
    const bytes = new Uint8Array(chunk.buffer);
    // 16KB chunks: btoa with spread overflows; chunk in 8KB slices.
    let binary = '';
    for (let i = 0; i < bytes.length; i += 8192) {
      binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 8192));
    }
    const base64 = btoa(binary);
    this.port.postMessage({ type: 'audio', data: base64 });
  }
}
registerProcessor('pcm-capture', PcmCaptureProcessor);
`;

function ensureNativePort() {
  if (nativePort) return nativePort;
  nativePort = chrome.runtime.connectNative('com.sapomac.sapo-tab-capture');
  nativePort.onDisconnect.addListener(() => { nativePort = null; });
  return nativePort;
}

async function startCapture(message) {
  const tabId = String(message.tabId);
  if (captures.has(tabId)) {
    return { success: true, already: true };
  }

  const port = ensureNativePort(); // connect BEFORE the audio graph runs

  const audioContext = new AudioContext({ sampleRate: 48000 });
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: {
      mandatory: {
        chromeMediaSource: 'tab',
        chromeMediaSourceId: message.streamId
      }
    }
  });

  const sourceNode = audioContext.createMediaStreamSource(stream);
  const blobUrl = URL.createObjectURL(new Blob([WORKLET_CODE], { type: 'application/javascript' }));
  await audioContext.audioWorklet.addModule(blobUrl);
  const workletNode = new AudioWorkletNode(audioContext, 'pcm-capture');

  workletNode.port.onmessage = (event) => {
    if (event.data && event.data.type === 'audio' && nativePort) {
      nativePort.postMessage({
        type: 'audio',
        tabId: tabId,
        data: event.data.data
      });
    }
  };

  // Connect last: source → worklet → destination (tab audio keeps playing).
  sourceNode.connect(workletNode);
  workletNode.connect(audioContext.destination);

  captures.set(tabId, { audioContext, stream, sourceNode, workletNode });
  return { success: true };
}

function teardownCapture(tabId) {
  const entry = captures.get(tabId);
  if (!entry) return;
  try { entry.workletNode.disconnect(); } catch (e) {}
  try { entry.sourceNode.disconnect(); } catch (e) {}
  try { entry.stream.getTracks().forEach(t => t.stop()); } catch (e) {}
  try { entry.audioContext.close(); } catch (e) {}
  captures.delete(tabId);
}

async function stopCapture(message) {
  if (message.tabId !== undefined) {
    teardownCapture(String(message.tabId));
  } else {
    for (const tabId of Array.from(captures.keys())) teardownCapture(tabId);
  }
  // No captures left → drop the audio port so the host (and its TCP
  // connection) exits cleanly.
  if (captures.size === 0 && nativePort) {
    nativePort.disconnect();
    nativePort = null;
  }
  // Close the offscreen document only when fully idle — Chrome allows just
  // one instance per URL and it is expensive to recreate.
  if (captures.size === 0) {
    try { await chrome.offscreen.closeDocument(); } catch (e) {}
  }
  return { success: true };
}

chrome.runtime.onMessage.addListener(async (message, sender, sendResponse) => {
  if (message.type === 'startCapture') {
    try {
      sendResponse(await startCapture(message));
    } catch (error) {
      // Clean up any half-built graph for this tab.
      if (message.tabId !== undefined) teardownCapture(String(message.tabId));
      sendResponse({ success: false, error: error.message });
    }
    return true;
  }
  if (message.type === 'stopCapture') {
    sendResponse(await stopCapture(message));
    return true;
  }
});
