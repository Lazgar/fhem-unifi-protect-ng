#!/usr/bin/env python3
"""Integration test: starts the mock Protect console and a throw-away FHEM instance (own ports, own directory),
loads the modules from this repository and checks autocreate, readings, events, set commands and reconnect behaviour.

Needs a FHEM installation (default /opt/fhem), perl with FHEM's dependencies and python3 (stdlib only).
Usage: python3 tests/run_tests.py [--fhem /opt/fhem]
The production FHEM is only read (symlinks); the test instance uses ports 17072 (telnet), 18443 and 18081 (mock).
"""
import json, os, shutil, socket, subprocess, sys, time, urllib.parse, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FHEM_SRC = "/opt/fhem"
if "--fhem" in sys.argv:
    FHEM_SRC = sys.argv[sys.argv.index("--fhem") + 1]
W = "/tmp/upng-test"
TELNET, API, CTL = 17072, 18443, 18081
results = []


def check(name, ok, detail=""):
    results.append(ok)
    print(("PASS " if ok else "FAIL ") + name + (("  (" + str(detail) + ")") if detail and not ok else ""), flush=True)


def ctl(path, **q):
    url = "http://127.0.0.1:%d/%s?%s" % (CTL, path, urllib.parse.urlencode(q))
    return json.loads(urllib.request.urlopen(url, timeout=5).read())


def fhem(cmd):
    s = socket.create_connection(("127.0.0.1", TELNET), timeout=10)
    s.sendall((cmd + "\n").encode())
    out = b""
    start = time.time()
    s.settimeout(0.7)
    while time.time() - start < 15:
        try:
            d = s.recv(65536)
            if not d:
                break
            out += d
            start = max(start, time.time() - 14)      # data arrived: wait again for a short idle period
        except socket.timeout:
            if out:
                break
        except Exception:
            break
    try:
        s.sendall(b"quit\n")
    except Exception:
        pass
    s.close()
    return out.decode("utf-8", "replace").replace("\xff\xfb\x01", "").strip()


def reading(dev, r):
    try:
        j = json.loads(fhem("jsonlist2 %s" % dev))
        return j["Results"][0]["Readings"][r]["Value"]
    except Exception:
        return None


def internal(dev, i):
    try:
        return json.loads(fhem("jsonlist2 %s" % dev))["Results"][0]["Internals"].get(i)
    except Exception:
        return None


def wait(cond, timeout=20, step=0.5):
    t = time.time()
    while time.time() - t < timeout:
        try:
            if cond():
                return True
        except Exception:
            pass
        time.sleep(step)
    return False


def setup():
    shutil.rmtree(W, ignore_errors=True)
    os.makedirs(W + "/fhem/log")
    shutil.copy(FHEM_SRC + "/fhem.pl", W + "/fhem/fhem.pl")
    subprocess.run(["cp", "-rs", FHEM_SRC + "/FHEM", W + "/fhem/FHEM"], check=True)
    for n in ("lib", "www", "contrib"):
        if os.path.exists(FHEM_SRC + "/" + n):
            os.symlink(FHEM_SRC + "/" + n, W + "/fhem/" + n)
    # the key store (FHEM/FhemUtils) must NOT be shared with the production instance: use an own, empty one
    shutil.rmtree(W + "/fhem/FHEM/FhemUtils", ignore_errors=True)
    os.makedirs(W + "/fhem/FHEM/FhemUtils")
    os.makedirs(W + "/snap", exist_ok=True)
    for m in ("74_UnifiProtectNG.pm", "74_UnifiProtectNGDevice.pm"):
        p = W + "/fhem/FHEM/" + m
        if os.path.lexists(p):
            os.remove(p)
        shutil.copy(REPO + "/FHEM/" + m, p)
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", W + "/k.pem", "-out", W + "/c.pem",
                    "-subj", "/CN=127.0.0.1", "-days", "2"], check=True, capture_output=True)
    open(W + "/fhem/test.cfg", "w").write("""attr global modpath %s/fhem
attr global logfile %s/fhem/log/fhem.log
attr global verbose 3
attr global statefile %s/fhem/fhem.save
attr global autoload_undefined_devices 1
define telnetPort telnet %d
define autocreate autocreate
attr autocreate autosave 0
define bridge UnifiProtectNG 127.0.0.1:%d
attr bridge checkInterval 3
attr bridge refreshInterval 0
attr bridge verbose 4
""" % (W, W, W, TELNET, API))


