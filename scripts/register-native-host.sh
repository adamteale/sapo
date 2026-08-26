#!/bin/bash
# Register SapoTabHost as a Chrome native messaging host.
# Usage: ./scripts/register-native-host.sh [path-to-SapoTabHost]
#
# If no path is given, looks for SapoTabHost in .build/release/.

set -euo pipefail

HOST_NAME="com.sapomac.sapo-tab-capture"
MANIFEST_DIR="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
MANIFEST_FILE="$MANIFEST_DIR/${HOST_NAME}.json"

# Determine SapoTabHost path
if [ $# -gt 0 ]; then
    HOST_PATH="$1"
else
    HOST_PATH="$(pwd)/.build/release/SapoTabHost"
fi

# Verify the binary exists
if [ ! -f "$HOST_PATH" ]; then
    echo "Error: SapoTabHost not found at $HOST_PATH"
    echo "Build it first: swift build -c release --product SapoTabHost"
    exit 1
fi

# Create manifest directory if it doesn't exist
mkdir -p "$MANIFEST_DIR"

# Extension ID is deterministic: chrome-extension/manifest.json pins a public
# `key`, so the ID is stable regardless of which directory it's loaded from.
# ID = first 128 bits of SHA-256(SPKI DER), mapped to a-p.
EXTENSION_ID="nhglbplanbiljndnbkaadecapgbbcdcb"

# Create manifest
cat > "$MANIFEST_FILE" << EOF
{
  "name": "$HOST_NAME",
  "description": "Sapo tab capture native messaging host",
  "path": "$HOST_PATH",
  "type": "stdio",
  "allowed_origins": [
    "chrome-extension://$EXTENSION_ID/"
  ]
}
EOF

echo "Registered native messaging host at: $MANIFEST_FILE"
echo "Allowed extension ID: $EXTENSION_ID (pinned via manifest key)"
echo ""
echo "Next steps:"
echo "1. Open chrome://extensions in Chrome"
echo "2. Enable Developer mode (top right toggle)"
echo "3. Click 'Load unpacked' and select the chrome-extension/ directory"
echo "4. Verify the extension ID shown matches: $EXTENSION_ID"
echo "5. The extension can now connect to the native host — no manifest editing needed"
