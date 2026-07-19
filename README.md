# ADB Tablet Proxy

A zero-dependency HTTP proxy and Android device bridge that exposes local development servers to tablets on the same LAN. It solves three problems simultaneously: host-based redirects, CORS restrictions, and browser security policies that prevent testing on real devices.

## Problem

Modern web applications often decide which backend to call based on `window.location.hostname`. When accessed from a non-localhost origin (e.g., a tablet on the LAN), apps either redirect to a production environment or fail due to CORS policies. Services like Moodle reject requests that don't come from `localhost`, and libraries such as chatkit only permit CORS from `localhost`.

This tool eliminates all three obstacles without modifying application code:

1. **Host spoofing** -- rewrites the `Host` header to `localhost` before forwarding requests to backends, preventing unwanted redirects.
2. **CORS injection** -- injects permissive CORS headers into every response, satisfying browser security checks.
3. **On-the-fly bundle rewriting** -- rewrites JS bundles in transit so backend URLs reference the proxy origin instead of `localhost`. No files are modified on disk.

## Architecture

The project consists of two main components:

### Proxy Server (`proxy.js`)

A single `Node.js` HTTP server that listens on a configurable port (default `8090`) and routes incoming requests to local backends based on URL prefix matching. Routes are defined declaratively in `proxy.env` -- the longest prefix wins. The proxy handles host spoofing, CORS injection, and bundle rewriting transparently.

### ADB Bridge (`tablet.sh`)

A shell script that manages Android Debug Bridge (ADB) connections to one or more tablets. It sets up `adb reverse` tunnels so that each tablet sees localhost services as if they were running locally. Only one transport (USB or WiFi) is used per device to avoid tunnel contention.

## Prerequisites

The following services must be running on your development machine:

- Application backend and Moodle on port **80**
- Chatkit or AI agent on port **8000**

System dependencies:

- **Node.js** -- runs the proxy server
- **ADB** (`android-tools-adb`) -- Android device bridge
- **nmap** -- automatic port scanning for WiFi reconnection
- **curl** -- health checks
- **qrencode** -- QR code generation for wireless pairing (optional)

## Setup

```bash
sudo apt update
sudo apt install -y nodejs android-tools-adb nmap curl qrencode
```

Verify installation:

```bash
for c in node adb nmap curl qrencode; do
  command -v $c >/dev/null && echo "[OK] $c" || echo "[MISSING] $c"
done
```

## Configuration

All configuration is managed through environment files. Edit these files instead of modifying scripts.

### `proxy.env`

Controls proxy behavior:

| Variable       | Default       | Description                                       |
|----------------|---------------|---------------------------------------------------|
| `PORT`         | `8090`        | Port the proxy listens on                         |
| `HOST_SPOOF`   | `localhost`   | Host header value sent to backends (empty = off)  |
| `CORS`         | `on`          | Enable or disable CORS header injection           |
| `ROUTE`        | see below     | URL prefix to backend mapping (one per line)      |

Default routes:

```
ROUTE /chatkit 127.0.0.1:8000
ROUTE /        127.0.0.1:80
```

### `devices.env`

Registered Android devices. Format:

```
name | serial | ip:port | type
```

- `serial` -- hardware serial number (`ro.serialno`), the stable device identifier
- `ip:port` -- last known WiFi endpoint (ignored in USB mode)
- `type` -- `usb` (cable) or `wifi`

Add devices automatically using `./tablet.sh usb` or `./tablet.sh qr`.

### `urls.env`

Local URLs to expose on connected tablets. One per line. Supports full URLs or bare port numbers. Ports below 1024 cannot be forwarded via ADB on Android and should be accessed through the proxy.

## Usage

### Start the proxy

```bash
./start.sh
```

This detects your LAN IP, prints the tablet access URL, and starts the proxy. If `qrencode` is installed, a QR code is also displayed.

### Connect a tablet

Three exclusive connection modes are available:

| Mode | Command | Transport | Use Case |
|------|---------|-----------|----------|
| QR | `./tablet.sh qr [name]` | WiFi | Wireless pairing via QR code scan |
| USB | `./tablet.sh usb [name]` | USB | Permanent cable connection |
| WiFi | `./tablet.sh wifi [name]` | WiFi | Reconnect to a known endpoint |

Only one transport is active per device at a time. This prevents tunnel instability that occurs when both USB and WiFi are connected simultaneously.

```bash
# First-time USB connection
./tablet.sh usb my-tablet

# First-time QR wireless pairing
./tablet.sh qr my-tablet

# Reconnect all registered devices
./tablet.sh
```

### Device management

```bash
# Interactive device picker and transport switcher
./tablet.sh use

# Show connection status for all devices
./tablet.sh status
```

### Utility commands

```bash
# Take a screenshot
./tablet.sh cap [name]

# Open URLs on one or more tablets
./tablet.sh url

# Clear Chrome cache, cookies, and service workers
./tablet.sh clear

# Force-stop Chrome
./tablet.sh stop

# Live Chromium logcat
./tablet.sh logs [name]

# Screen recording (Ctrl+C to stop, max 180s)
./tablet.sh rec [name]
```

### Access from tablet

Open the same URL in Chrome on the tablet that you use on your development machine:

```
http://<LAN-IP>:8090/App/#/login
```

Because of the ADB reverse tunnel, the tablet sees `localhost` services as if they were running locally -- no redirects, no CORS errors.

## How It Works

### Request flow

```
Tablet Browser
      |
      v  http://192.168.x.x:8090/App/
Proxy (proxy.js)
      |
      +---> Backend A (e.g., Moodle on :80)     Host: localhost  (spoofed)
      +---> Backend B (e.g., chatkit on :8000)  CORS headers injected
      +---> JS bundle rewritten on-the-fly
      |
      v  Response with modified headers + optional bundle rewrite
Tablet Browser
```

### ADB reverse tunnel

When the tablet connects via ADB, `adb reverse tcp:8090 tcp:8090` creates a tunnel: any request the tablet makes to `localhost:8090` is transparently forwarded to the proxy running on the development machine.

## Project Structure

```
.
├── proxy.js          HTTP proxy server (zero dependencies)
├── start.sh          LAN IP detection + proxy launcher
├── tablet.sh         ADB device management and bridging
├── proxy.env         Proxy configuration
├── devices.env       Registered device database
├── urls.env          Local URLs to expose on tablets
├── comando.txt       Quick-reference cheat sheet
└── DEPENDENCIAS.txt  Detailed dependency guide and concepts
```

## Troubleshooting

- **Tablet shows stale content** -- run `./tablet.sh clear` to wipe Chrome's cache, cookies, and service workers.
- **Connection drops after unplugging USB** -- USB and WiFi transports conflict. Use `./tablet.sh use` to switch the device to WiFi mode.
- **Proxy not responding** -- check `/tmp/responsive-proxy.log` for errors and verify backends are running on the expected ports.
- **DHCP reservation recommended** -- assign a static IP to your tablet in the router settings to ensure reliable WiFi reconnection.
