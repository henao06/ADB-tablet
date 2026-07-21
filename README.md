
## ADB Tablet Proxy
A zero-dependency HTTP proxy and Android device bridge that exposes local development servers to tablets on the same LAN. It solves three problems simultaneously: host-based redirects, CORS restrictions, and browser security policies that prevent testing on real devices.
## Problem
Modern web applications often decide which backend to call based on window.location.hostname. When accessed from a non-localhost origin (e.g., a tablet on the LAN), apps either redirect to a production environment or fail due to CORS policies. Certain services and libraries reject requests that do not explicitly come from localhost or restrict CORS permissions solely to this origin.
This tool eliminates all three obstacles without modifying application code:

   1. Host spoofing -- rewrites the Host header to localhost before forwarding requests to backends, preventing unwanted redirects.
   2. CORS injection -- injects permissive CORS headers into every response, satisfying browser security checks.
   3. On-the-fly bundle rewriting -- rewrites JS bundles in transit so backend URLs reference the proxy origin instead of localhost. No files are modified on disk.

## Architecture
The project consists of two main components:
## Proxy Server (proxy.js)
A single Node.js HTTP server that listens on a configurable port (default 8090) and routes incoming requests to local backends based on URL prefix matching. Routes are defined declaratively in proxy.env -- the longest prefix wins. The proxy handles host spoofing, CORS injection, and bundle rewriting transparently.
## ADB Bridge (tablet.sh)
A shell script that manages Android Debug Bridge (ADB) connections to one or more tablets. It sets up adb reverse tunnels so that each tablet sees localhost services as if they were running locally. Only one transport (USB or WiFi) is used per device to avoid tunnel contention.
## Prerequisites
The following services must be running on your development machine:

* Main application backend on port 80
* Secondary services or APIs on port 8000

System dependencies:

* Node.js -- runs the proxy server
* ADB (android-tools-adb) -- Android device bridge
* nmap -- automatic port scanning for WiFi reconnection
* curl -- health checks
* qrencode -- QR code generation for wireless pairing (optional)

## Configuration
All configuration is managed through environment files.
## proxy.env
Controls proxy behavior:

| Variable | Default | Description |
|---|---|---|
| PORT | 8090 | Port the proxy listens on |
| HOST_SPOOF | localhost | Host header value sent to backends |
| CORS | on | Enable or disable CORS header injection |
| ROUTE | see below | URL prefix to backend mapping (one per line) |

Default routes:

ROUTE /api   127.0.0.1:8000
ROUTE /      127.0.0.1:80

## devices.env
Registered Android devices. Format: name | serial | ip:port | type
## urls.env
Local URLs to expose on connected tablets (one per line). Ports below 1024 cannot be forwarded via ADB on Android without special permissions and must be accessed through the proxy.
## Usage## Start the proxy

./start.sh

This detects your LAN IP, prints the tablet access URL, and starts the proxy.
## Connect a tablet
Three exclusive connection modes are available: QR (wireless pairing), USB (permanent cable connection), or WiFi (reconnect to a known endpoint).

# First-time USB connection
./tablet.sh usb my-tablet
# First-time QR wireless pairing
./tablet.sh qr my-tablet
# Reconnect all registered devices
./tablet.sh

## Utility commands
These allow direct interaction with connected devices:

* ./tablet.sh status: Show connection status for all devices.
* ./tablet.sh url: Open URLs on tablets.
* ./tablet.sh clear: Clear Chrome cache, cookies, and service workers on the device.
* ./tablet.sh cap: Take a screenshot.
* ./tablet.sh logs: Live Chromium logcat stream.

## Access from tablet
Open the URL provided by the startup script in the tablet's browser:

http://<YOUR-LAN-IP>:8090/App/#/login

Because of the ADB reverse tunnel, the tablet processes localhost services as if they were running locally on its own system.
## How It Works## Request flow

Tablet Browser
      |
      v  http://192.168.x.x:8090/App/
Proxy (proxy.js)
      |
      +---> Backend A (Port :80)     Host header changed to "localhost"
      +---> Backend B (Port :8000)   Approved CORS headers injected
      +---> On-the-fly JS bundle rewrite
      |
      v  Modified response sent back
Tablet Browser

## ADB reverse tunnel
When the tablet connects via ADB, the adb reverse tcp:8090 tcp:8090 command creates a tunnel: any request the tablet makes to its own localhost:8090 is transparently forwarded to the proxy running on the development machine.

