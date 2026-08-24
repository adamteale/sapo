// Background service worker: manages offscreen document lifecycle
// and forwards messages between popup and offscreen document

let offscreenDocumentCreated = false;

chrome.runtime.onInstalled.addListener(() => {
  console.log('Sapo Tab Capture installed');
});

// Create offscreen document if needed
async function ensureOffscreenDocument() {
  if (!offscreenDocumentCreated) {
    try {
      // Check if document already exists
      const documents = await chrome.offscreen.getDocuments();
      if (documents.length === 0) {
        await chrome.offscreen.createDocument({
          url: 'offscreen.html',
          reasons: ['MEDIA_PLAYBACK'],
          justification: 'Tab audio capture for Sapo recording'
        });
        offscreenDocumentCreated = true;
        console.log('Offscreen document created');
      }
    } catch (error) {
      console.error('Failed to create offscreen document:', error);
    }
  }
}

// Forward messages from popup to offscreen
chrome.runtime.onMessage.addListener(async (message, sender, sendResponse) => {
  if (message.type === 'startCapture') {
    await ensureOffscreenDocument();
    
    // Forward startCapture message to offscreen document
    const tabs = await chrome.runtime.getPlatformInfo();
    
    // Send message to offscreen document via runtime
    chrome.runtime.sendMessage({
      type: 'startCapture',
      streamId: message.streamId,
      tabId: message.tabId
    }).then((response) => {
      sendResponse(response);
    }).catch((error) => {
      console.error('Failed to send to offscreen:', error);
      sendResponse({ success: false, error: 'Failed to communicate with offscreen document' });
    });
    
    return true; // Async response
  }
  
  if (message.type === 'stopCapture') {
    try {
      const response = await chrome.runtime.sendMessage({ type: 'stopCapture' });
      
      // Close offscreen document after stopping
      try {
        await chrome.offscreen.closeDocument();
        offscreenDocumentCreated = false;
      } catch (e) {
        // Document may already be closed
      }
      
      sendResponse(response);
    } catch (error) {
      console.error('Failed to stop capture:', error);
      sendResponse({ success: false, error: error.message });
    }
    
    return true; // Async response
  }
});
