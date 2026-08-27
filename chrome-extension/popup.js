// Popup: list ALL tabs (every window), pick one to capture, or stop all.
let selectedTabId = null;
let isRecording = false;

document.addEventListener('DOMContentLoaded', () => {
  refreshTabs();
  document.getElementById('startBtn').onclick = startCapture;
  document.getElementById('stopBtn').onclick = stopAll;
  updateButtons();
});

function refreshTabs() {
  chrome.tabs.query({}, (tabs) => {
    const usable = tabs.filter(t =>
      t.title && !t.url.startsWith('chrome-extension://') && !t.url.startsWith('chrome://')
    );
    renderTabs(usable);
    // If the selected tab vanished, clear the selection.
    if (selectedTabId !== null && !usable.some(t => t.id === selectedTabId)) {
      selectedTabId = null;
      updateButtons();
    }
  });
}

chrome.runtime.onMessage.addListener((message) => {
  if (message.type === 'captureStatus') {
    isRecording = !!message.recording;
    document.getElementById('status').textContent =
      message.recording ? 'Capturing — start recording in Sapo' : (message.error || 'Stopped');
    updateButtons();
  }
});

function renderTabs(tabs) {
  const list = document.getElementById('tabList');
  list.innerHTML = '';
  if (tabs.length === 0) {
    list.innerHTML = '<div class="tab-item" style="color: #999;">No tabs</div>';
    return;
  }
  tabs.forEach(tab => {
    const div = document.createElement('div');
    div.className = 'tab-item' + (tab.id === selectedTabId ? ' selected' : '');
    const title = document.createElement('span');
    title.textContent = (tab.audible ? '🔊 ' : '') + (tab.title.length > 48 ? tab.title.slice(0, 45) + '…' : tab.title);
    div.appendChild(title);
    div.onclick = () => { selectedTabId = tab.id; renderTabs(tabs); updateButtons(); };
    list.appendChild(div);
  });
}

function updateButtons() {
  document.getElementById('startBtn').disabled = selectedTabId === null || isRecording;
  document.getElementById('stopBtn').disabled = !isRecording;
}

async function startCapture() {
  if (!selectedTabId) return;
  document.getElementById('status').textContent = 'Starting…';
  try {
    const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: selectedTabId });
    chrome.runtime.sendMessage({
      type: 'startCapture',
      streamId: streamId,
      tabId: String(selectedTabId)
    }, (response) => {
      if (chrome.runtime.lastError) {
        document.getElementById('status').textContent = 'Error: ' + chrome.runtime.lastError.message;
        return;
      }
      if (response && response.success) {
        isRecording = true;
        document.getElementById('status').textContent = 'Capturing — start recording in Sapo';
      } else {
        document.getElementById('status').textContent = 'Error: ' + (response?.error || 'Unknown');
      }
      updateButtons();
    });
  } catch (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
  }
}

function stopAll() {
  document.getElementById('status').textContent = 'Stopping…';
  chrome.runtime.sendMessage({ type: 'stopCapture' }, (response) => {
    if (chrome.runtime.lastError) {
      document.getElementById('status').textContent = 'Error: ' + chrome.runtime.lastError.message;
      return;
    }
    isRecording = false;
    document.getElementById('status').textContent = response?.success ? 'Stopped' : 'Error';
    updateButtons();
  });
}
