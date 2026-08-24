let selectedTabId = null;
let isRecording = false;

// Load tabs on popup open
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'tabsUpdated') {
    renderTabs(message.tabs);
  }
});

// Initial load
chrome.tabs.query({active: true, currentWindow: true}, (tabs) => {
  renderTabs(tabs);
});

function renderTabs(tabs) {
  const list = document.getElementById('tabList');
  list.innerHTML = '';
  
  tabs.forEach(tab => {
    const div = document.createElement('div');
    div.className = 'tab-item' + (tab.id === selectedTabId ? ' selected' : '');
    div.textContent = tab.title || 'Untitled';
    div.onclick = () => {
      selectedTabId = tab.id;
      renderTabs(tabs);
      updateButtons();
    };
    list.appendChild(div);
  });
}

function updateButtons() {
  document.getElementById('startBtn').disabled = selectedTabId === null || isRecording;
  document.getElementById('stopBtn').disabled = !isRecording;
}

document.getElementById('startBtn').onclick = async () => {
  if (!selectedTabId) return;
  
  try {
    // Start tab capture in offscreen document
    const streamId = await chrome.tabCapture.getMediaStreamId({
      targetTabId: selectedTabId
    });
    
    // Send to offscreen document
    await chrome.runtime.sendMessage({
      type: 'startCapture',
      streamId: streamId,
      tabId: selectedTabId.toString()
    });
    
    isRecording = true;
    document.getElementById('status').textContent = 'Recording...';
    updateButtons();
  } catch (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
  }
};

document.getElementById('stopBtn').onclick = async () => {
  try {
    await chrome.runtime.sendMessage({ type: 'stopCapture' });
    isRecording = false;
    document.getElementById('status').textContent = 'Stopped';
    updateButtons();
  } catch (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
  }
};
