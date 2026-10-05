# fhem-unifi-protect-ng

FHEM modules for **UniFi Protect** that use the **official Integration API** (API key) instead of the unofficial, session-based
interface used by older modules. Cameras, **smart detections**, sensors, lights, chimes and viewers are created automatically
and updated in real time over websockets.

> **Status: beta.** The modules are tested against a mock of the Protect Integration API (46 automated checks, see *Tests*).
> They have not yet been verified against every Protect release/device type. Issues and pull requests are welcome.

## Why a new module?
* **No sessions, cookies or CSRF tokens.** An API key does not expire when the console or Protect restarts. Older modules lost their
  session/websocket after a Protect restart and needed a FHEM restart.
* **Smart detections** (person, vehicle, animal, package, license plate, face), ring, motion, sensor events (open/close, leak, tamper,
  alarm, battery, ...) with start and end.
* **Open for all Protect devices**: anything the API reports becomes readings (nested values are flattened), unknown future event types
  appear as `event_<type>`, and `set <dev> patch {json}` sends any body to the device's PATCH endpoint.
* Self-healing: websocket loss, console restarts and outages are detected and the connection is rebuilt automatically.

## Installation
```
update add https://raw.githubusercontent.com/Lazgar/fhem-unifi-protect-ng/main/controls_UnifiProtectNG.txt
update all https://raw.githubusercontent.com/Lazgar/fhem-unifi-protect-ng/main/controls_UnifiProtectNG.txt
shutdown restart
```
Requires FHEM with the standard Perl modules (JSON, IO::Socket::SSL) and a UniFi OS console with Protect 5.3 or newer.

## Setup
1. In the UniFi OS web interface create an API key: *Settings → Control Plane → Integrations → Create API Key*.
2. In FHEM:
```
define protect UnifiProtectNG 192.168.1.1
set protect apiKey <your key>
```
The key is stored in FHEM's key store (not in `fhem.cfg`). Devices are created by `autocreate` as `UnifiProtectNGDevice`.

## Devices and readings
| Device | Examples |
|---|---|
| camera | `state`, `micVolume`, `videoMode`, `hdrType`, `statusLed`, `smartDetectObjectTypes`, `motion`, `smartDetected`, `smartDetect_person`, `smartDetect_vehicle`, `lastSmartDetect`, `ring`, `snapshotFile` |
| sensor | `batteryPercentage`, `batteryLow`, `temperature`, `humidity`, `illuminance`, `contact` (open/closed), `motion`, `alarm`, `leak`, `tamper` |
| light | `isLightOn`, `isDark`, `lastMotion`, `ledLevel`, `pirSensitivity`, `mode` |
| chime, viewer, nvr | all reported values as readings |

Set commands (camera): `micVolume`, `videoMode`, `hdr`, `statusLed`, `smartDetectObjectTypes`, `name`, `ptzGoto`, `ptzPatrolStart`,
`ptzPatrolStop`, `snapshot [file]`, `snapshotHQ`; light: `ledLevel`, `pirSensitivity`, `pirDuration`, `indicator`, `forceOn`, `mode`;
all: `patch {json}`. Get: `raw`, `rtspsStream` (camera). The bridge has `get devices`, `get info`, `set reconnect`, `set refresh`.

See the commandref (`help UnifiProtectNG`, `help UnifiProtectNGDevice`) for attributes.

## Live picture

The camera detail page (and optionally the room/summary view, `attr <cam> liveInSummary 1`) shows a continuously refreshed snapshot (default 1 s, `liveInterval` in ms, min 200; `liveWidth`; switch off with `liveView 0`).
The official API provides no browser-playable stream, only RTSPS (`get <cam> rtspsStream` for VLC/go2rtc) and snapshots. Pictures are served via the FHEMWEB extension `/fhem/UnifiProtectNG?dev=<cam>[&hq=1]` with a short cache, so many viewers do not multiply the load on the console.

## Limits of the official API (compared with the unofficial interface)
Not available through the Integration API, therefore not available here: IR LED mode/level, recording mode, `isRecording`, camera
health values (WiFi quality, uptime), event statistics and NVR statistics (CPU, storage, disk health). A hybrid setup with an older
module for those values is possible; the two modules do not interfere with each other.

## Notes
* Install new versions and **restart FHEM** (`shutdown restart`). `reload` is not enough for a bridge that already dispatched messages (FHEM caches the client list).
* `/v1/nvrs` of the real API returns a single object; lists that a console does not provide (e.g. no chimes) are skipped, they never block the connection.

## Tests
`python3 tests/run_tests.py` starts a mock Protect console (`tests/mock_protect.py`, HTTPS + WebSocket, Python standard library only)
and a throw-away FHEM instance on private ports. It checks API key handling, autocreate, readings, events (motion, smart detection, ring,
sensor, unknown types), set commands, snapshot, RTSPS, and recovery after websocket loss, console outage and key revocation.
The production FHEM is only read.

## Roadmap
* verification against more consoles/Protect versions, Access/Doorbell specifics, face/license-plate event metadata,
* optional JSON `eventMap`/readings configuration, `update`-site entry in the FHEM wiki.

## License
GPL-2.0-or-later (like FHEM). Not affiliated with Ubiquiti Inc.

---
### Kurzfassung (Deutsch)
FHEM-Anbindung für UniFi Protect über die **offizielle Integration-API** (API-Schlüssel): Kameras mit **Smart Detection** (Person, Fahrzeug,
Tier, Paket, Kennzeichen), Sensoren, Lichter, Gong und Viewer werden automatisch angelegt und in Echtzeit aktualisiert. Kein Session-Ablauf,
automatische Wiederverbindung nach Neustarts. Einrichtung: API-Schlüssel in UniFi OS erstellen (*Einstellungen → Control Plane → Integrations*),
dann `define protect UnifiProtectNG <IP>` und `set protect apiKey <Schlüssel>`.
