class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.frozenInputData = null;
    this.hasData = false;
    this.bufferSize = 4096;
    this.buffer = new Float32Array(this.bufferSize);
    this.writeIndex = 0;
    
    this.port.onmessage = (event) => {
      if (event.data && event.data.type === 'config') {
        this.bufferSize = event.data.bufferSize || 4096;
        this.buffer = new Float32Array(this.bufferSize);
      }
    };
  }
  
  process(inputs, outputs) {
    const input = inputs[0];
    if (input.length === 0) return true;
    
    const channelData = input[0];
    if (!channelData || channelData.length === 0) return true;
    
    // Copy data to our buffer (mono - first channel)
    const available = channelData.length;
    const spaceLeft = this.bufferSize - this.writeIndex;
    
    if (available >= spaceLeft && spaceLeft > 0) {
      // Fill and flush
      this.buffer.set(channelData.subarray(0, spaceLeft), this.writeIndex);
      this.flushBuffer();
      this.writeIndex = 0;
    } else if (available < spaceLeft) {
      // Partial fill
      this.buffer.set(channelData.subarray(0, available), this.writeIndex);
      this.writeIndex += available;
    } else {
      // Exactly fills buffer
      this.buffer.set(channelData, this.writeIndex);
      this.flushBuffer();
      this.writeIndex = 0;
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
