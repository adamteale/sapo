// Background service worker: tab-list discovery pushes + offscreen capture
// orchestration.
//
// Discovery: on browser start, tab events, and a 1-minute alarm, query ALL
// tabs and push {type:"tablist"} to the native host, which relays it to
// Sapo's registry (TCP 5679). A persistent native port is reused across
// pushes; if the host dies (browser restart, Sapo quit), it reconnects on
// the next push.
//
// Capture: popup requests start/stop; we ensure the offscreen document
// exists and forward. The offscreen document manages per-tab capture
// graphs and the audio native port.

let registryPort = null;
let offscreenDocumentCreated = false;

// ---------- Tab discovery ----------

function connectRegistry() {
  if (registryPort) return registryPort;
  registryPort = chrome.runtime.connectNative('com.sapomac.sapo-tab-capture');
  registryPort.onDisconnect.addListener(() => {
    registryPort = null; // host gone; next push reconnects
  });
  return registryPort;
}

function pushTabList() {
  chrome.tabs.query({}, (tabs) => {
    if (chrome.runtime.lastError) return;
    const payload = {
      type: 'tablist',
      tabId: '0',
      tabs: tabs
        .filter(t => t.title || t.url) // skip half-created tabs
        .map(t => ({
          id: t.id,
          title: t.title || t.url || 'Untitled',
          audible: !!t.audible
        }))
    };
    try {
      const port = connectRegistry();
      port.postMessage(payload);
    } catch (e) {
      registryPort = null;
    }
  });
}

// Push immediately whenever the service worker wakes up — browser start,
// event storms, or MV3 revival. This is the primary freshness mechanism;
// the alarm below is the backstop.
pushTabList();

chrome.tabs.onCreated.addListener(pushTabList);
chrome.tabs.onRemoved.addListener(pushTabList);
chrome.tabs.onUpdated.addListener(pushTabList);
chrome.tabs.onActivated.addListener(pushTabList);

chrome.runtime.onInstalled.addListener(() => {
  pushTabList();
  chrome.alarms.create('tablist-heartbeat', { periodInMinutes: 1 });
});
chrome.runtime.onStartup.addListener(() => {
  pushTabList();
  chrome.alarms.create('tablist-heartbeat', { periodInMinutes: 1 });
});
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === 'tablist-heartbeat') pushTabList();
});

// ---------- Capture orchestration ----------

async function ensureOffscreenDocument() {
  try {
    const documents = await chrome.offscreen.getDocuments();
    if (documents.length > 0) {
      offscreenDocumentCreated = true;
      return;
    }
    await chrome.offscreen.createDocument({
      url: 'offscreen.html',
      reasons: ['MEDIA_PLAYBACK'],
      justification: 'Tab audio capture for Sapo recording'
    });
    offscreenDocumentCreated = true;
  } catch (error) {
    // "Only a single offscreen instance may be created" races are benign.
    if (!String(error).includes('single offscreen')) {
      console.error('Failed to create offscreen document:', error);
    }
  }
}

chrome.runtime.onMessage.addListener(async (message, sender, sendResponse) => {
  if (message.type === 'startCapture') {
    await ensureOffscreenDocument();
    chrome.runtime.sendMessage({
      type: 'startCapture',
      streamId: message.streamId,
      tabId: message.tabId
    }).then((response) => {
      broadcastCaptureStatus(response);
      sendResponse(response);
    }).catch((error) => {
      const response = { success: false, error: 'Failed to communicate with offscreen document' };
      broadcastCaptureStatus(response);
      sendResponse(response);
    });
    return true; // async response
  }

  if (message.type === 'stopCapture') {
    try {
      const response = await chrome.runtime.sendMessage({
        type: 'stopCapture',
        tabId: message.tabId // undefined = stop all
      });
      broadcastCaptureStatus(response);
      sendResponse(response);
    } catch (error) {
      sendResponse({ success: false, error: String(error) });
    }
    return true;
  }
});

function broadcastCaptureStatus(response) {
  // Popup listens for this to update its buttons even when closed/reopened.
  chrome.runtime.sendMessage({
    type: 'captureStatus',
    recording: response && response.success,
    error: response && response.error
  }).catch(() => {}); // popup may be closed; ignore
}
