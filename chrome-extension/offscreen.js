// Offscreen document: captures tab audio via AudioWorklet and forwards to native host
let audioContext = null;
let mediaStream = null;
let workletNode = null;
let nativePort = null;
let currentTabId = null;

// Connect to native messaging host
function connectNative() {
  nativePort = chrome.runtime.connectNative('com.sapomac.sapo-tab-capture');
  nativePort.onMessage.addListener((message) => {
    // Host may send acknowledgments or status updates
  });
  nativePort.onDisconnect.addListener(() => {
    console.error('Native host disconnected');
  });
}

// Start tab audio capture
chrome.runtime.onMessage.addListener(async (message, sender, sendResponse) => {
  if (message.type === 'startCapture') {
    try {
      // Create AudioContext at 48kHz
      audioContext = new AudioContext({ sampleRate: 48000 });
      
      // Get media stream for tab
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          mandatory: {
            chromeMediaSource: 'tab',
            chromeMediaSourceId: message.streamId
          }
        }
      });
      
      mediaStream = stream;
      currentTabId = message.tabId;
      
      // Create source from media stream
      const source = audioContext.createMediaStreamSource(stream);
      
      // Load and connect AudioWorklet
      // Use blob URL for CSP-safe loading
      const workletCode = `
class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.bufferSize = 4096;
    this.buffer = new Float32Array(this.bufferSize);
    this.writeIndex = 0;
  }
  
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
    } else if (available < spaceLeft) {
      this.buffer.set(channelData.subarray(0, available), this.writeIndex);
      this.writeIndex += available;
    }
    
    return true;
  }
  
  flushBuffer() {
    if (this.writeIndex === 0) return;
    
    const chunk = this.buffer.slice(0, this.writeIndex);
    const bytes = new Uint8Array(chunk.buffer);
    const base64 = btoa(String.fromCharCode.apply(null, bytes));
    
    this.port.postMessage({
      type: 'audio',
      data: base64
    });
  }
}

registerProcessor('pcm-capture', PcmCaptureProcessor);
`;
      
      const blob = new Blob([workletCode], { type: 'application/javascript' });
      const blobUrl = URL.createObjectURL(blob);
      
      await audioContext.audioWorklet.addModule(blobUrl);
      workletNode = new AudioWorkletNode(audioContext, 'pcm-capture');
      
      // Connect: source → worklet → destination (keeps audio playing)
      source.connect(workletNode);
      workletNode.connect(audioContext.destination);
      
      // Listen for audio data from worklet processor
      workletNode.port.onmessage = (event) => {
        if (event.data && event.data.type === 'audio') {
          // Forward to native messaging host
          if (nativePort) {
            nativePort.postMessage({
              type: 'audio',
              tabId: currentTabId,
              data: event.data.data
            });
          }
        }
      };
      
      connectNative();
      
      sendResponse({ success: true });
    } catch (error) {
      console.error('Capture failed:', error);
      sendResponse({ success: false, error: error.message });
    }
  }
  
  if (message.type === 'stopCapture') {
    // Disconnect audio graph
    if (workletNode) {
      workletNode.disconnect();
    }
    if (mediaStream) {
      mediaStream.getTracks().forEach(track => track.stop());
    }
    if (audioContext) {
      await audioContext.close();
    }
    if (nativePort) {
      nativePort.disconnect();
    }
    
    // Close offscreen document
    try {
      await chrome.offscreen.closeDocument();
    } catch (e) {
      // Document may already be closed
    }
    
    sendResponse({ success: true });
  }
});
