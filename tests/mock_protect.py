#!/usr/bin/env python3
"""Mock of the UniFi Protect Integration API (HTTPS + WebSocket) for testing the FHEM modules without a console.

Usage: mock_protect.py <tls-cert> <tls-key> [api-port=18443] [control-port=18081]
Control (plain HTTP on 127.0.0.1:<control-port>):
  /push?kind=events|devices&msg=<json>   send a websocket message to all connected clients of that kind
  /kill                                  close all websockets (like a Protect restart)
  /down?on=1|0                           refuse all API requests with HTTP 503 (1) or work again (0)
  /apikey?value=<key>                    change the accepted API key (to test 401 handling)
  /state                                 JSON with counters (connections, requests, patches)
Only the Python standard library is used.
"""
import base64, hashlib, json, ssl, socket, sys, threading, struct, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

CERT, KEY = sys.argv[1], sys.argv[2]
API_PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 18443
CTL_PORT = int(sys.argv[4]) if len(sys.argv) > 4 else 18081
BASE = "/proxy/protect/integration"
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

state = {"apikey": "TESTKEY", "down": False, "requests": 0, "patches": [], "ws_connections": 0, "posts": []}
ws_clients = {"events": [], "devices": []}
lock = threading.Lock()

DEVICES = {
    "cameras": [
        {"id": "cam001", "modelKey": "camera", "state": "CONNECTED", "name": "Garage", "mac": "AABBCCDDEE01", "isMicEnabled": True,
         "osdSettings": {"isNameEnabled": True, "isDateEnabled": True, "isLogoEnabled": False, "isDebugEnabled": False, "overlayLocation": "topLeft"},
         "ledSettings": {"isEnabled": True}, "micVolume": 50, "activePatrolSlot": None, "videoMode": "default", "hdrType": "auto",
         "featureFlags": {"hasHdr": True, "hasMic": True, "hasSpeaker": False, "hasLedStatus": True, "supportFullHdSnapshot": True,
                          "smartDetectTypes": ["person", "vehicle", "animal"], "smartDetectAudioTypes": ["alrmSmoke", "alrmBark"],
                          "videoModes": ["default", "highFps", "sport"]},
         "smartDetectSettings": {"objectTypes": ["person", "vehicle"], "audioTypes": []}},
        {"id": "cam002", "modelKey": "camera", "state": "DISCONNECTED", "name": "Eingang Süd", "mac": "AABBCCDDEE02", "micVolume": 0,
         "videoMode": "highFps", "hdrType": "off", "ledSettings": {"isEnabled": False}, "featureFlags": {}},
    ],
    "sensors": [
        {"id": "sen001", "modelKey": "sensor", "state": "CONNECTED", "name": "Fenster Bad", "mac": "AABBCCDDEE03", "mountType": "door",
         "batteryStatus": {"percentage": 87, "isLow": False},
         "stats": {"light": {"value": 12, "status": "neutral"}, "humidity": {"value": 55, "status": "neutral"}, "temperature": {"value": 21.5, "status": "neutral"}},
         "isOpened": False, "openStatusChangedAt": 1790000000000, "isMotionDetected": False, "motionDetectedAt": 1790000100000},
    ],
    "lights": [
        {"id": "lig001", "modelKey": "light", "state": "CONNECTED", "name": "Hof Flutlicht", "mac": "AABBCCDDEE04", "isDark": True, "isLightOn": False,
         "isLightForceEnabled": False, "lastMotion": 1790000200000, "isPirMotionDetected": False, "camera": "cam001",
         "lightModeSettings": {"mode": "motion", "enableAt": "dark"},
         "lightDeviceSettings": {"isIndicatorEnabled": True, "pirDuration": 30000, "pirSensitivity": 60, "ledLevel": 4}},
    ],
    "chimes": [{"id": "chi001", "modelKey": "chime", "state": "CONNECTED", "name": "Gong", "mac": "AABBCCDDEE05", "cameraIds": ["cam001"],
                "ringSettings": [{"cameraId": "cam001", "repeatTimes": 1, "ringtoneId": "r1", "volume": 60}]}],
    "nvrs": [{"id": "nvr001", "modelKey": "nvr", "name": "Test-NVR", "doorbellSettings": {"defaultMessageText": "Hallo"}}],
}
MISSING = {"viewers"}   # /v1/viewers -> 404, like a console without viewers


def find(kind, did):
    for d in DEVICES.get(kind, []):
        if d["id"] == did:
            return d


def merge(dst, patch):
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            merge(dst[k], v)
        else:
            dst[k] = v


def ws_frame(text):
    data = text.encode()
    n = len(data)
    head = bytes([0x81])
    if n < 126:
        head += bytes([n])
    elif n < 65536:
        head += bytes([126]) + struct.pack(">H", n)
    else:
        head += bytes([127]) + struct.pack(">Q", n)
    return head + data


