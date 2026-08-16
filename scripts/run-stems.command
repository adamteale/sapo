#!/bin/bash
# Stems dev launcher — launches the app in a context where macOS's audio
# server delivers process-tap audio (see README "Running dev builds").
#
# WHY THIS EXISTS: on this macOS build, apps launched normally (Finder/Dock)
# receive silent process taps even with microphone permission granted;
# the same binary launched as a Terminal child receives audio normally.
# Double-clicking this file opens Terminal, which provides that context.
# Tracked as the "LaunchServices tap silence" issue.

cd "$(dirname "$0")/.."
# Detach so closing the Terminal window doesn't quit Stems. The launch
# context (responsible process) is fixed at process birth, so detaching
# afterwards keeps the working tap context.
nohup build/Stems.app/Contents/MacOS/Stems >/dev/null 2>&1 & disown
echo "Stems is running — you can close this Terminal window."
