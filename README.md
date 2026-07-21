# ADB Tablet Proxy

A zero-dependency HTTP proxy and Android device bridge that exposes local development servers to tablets and phones on the same LAN. Test your work on real devices — with the exact same `localhost` URLs you use on your desktop.

It solves three problems at once, without touching your application code:

1. **Host-based redirects** — apps and backends that only accept requests from `localhost` get a spoofed `Host` header and respond normally.
2. **CORS restrictions** — permissive CORS headers are injected into every response, so browsers stop blocking cross-origin calls.
3. **Real-device access** — `adb reverse` tunnels make each Android device see your machine's services as its own `localhost`.

## How it works

```
Tablet browser  ──  http://localhost:<port>/...
      │
      │  adb reverse tunnel (USB or WiFi — never both)
      ▼
Development machine
      │
      ▼
Proxy (proxy.js, default :8090)
      ├──►  ROUTE /api  → 127.0.0.1:8000      Host header spoofed to "localhost"
      └──►  ROUTE /     → 127.0.0.1:80        CORS headers injected
```

- **`tablet.sh`** manages device enrollment and connections over ADB, and registers the reverse tunnels for every port listed in `urls.env`.
- **`proxy.js`** is a single-file Node.js HTTP proxy (no npm packages) that fans requests out to one or more local backends by URL prefix — longest prefix wins. It can also rewrite JS bundles in transit (opt-in, marker-based; a no-op for apps that don't contain the marker).
- **One transport per device, by design.** An `adb reverse` tunnel binds to a single transport. If USB and WiFi are connected simultaneously, the tunnel sticks to USB and dies when the cable is unplugged. Every mode cleans up existing tunnels and re-registers them on exactly one transport, so that failure mode cannot happen.

> **iOS note:** iPads/iPhones have no ADB. For those, run `./start.sh` and open the printed `http://<your-lan-ip>:8090/...` URL (or scan its QR code) in Safari — same proxy, no tunnel.

## Quick start

```bash
git clone <repo-url> && cd ADB-tablet
./tablet.sh setup            # installs every missing dependency (apt/dnf/pacman)
./tablet.sh usb my-tablet    # enroll over USB cable, or:
./tablet.sh qr my-tablet     # enroll wirelessly via QR pairing
```

Then open the same URL you use locally (e.g. `http://localhost:5173`) in the tablet's browser. Done.

Day-to-day, a single command reconnects everything:

```bash
./tablet.sh                  # reconnects ALL enrolled devices per their saved type
```

## Requirements

| Tool | Purpose | Required |
|---|---|---|
| `adb` | device pairing, connections, reverse tunnels | yes |
| `node` | runs the proxy | yes |
| `curl` | health checks | yes |
| `nmap` | WiFi auto-reconnect when the ADB port rotates | recommended |
| `qrencode` | renders the pairing/access QR codes in the terminal | recommended |
| `avahi-utils` | mDNS discovery in QR mode | optional |

`./tablet.sh setup` detects your package manager (`apt`, `dnf`, or `pacman`) and installs **only what is missing**. Every run of `tablet.sh` also verifies dependencies and prints exactly what is absent and how to install it.

> **Warning:** keep a single `adb` installation. Two different versions (e.g. the distro package plus Google platform-tools) fight over the ADB server on port 5037 — each client kills the other's server, which surfaces as `protocol fault / connection reset` mid-pairing. The script detects this and warns at startup.

## Commands

### Connecting

| Command | Description |
|---|---|
| `./tablet.sh setup` | Install every missing dependency |
| `./tablet.sh qr [name]` | Enroll/connect via QR wireless pairing → WiFi |
| `./tablet.sh usb [name]` | Enroll/connect via USB cable → USB |
| `./tablet.sh wifi [name]` | Reconnect an enrolled device over WiFi |
| `./tablet.sh use` | Interactive menu: pick a device and/or switch its transport |
| `./tablet.sh` | Reconnect all enrolled devices per their saved type |
| `./tablet.sh status` | Show every device and how it is connected |

QR enrollment is fully automatic: after pairing it connects through up to three rounds of *stale-session cleanup → mDNS discovery → nmap port scan* against the IP learned during pairing. It never asks you to type an IP or port. On networks that block multicast (where mDNS never resolves), the nmap fallback carries the whole flow.

### Operating

| Command | Description |
|---|---|
| `./tablet.sh url` | Pick URL(s), device(s) and a **browser** — it lists the browsers actually installed on each device (Chrome, Firefox, Brave, Edge, Samsung Internet, …) and opens the URLs there |
| `./tablet.sh cap [name]` | Screenshot → `/tmp/<name>-<timestamp>.png` |
| `./tablet.sh rec [name]` | Screen recording → `/tmp` (Ctrl+C to stop) |
| `./tablet.sh logs [name]` | Live Chromium logcat stream |
| `./tablet.sh clear` | Clear browser cache, cookies and service workers |
| `./tablet.sh stop` | Force-stop the browser |

`clear` and `stop` target Chrome by default; override with `CHROME=<package> ./tablet.sh clear`.

## Configuration

Everything lives in three plain-text env files next to the scripts.

### `proxy.env` — proxy behavior

| Key | Default | Description |
|---|---|---|
| `PORT` | `8090` | Port the proxy listens on |
| `HOST_SPOOF` | `localhost` | `Host` header sent to backends (empty = forward the original) |
| `CORS` | `on` | Inject permissive CORS headers (`off` to disable) |
| `ROUTE <prefix> <host:port>` | — | Prefix → backend mapping, one per line; longest prefix wins |

```
ROUTE /api   127.0.0.1:3000
ROUTE /      127.0.0.1:5173
```

If no routes are defined, the proxy falls back to `/chatkit → 127.0.0.1:8000` and `/ → 127.0.0.1:80`.

### `devices.env` — enrolled devices (source of truth)

```
name | serial | ip:port | type
```

- `serial` is the hardware serial (`ro.serialno`) — it never changes, so a device is recognized even after its IP or ADB port rotates.
- `ip:port` is the last known WiFi endpoint (ignored in USB mode).
- `type` is `usb` or `wifi`.

Devices self-register on successful enrollment. To remove one, delete its line.

### `urls.env` — what to expose

One local URL (or bare port number) per line. Every listed port gets an `adb reverse` tunnel on connect.

```
http://localhost:5173/#/login
http://localhost:3000
8080
```

> Ports below 1024 cannot be reverse-forwarded on Android. Serve those through the proxy instead (e.g. put port 80 behind a `ROUTE` and expose the proxy's high port).

### Environment overrides

| Variable | Default | Description |
|---|---|---|
| `SCAN_RANGE` | `30000-65535` | Port range nmap scans during WiFi reconnection |
| `CHROME` | `com.android.chrome` | Browser package used by `clear`/`stop`/`logs` |

## Troubleshooting

**`protocol fault (couldn't read status): Connection reset by peer` during pairing**
Two `adb` installations are fighting over the server. Keep one: `sudo apt remove -y adb android-tools-adb` (if you use Google platform-tools) or delete the manually installed copy. The startup check reports the conflicting paths and versions.

**QR pairing succeeds but the connection takes a while**
Your network is probably blocking mDNS multicast, so discovery falls back to an nmap port scan (~30–60 s). This is expected and automatic. A DHCP reservation for the device on your router makes every later reconnection instant.

**`wifi` says the device is unreachable**
Its IP changed or Wireless debugging was switched off. Re-enroll with `./tablet.sh qr <name>` — and consider a DHCP reservation so it stops happening.

**The tablet shows stale content**
Almost always a service worker. Run `./tablet.sh clear` and reload.

**`status` warns about a DOUBLE transport**
The device is connected over USB and WiFi at the same time. Unplug the cable (WiFi mode) or run `./tablet.sh` to let the script normalize the tunnels.

## Project layout

```
tablet.sh          device enrollment, connections, tunnels, device utilities
proxy.js           zero-dependency HTTP proxy (Node.js)
start.sh           starts the proxy and prints/QRs the LAN access URL
proxy.env          proxy port, host spoofing, CORS, routes
devices.env        enrolled devices registry
urls.env           local URLs/ports to expose
DEPENDENCIES.txt   dependency reference and concept primer
commands.txt       one-page cheatsheet
```