class Api(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, body=b"", ctype="application/json"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _auth(self):
        with lock:
            state["requests"] += 1
            if state["down"]:
                self._send(503, {"error": "service unavailable"})
                return False
        if self.headers.get("X-API-KEY") != state["apikey"]:
            self._send(401, {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._auth():
            return
        p = urlparse(self.path).path
        if not p.startswith(BASE):
            return self._send(404, {"error": "not found"})
        p = p[len(BASE):]
        if p.startswith("/v1/subscribe/") and self.headers.get("Upgrade", "").lower() == "websocket":
            return self._websocket(p.split("/")[-1])
        if p == "/v1/meta/info":
            return self._send(200, {"applicationVersion": "7.2.105"})
        parts = p.strip("/").split("/")          # v1, cameras, id, snapshot
        if len(parts) == 2 and parts[1] == "nvrs":
            return self._send(200, DEVICES["nvrs"][0])          # the real API returns a single object here
        if len(parts) == 2 and parts[1] in DEVICES and parts[1] not in MISSING:
            return self._send(200, DEVICES[parts[1]])
        if len(parts) == 2 and parts[1] in MISSING:
            return self._send(404, {"error": "not found"})
        if len(parts) == 4 and parts[1] == "cameras" and parts[3] == "snapshot":
            return self._send(200, b"\xff\xd8\xff\xe0" + b"JPEG" * 100, "image/jpeg")
        if len(parts) == 4 and parts[1] == "cameras" and parts[3] == "rtsps-stream":
            if state.get("rtsps"):
                return self._send(200, {"high": "rtsps://127.0.0.1:7441/abc?enableSrtp"})
            return self._send(200, {})
        return self._send(404, {"error": "not found"})

    def do_PATCH(self):
        if not self._auth():
            return
        n = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(n) or b"{}")
        parts = urlparse(self.path).path[len(BASE):].strip("/").split("/")
        d = find(parts[1], parts[2]) if len(parts) == 3 else None
        if not d:
            return self._send(404, {"error": "not found"})
        with lock:
            state["patches"].append({"path": "/".join(parts), "body": body})
        merge(d, body)
        return self._send(200, d)

    def do_POST(self):
        if not self._auth():
            return
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n) if n else b""
        path = urlparse(self.path).path[len(BASE):]
        with lock:
            state["posts"].append({"path": path, "body": body.decode() or None})
        if path.endswith("/rtsps-stream"):
            state["rtsps"] = True
            return self._send(200, {"high": "rtsps://127.0.0.1:7441/abc?enableSrtp"})
        return self._send(200, {})

    def _websocket(self, kind):
        key = self.headers.get("Sec-WebSocket-Key", "")
        acc = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()
        self.wfile.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                          "Sec-WebSocket-Accept: %s\r\n\r\n" % acc).encode())
        self.wfile.flush()
        sock = self.connection
        with lock:
            ws_clients.setdefault(kind, []).append(sock)
            state["ws_connections"] += 1
        self.close_connection = True
        try:
            while True:                          # read & ignore client frames (ping/close) until the socket dies
                data = sock.recv(4096)
                if not data:
                    break
        except Exception:
            pass
        with lock:
            if sock in ws_clients.get(kind, []):
                ws_clients[kind].remove(sock)


class Ctl(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        out = {"ok": True}
        if u.path == "/push":
            frame = ws_frame(q["msg"][0])
            sent = 0
            with lock:
                for s in list(ws_clients.get(q["kind"][0], [])):
                    try:
                        s.sendall(frame)
                        sent += 1
                    except Exception:
                        pass
            out["sent"] = sent
        elif u.path == "/kill":
            with lock:
                for k in ws_clients:
                    for s in ws_clients[k]:
                        try:
                            s.shutdown(socket.SHUT_RDWR)
                        except Exception:
                            pass
                    ws_clients[k] = []
        elif u.path == "/down":
            state["down"] = q.get("on", ["1"])[0] == "1"
        elif u.path == "/apikey":
            state["apikey"] = q["value"][0]
        elif u.path == "/state":
            out = dict(state)
            out["ws"] = {k: len(v) for k, v in ws_clients.items()}
        body = json.dumps(out).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class ThreadedServer(HTTPServer):
    daemon_threads = True

    def process_request(self, request, client_address):
        threading.Thread(target=self._handle, args=(request, client_address), daemon=True).start()

    def _handle(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            pass
        finally:
            try:
                self.shutdown_request(request)
            except Exception:
                pass


if __name__ == "__main__":
    api = ThreadedServer(("127.0.0.1", API_PORT), Api)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(CERT, KEY)
    api.socket = ctx.wrap_socket(api.socket, server_side=True)
    threading.Thread(target=api.serve_forever, daemon=True).start()
    ctl = ThreadedServer(("127.0.0.1", CTL_PORT), Ctl)
    print("mock ready on %d (api) / %d (control)" % (API_PORT, CTL_PORT), flush=True)
    ctl.serve_forever()
