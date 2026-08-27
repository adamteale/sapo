#!/usr/bin/env python3
"""E2E harness for SapoTabHost with BOTH channels:
- registry (5679): tablist pushes as NDJSON
- capture (5678): multi-tab audio, header+PCM framing
Simulates Chrome on stdin; simulates Sapo with two TCP listeners."""
import socket, struct, subprocess, base64, json, sys, threading, time, math

HOST_BIN = ".build/release/SapoTabHost"

registry_lines = []
audio_messages = []

def ndjson_listener(port, sink):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    conn, _ = srv.accept()
    buf = b""
    deadline = time.time() + 5
    while time.time() < deadline:
        data = conn.recv(65536)
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            sink.append(json.loads(line))
    conn.close(); srv.close()

def audio_listener(port):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    conn, _ = srv.accept()
    buf = b""
    deadline = time.time() + 5
    while len(audio_messages) < 3 and time.time() < deadline:
        data = conn.recv(65536)
        if not data:
            break
        buf += data
        while len(audio_messages) < 3:
            nl = buf.find(b"\n")
            if nl < 0:
                break
            header = json.loads(buf[:nl]); buf = buf[nl+1:]
            need = header["frameCount"] * 4
            while len(buf) < need:
                more = conn.recv(65536)
                if not more:
                    return
                buf += more
            audio_messages.append((header, buf[:need]))
            buf = buf[need:]
    conn.close(); srv.close()

def native_msg(payload):
    body = json.dumps(payload).encode()
    return struct.pack("<I", len(body)) + body

# Build stdin feed: tablist + interleaved audio for two tabs
phase = 0
def sine_pcm(n):
    global phase
    samples = [0.25 * math.sin(2 * math.pi * 440.0 * (phase + i) / 48000) for i in range(n)]
    phase += n
    return struct.pack(f"<{n}f", *samples)

feed = native_msg({"type": "tablist", "tabId": "0", "tabs": [
    {"id": 11, "title": "YouTube — Song", "audible": True},
    {"id": 22, "title": "GitHub", "audible": False},
]})
feed += native_msg({"type": "audio", "tabId": "11", "data": base64.b64encode(sine_pcm(4800)).decode()})
feed += native_msg({"type": "audio", "tabId": "22", "data": base64.b64encode(sine_pcm(2400)).decode()})
feed += native_msg({"type": "audio", "tabId": "11", "data": base64.b64encode(sine_pcm(4800)).decode()})

t1 = threading.Thread(target=ndjson_listener, args=(5679, registry_lines))
t2 = threading.Thread(target=audio_listener, args=(5678,))
t1.start(); t2.start()
time.sleep(0.3)

proc = subprocess.run([HOST_BIN, "chrome-extension://x/"], input=feed,
                      capture_output=True, timeout=10)
t1.join(timeout=5); t2.join(timeout=5)

ok = True
if proc.stdout:
    print("FAIL: host wrote to stdout"); ok = False
if len(registry_lines) != 1:
    print(f"FAIL: expected 1 registry line, got {len(registry_lines)}"); ok = False
else:
    tabs = registry_lines[0]["tabs"]
    print(f"registry: {tabs}")
    if len(tabs) != 2 or tabs[0]["id"] != 11 or tabs[1]["title"] != "GitHub":
        print("FAIL: registry payload wrong"); ok = False
if len(audio_messages) != 3:
    print(f"FAIL: expected 3 audio messages, got {len(audio_messages)}"); ok = False
else:
    ids = [h["tabId"] for h, _ in audio_messages]
    frames = {tid: sum(h["frameCount"] for h, _ in audio_messages if h["tabId"] == tid) for tid in ("11", "22")}
    print(f"audio tabs: {ids}, per-tab frames: {frames}")
    if ids != ["11", "22", "11"] or frames != {"11": 9600, "22": 2400}:
        print("FAIL: audio framing/demux wrong"); ok = False

print("host stderr:", proc.stderr.decode().strip()[:200])
print("\nRESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