def drop_privileges():
    """FHEM refuses to log as root in some setups: run the test instance as the 'fhem' user when started as root."""
    if os.geteuid() != 0:
        return None
    import pwd
    try:
        u = pwd.getpwnam("fhem")
    except KeyError:
        return None
    subprocess.run(["chown", "-R", "%d:%d" % (u.pw_uid, u.pw_gid), W], check=True)

    def fn():
        os.setgid(u.pw_gid)
        os.setuid(u.pw_uid)
    return fn


def main():
    setup()
    pre = drop_privileges()
    mock = subprocess.Popen([sys.executable, HERE + "/mock_protect.py", W + "/c.pem", W + "/k.pem", str(API), str(CTL)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=pre)
    mock.stdout.readline()
    fh = subprocess.Popen(["perl", "fhem.pl", "test.cfg"], cwd=W + "/fhem", stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, preexec_fn=pre)
    try:
        ok = wait(lambda: "bridge" in fhem("list bridge"), 40)
        check("FHEM test instance starts, module loads", ok)
        if not ok:
            return

        # --- API key handling
        check("without key: state 'no apiKey'", wait(lambda: reading("bridge", "state") == "no apiKey", 10), reading("bridge", "state"))
        fhem("set bridge apiKey WRONG")
        check("wrong key: state 'unauthorized'", wait(lambda: reading("bridge", "state") == "unauthorized", 15), reading("bridge", "state"))
        req_before = ctl("state")["requests"]
        time.sleep(8)
        req_after = ctl("state")["requests"]
        check("unauthorized: no request storm (<=3 requests in 8 s)", req_after - req_before <= 3, req_after - req_before)
        fhem("set bridge apiKey TESTKEY")
        check("correct key: state 'opened'", wait(lambda: reading("bridge", "state") == "opened", 25), reading("bridge", "state"))
        check("Protect version reading", reading("bridge", "protectVersion") == "7.2.105", reading("bridge", "protectVersion"))

        # --- autocreate + readings
        names = json.loads(fhem("jsonlist2 TYPE=UnifiProtectNGDevice"))["Results"] if wait(lambda: "UProtNG_" in fhem("list TYPE=UnifiProtectNGDevice"), 15) else []
        n = sorted(r["Name"] for r in names)
        check("autocreate: 6 devices (2 cameras, sensor, light, chime, nvr)", len(n) == 6, n)
        cam = "UProtNG_camera_Garage"
        sen = "UProtNG_sensor_Fenster_Bad"
        lig = "UProtNG_light_Hof_Flutlicht"
        check("camera readings: micVolume/statusLed/hdrType", (reading(cam, "micVolume"), reading(cam, "statusLed"), reading(cam, "hdrType")) == ("50", "on", "auto"),
              (reading(cam, "micVolume"), reading(cam, "statusLed"), reading(cam, "hdrType")))
        check("camera state internal 'connected'", internal(cam, "STATE") == "connected", internal(cam, "STATE"))
        check("sensor readings: temperature/humidity/battery", (reading(sen, "temperature"), reading(sen, "humidity"), reading(sen, "batteryPercentage")) == ("21.5", "55", "87"),
              (reading(sen, "temperature"), reading(sen, "humidity"), reading(sen, "batteryPercentage")))
        check("light readings: ledLevel/mode/isDark", (reading(lig, "ledLevel"), reading(lig, "mode"), reading(lig, "isDark")) == ("4", "motion", "1"),
              (reading(lig, "ledLevel"), reading(lig, "mode"), reading(lig, "isDark")))
        check("timestamp readings are formatted", (reading(lig, "lastMotion") or "").startswith("20"), reading(lig, "lastMotion"))
        check("404 for /viewers is tolerated (bridge stays opened)", reading("bridge", "state") == "opened")
        check("websockets open (events+devices)", ctl("state")["ws"] == {"events": 1, "devices": 1}, ctl("state")["ws"])

        # --- events
        def push(kind, msg):
            ctl("push", kind=kind, msg=json.dumps(msg))
        push("events", {"type": "add", "item": {"id": "e1", "modelKey": "event", "type": "motion", "start": 1790001000000, "end": None, "device": "cam001"}})
        check("event: motion on", wait(lambda: reading(cam, "motion") == "on", 5), reading(cam, "motion"))
        push("events", {"type": "update", "item": {"id": "e1", "modelKey": "event", "type": "motion", "start": 1790001000000, "end": 1790001010000, "device": "cam001"}})
        check("event: motion off after end", wait(lambda: reading(cam, "motion") == "off", 5), reading(cam, "motion"))
        push("events", {"type": "add", "item": {"id": "e2", "modelKey": "event", "type": "smartDetectZone", "start": 1790002000000, "end": None, "device": "cam001", "smartDetectTypes": ["person"]}})
        check("smart detection: person on, smartDetected on",
              wait(lambda: reading(cam, "smartDetect_person") == "on" and reading(cam, "smartDetected") == "on", 5), (reading(cam, "smartDetect_person"), reading(cam, "smartDetected")))
        check("smart detection: lastSmartDetectTypes=person", reading(cam, "lastSmartDetectTypes") == "person", reading(cam, "lastSmartDetectTypes"))
        push("events", {"type": "update", "item": {"id": "e2", "modelKey": "event", "type": "smartDetectZone", "start": 1790002000000, "end": 1790002005000, "device": "cam001", "smartDetectTypes": ["person"]}})
        check("smart detection: off after end", wait(lambda: reading(cam, "smartDetect_person") == "off" and reading(cam, "smartDetected") == "off", 5))
        push("events", {"type": "add", "item": {"id": "e3", "modelKey": "event", "type": "sensorOpened", "start": 1790003000000, "end": 1790003000000, "device": "sen001", "metadata": {}}})
        check("sensor event: contact open", wait(lambda: reading(sen, "contact") == "open", 5), reading(sen, "contact"))
        push("events", {"type": "add", "item": {"id": "e4", "modelKey": "event", "type": "ring", "start": 1790004000000, "end": None, "device": "cam001"}})
        check("ring event: ring on", wait(lambda: reading(cam, "ring") == "on", 5), reading(cam, "ring"))
        push("events", {"type": "add", "item": {"id": "e5", "modelKey": "event", "type": "futureThing", "start": 1790005000000, "end": None, "device": "sen001"}})
        check("unknown event type kept as event_<type>", wait(lambda: reading(sen, "event_futureThing") == "on", 5), reading(sen, "event_futureThing"))
        push("events", {"type": "add", "item": {"id": "e6", "modelKey": "event", "type": "motion", "start": 1790006000000, "end": None, "device": "ghost999"}})
        time.sleep(1)
        check("event for unknown device is ignored (still opened)", reading("bridge", "state") == "opened")

        # --- device updates
        push("devices", {"type": "update", "item": {"id": "cam001", "modelKey": "camera", "micVolume": 70, "state": "DISCONNECTED"}})
        check("device update: micVolume 70", wait(lambda: reading(cam, "micVolume") == "70", 5), reading(cam, "micVolume"))
        check("device update: state internal disconnected", wait(lambda: internal(cam, "STATE") == "disconnected", 5), internal(cam, "STATE"))
        push("devices", {"type": "add", "item": {"id": "sen002", "modelKey": "sensor", "state": "CONNECTED", "name": "Neu", "isOpened": True}})
        check("device add over websocket creates a device", wait(lambda: "UProtNG_sensor_Neu" in fhem("list TYPE=UnifiProtectNGDevice"), 8))

        # --- set / get
        fhem("set %s micVolume 30" % cam)
        check("set micVolume -> PATCH body + reading",
              wait(lambda: any(p["path"].endswith("cameras/cam001") and p["body"] == {"micVolume": 30} for p in ctl("state")["patches"]), 5) and wait(lambda: reading(cam, "micVolume") == "30", 5))
        fhem("set %s statusLed off" % cam)
        check("set statusLed off -> ledSettings.isEnabled=false", wait(lambda: any(p["body"] == {"ledSettings": {"isEnabled": False}} for p in ctl("state")["patches"]), 5))
        check("reading statusLed off", wait(lambda: reading(cam, "statusLed") == "off", 5), reading(cam, "statusLed"))
        fhem("set %s hdr on" % cam)
        check("set hdr on", wait(lambda: any(p["body"] == {"hdrType": "on"} for p in ctl("state")["patches"]), 5))
        fhem("set %s videoMode sport" % cam)
        check("set videoMode sport", wait(lambda: any(p["body"] == {"videoMode": "sport"} for p in ctl("state")["patches"]), 5))
        check("set videoMode with invalid value is refused", "videoMode:" in fhem("set %s videoMode nonsense" % cam))
        fhem('set %s smartDetectObjectTypes person,animal' % cam)
        check("set smartDetectObjectTypes", wait(lambda: any(p["body"] == {"smartDetectSettings": {"objectTypes": ["person", "animal"]}} for p in ctl("state")["patches"]), 5))
        fhem('set %s patch {"name":"Garage Neu"}' % cam)
        check("set patch {json}", wait(lambda: any(p["body"] == {"name": "Garage Neu"} for p in ctl("state")["patches"]), 5))
        fhem("set %s ptzGoto 2" % cam)
        check("set ptzGoto -> POST ptz/goto/2", wait(lambda: any(p["path"].endswith("/cameras/cam001/ptz/goto/2") for p in ctl("state")["posts"]), 5))
        fhem("set %s ledLevel 6" % lig)
        check("light: set ledLevel", wait(lambda: any(p["path"].endswith("lights/lig001") and p["body"] == {"lightDeviceSettings": {"ledLevel": 6}} for p in ctl("state")["patches"]), 5))
        fhem("set %s snapshot test.jpg" % cam)
        snap = W + "/snap"
        fhem("attr %s snapshotDir %s" % (cam, snap))
        fhem("set %s snapshot test.jpg" % cam)
        check("snapshot written as JPEG file", wait(lambda: os.path.exists(snap + "/test.jpg") and open(snap + "/test.jpg", "rb").read(4) == b"\xff\xd8\xff\xe0", 8))
        fhem("get %s rtspsStream" % cam)
        check("get rtspsStream stores rtspsUrl_high", wait(lambda: (reading(cam, "rtspsUrl_high") or "").startswith("rtsps://"), 8), reading(cam, "rtspsUrl_high"))
        check("get raw returns JSON", '"modelKey"' in fhem("get %s raw" % cam))

        # --- recovery: websocket killed (Protect restart)
        ctl("kill")
        check("after kill: back to 'opened' and websockets reconnected",
              wait(lambda: reading("bridge", "state") == "opened" and ctl("state")["ws"] == {"events": 1, "devices": 1}, 40), (reading("bridge", "state"), ctl("state")["ws"]))
        push("events", {"type": "add", "item": {"id": "e7", "modelKey": "event", "type": "motion", "start": 1790007000000, "end": None, "device": "cam001"}})
        check("events flow again after reconnect", wait(lambda: reading(cam, "motion") == "on", 5), reading(cam, "motion"))

        # --- recovery: console down for a while
        ctl("down", on=1)
        ctl("kill")
        check("console down: state leaves 'opened'", wait(lambda: reading("bridge", "state") != "opened", 20), reading("bridge", "state"))
        time.sleep(8)
        ctl("down", on=0)
        check("console back: 'opened' again", wait(lambda: reading("bridge", "state") == "opened" and ctl("state")["ws"] == {"events": 1, "devices": 1}, 60), (reading("bridge", "state"), ctl("state")["ws"]))

        # --- key revoked while running
        ctl("apikey", value="OTHER")
        check("key revoked while running: state 'unauthorized'", wait(lambda: reading("bridge", "state") == "unauthorized", 20), reading("bridge", "state"))
        ctl("apikey", value="TESTKEY")
        fhem("set bridge reconnect")
        check("set reconnect recovers", wait(lambda: reading("bridge", "state") == "opened", 25), reading("bridge", "state"))
    finally:
        fh.terminate()
        mock.terminate()
        time.sleep(1)
        log = open(W + "/fhem/log/fhem.log", errors="replace").read() if os.path.exists(W + "/fhem/log/fhem.log") else ""
        bad = [l for l in log.splitlines() if "PERL WARNING" in l and "UnifiProtectNG" in l or "Undefined subroutine" in l or "syntax error" in l]
        check("no Perl warnings/errors from the modules in the FHEM log", not bad, bad[:3])
        print("\n%d/%d checks passed" % (sum(results), len(results)))
        sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
