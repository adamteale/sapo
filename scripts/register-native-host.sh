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

# Get the extension ID from the manifest (known at build time)
EXTENSION_DIR="$(pwd)/chrome-extension"
if [ ! -f "$EXTENSION_DIR/manifest.json" ]; then
    echo "Error: chrome-extension/manifest.json not found"
    exit 1
fi

# Extract extension ID from manifest (will be set when loaded in Developer mode)
# Chrome generates a random ID for unpacked extensions, so we note this in the manifest
EXTENSION_ID="NOT_SET"

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
echo ""
echo "Next steps:"
echo "1. Open chrome://extensions in Chrome"
echo "2. Enable Developer mode (top right toggle)"
echo "3. Click 'Load unpacked' and select the chrome-extension/ directory"
echo "4. Note the Extension ID shown on the extension card"
echo "5. Update the allowed_origins in $MANIFEST_FILE with your extension ID"
echo "6. Reload the extension by clicking the reload icon"
