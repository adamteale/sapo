#!/usr/bin/env python3
"""Test harness: simulates Sapo's TCP side while feeding SapoTabHost
native-messaging messages as Chrome would (4-byte LE length + JSON)."""
import socket, struct, subprocess, threading, base64, json, sys, time

HOST_BIN = ".build/release/SapoTabHost"

received = []

def tcp_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 5678))
    srv.listen(1)
    conn, _ = srv.accept()
    # Read 2 messages: newline-terminated header + exact PCM payload each
    buf = b""
    deadline = time.time() + 5
    while len(received) < 2 and time.time() < deadline:
        data = conn.recv(65536)
        if not data:
            break
        buf += data
        while len(received) < 2:
            nl = buf.find(b"\n")
            if nl < 0:
                break
            header = buf[:nl]
            buf = buf[nl+1:]
            msg = json.loads(header)
            need = msg["frameCount"] * 4
            while len(buf) < need:
                more = conn.recv(65536)
                if not more:
                    return
                buf += more
            pcm = buf[:need]
            buf = buf[need:]
            received.append((msg, pcm))
    conn.close()
    srv.close()

def native_msg(payload: dict) -> bytes:
    body = json.dumps(payload).encode()
    return struct.pack("<I", len(body)) + body

# Two audio messages: 4 samples each of Float32 (values 1.0, -1.0, 0.5, 0.25)
pcm1 = struct.pack("<4f", 1.0, -1.0, 0.5, 0.25)
pcm2 = struct.pack("<4f", -0.5, 0.75, -0.25, 0.9)
messages = native_msg({"type": "audio", "tabId": "tab-1", "data": base64.b64encode(pcm1).decode()}) \
         + native_msg({"type": "audio", "tabId": "tab-1", "data": base64.b64encode(pcm2).decode()})

t = threading.Thread(target=tcp_server)
t.start()
time.sleep(0.3)

proc = subprocess.run([HOST_BIN, "chrome-extension://fake/"], input=messages,
                      capture_output=True, timeout=10)
t.join(timeout=5)

print(f"host stdout ({len(proc.stdout)} bytes): {proc.stdout!r}")
print(f"host stderr: {proc.stderr.decode().strip()!r}")
print(f"messages received: {len(received)}")

ok = True
if proc.stdout:
    print("FAIL: host wrote to stdout (would corrupt Chrome protocol)")
    ok = False
if len(received) != 2:
    print("FAIL: expected 2 framed messages")
    ok = False
else:
    (h1, p1), (h2, p2) = received
    print(f"msg1 header: {h1}")
    print(f"msg1 pcm:    {struct.unpack('<4f', p1)}")
    print(f"msg2 header: {h2}")
    print(f"msg2 pcm:    {struct.unpack('<4f', p2)}")
    if p1 != pcm1 or p2 != pcm2:
        print("FAIL: PCM bytes mismatch")
        ok = False
    if h1.get("tabId") != "tab-1" or h1.get("frameCount") != 4 or h1.get("sampleRate") != 48000:
        print("FAIL: header fields wrong")
        ok = False

print("\nRESULT:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
