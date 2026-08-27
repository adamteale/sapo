#!/usr/bin/env python3
"""Fake Chrome: spawns SapoTabHost and pipes length-prefixed native messages
containing a 440Hz sine wave (48kHz mono Float32), 4800 frames per message.
Use with `Sapo --record-tab` to test the full pipeline without Chrome."""
import struct, base64, subprocess, sys, time, math

HOST_BIN = ".build/release/SapoTabHost"
RATE = 48000
CHUNK = 4800          # 0.1s per message, matches worklet batch size
DURATION_S = float(sys.argv[1]) if len(sys.argv) > 1 else 3.0
REALTIME = "--no-realtime" not in sys.argv  # pace like real audio by default

messages = b""
total = int(RATE * DURATION_S)
phase = 0.0
for start in range(0, total, CHUNK):
    n = min(CHUNK, total - start)
    samples = []
    for i in range(n):
        samples.append(0.25 * math.sin(2 * math.pi * 440.0 * phase / RATE))
        phase += 1
    pcm = struct.pack(f"<{n}f", *samples)
    body = ('{"type":"audio","tabId":"cli","data":"%s"}'
            % base64.b64encode(pcm).decode()).encode()
    messages += struct.pack("<I", len(body)) + body

proc = subprocess.Popen([HOST_BIN, "chrome-extension://nhglbplanbiljndnbkaadecapgbbcdcb/"],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
proc.stdin.write(messages)
proc.stdin.flush()
# Hold stdin open so the host keeps running while paced; the recording session
# is time-boxed by --seconds, so we just pace the writes here.
if REALTIME:
    per = DURATION_S / (total / CHUNK)
    time.sleep(per * 2)  # let the recorder get ahead
proc.stdin.close()
proc.wait(timeout=5)
print(f"host stderr: {proc.stderr.read().decode().strip()}")
print(f"sent {total} frames ({DURATION_S}s @ 48kHz)")
