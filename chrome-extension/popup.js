let selectedTabId = null;
let isRecording = false;

// Load tabs on popup open
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'tabsUpdated') {
    renderTabs(message.tabs);
  }
});

// Listen for capture status updates from background
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message.type === 'captureStatus') {
    if (message.recording) {
      isRecording = true;
      document.getElementById('status').textContent = 'Recording...';
      updateButtons();
    } else {
      isRecording = false;
      document.getElementById('status').textContent = message.error || 'Stopped';
      updateButtons();
    }
  }
});

// Initial load - query active tabs
chrome.tabs.query({active: true, currentWindow: true}, (tabs) => {
  renderTabs(tabs);
});

// Listen for tab updates (user switches tabs)
chrome.tabs.onUpdated.addListener(() => {
  chrome.tabs.query({active: true, currentWindow: true}, (tabs) => {
    renderTabs(tabs);
  });
});

function renderTabs(tabs) {
  const list = document.getElementById('tabList');
  list.innerHTML = '';
  
  if (tabs.length === 0) {
    list.innerHTML = '<div class="tab-item" style="color: #999;">No tabs available</div>';
    return;
  }
  
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
  
  document.getElementById('status').textContent = 'Starting...';
  
  try {
    // Get media stream ID for tab
    const streamId = await chrome.tabCapture.getMediaStreamId({
      targetTabId: selectedTabId
    });
    
    // Request tab capture permission
    const permission = await chrome.permissions.request({
      permissions: ['tabCapture']
    });
    
    if (!permission) {
      document.getElementById('status').textContent = 'Permission denied';
      return;
    }
    
    // Send to background service worker
    chrome.runtime.sendMessage({
      type: 'startCapture',
      streamId: streamId,
      tabId: selectedTabId.toString()
    }, (response) => {
      if (chrome.runtime.lastError) {
        document.getElementById('status').textContent = 'Error: ' + chrome.runtime.lastError.message;
        return;
      }
      
      if (response && response.success) {
        isRecording = true;
        document.getElementById('status').textContent = 'Recording...';
        updateButtons();
      } else {
        document.getElementById('status').textContent = 'Error: ' + (response?.error || 'Unknown');
      }
    });
  } catch (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
  }
};

document.getElementById('stopBtn').onclick = async () => {
  document.getElementById('status').textContent = 'Stopping...';
  
  try {
    chrome.runtime.sendMessage({ type: 'stopCapture' }, (response) => {
      if (chrome.runtime.lastError) {
        document.getElementById('status').textContent = 'Error: ' + chrome.runtime.lastError.message;
        return;
      }
      
      isRecording = false;
      document.getElementById('status').textContent = response?.success ? 'Stopped' : 'Error: ' + (response?.error || 'Unknown');
      updateButtons();
    });
  } catch (error) {
    document.getElementById('status').textContent = 'Error: ' + error.message;
  }
};
