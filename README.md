# ADB Tablet Proxy

A zero-dependency HTTP proxy and Android device bridge for Linux that exposes local development servers to tablets and phones on the same LAN. Test your work on real devices — with the exact same `localhost` URLs you use on your desktop.

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
./setup.sh                   # one shot: system deps + Rust + console + 'tab' launcher
./tablet.sh usb my-tablet    # enroll over USB cable, or:
./tablet.sh qr my-tablet     # enroll wirelessly via QR pairing
```

`./setup.sh` is idempotent — re-run it anytime; it installs only what is missing. Use `./setup.sh --no-ui` to skip the Rust toolchain and console (the shell scripts alone are fully functional).

Then open the same URL you use locally (e.g. `http://localhost:5173`) in the tablet's browser. Done.

Day-to-day, a single command reconnects everything:

```bash
./tablet.sh                  # reconnects ALL enrolled devices per their saved type
```

## Platform support

**Linux only.** The host machine must run Linux (any distro with `apt`, `dnf` or `pacman`). macOS and native Windows are not supported — the scripts refuse to run there and tell you why.

On the device side it works with **any Android tablet or phone** with Developer Options enabled (QR pairing needs Android 11+). iPads/iPhones have no ADB — use `./start.sh` and open the printed LAN URL in Safari.

## Requirements

| Tool | Purpose | Required |
|---|---|---|
| `adb` | device pairing, connections, reverse tunnels | yes |
| `node` | runs the proxy | yes |
| `curl` | health checks | yes |
| `nmap` | WiFi auto-reconnect when the ADB port rotates | recommended |
| `qrencode` | renders the pairing/access QR codes in the terminal | recommended |
| `avahi-utils` | mDNS discovery in QR mode | optional |

`./setup.sh` (also reachable as `./tablet.sh setup`) detects your package manager (`apt`, `dnf`, or `pacman`) and installs **only what is missing**, then sets up Rust, builds the console and installs the `tab` launcher. Every run of `tablet.sh` also verifies dependencies and prints exactly what is absent and how to install it.

> **Warning:** keep a single `adb` installation. Two different versions (e.g. the distro package plus Google platform-tools) fight over the ADB server on port 5037 — each client kills the other's server, which surfaces as `protocol fault / connection reset` mid-pairing. The script detects this and warns at startup.

## Commands

### Connecting

| Command | Description |
|---|---|
| `./setup.sh` | Full installer: system deps + Rust + console + launcher (idempotent) |
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
| `./tablet.sh size [preset]` | **Emulate other screens on one device**: `phone`, `phone-small`, `tablet-8`, `tablet-10`, `fold-open`, a custom `<WxH> <dpi>`, or `reset`. Uses `wm size`/`wm density` overrides — test every breakpoint with a single tablet |
| `./tablet.sh inspect [name]` | **Remote DevTools bridge**: forwards the device browser's DevTools socket so you get the full inspector (console, network, elements, screencast) via `chrome://inspect` or `http://localhost:9222/json` |
| `./tablet.sh cap [name]` | Screenshot → `/tmp/<name>-<timestamp>.png` |
| `./tablet.sh rec [name] [seconds]` | Screen recording → `/tmp` (Ctrl+C to stop, or auto-stop after `[seconds]`; bitrate via `REC_BITRATE`) |
| `./tablet.sh logs [name]` | Live Chromium logcat stream |
| `./tablet.sh clear` | Clear browser cache, cookies and service workers |
| `./tablet.sh stop` | Force-stop the browser |
| `./tablet.sh rm` | Pick device(s) and remove them from the registry (clears tunnels, disconnects) |
| `./tablet.sh proxy <cmd>` | Proxy control: `start`, `stop`, `status`, `logs` |
| `./tablet.sh off [name]` | **Tear down connections**: with a name, disconnect just that device (its tunnels and WiFi ADB session — proxy and ADB server stay up); without, everything — reverse tunnels, WiFi ADB sessions, the proxy, and the ADB server. Enrollment survives (`rm` is the one that unenrolls) |

`clear` and `stop` target Chrome by default; override with `CHROME=<package> ./tablet.sh clear`.

Closing the console (or your terminal) does **not** drop anything — tunnels, WiFi ADB sessions, the proxy and the ADB server keep running in the background. When you want everything down for security or peace of mind, run `./tablet.sh off`; reconnect later with `./tablet.sh`.

## Interactive console (optional)

`tablet-ui/` contains a full-screen terminal console (Rust + ratatui) in the spirit of lazygit: a big "ADB Tablet" banner, a device panel with live connection state, an action panel with single-key shortcuts, and an **Output panel where command results stream live** — you never leave the console. Popups pick the URL or screen preset, name a new device, `Esc` stops a running command (recordings are still pulled), and `1/2/3` open the env files in your `$EDITOR`. Quitting the console does **not** drop connections — the `s` action (Disconnect everything) runs `./tablet.sh off` for that, `f` disconnects a single device, `r` reconnects every enrolled device, and `n` connects a single one. Device-targeted actions always ask which device in a popup, so the target is explicit and confirmed before anything runs.

```
  ADB Tablet Proxy — 1 enrolled · 1 connected
┌ Devices ───────────────────┐ ┌ Actions ─────────────────────────┐
│ ● my-tablet [wifi] via ... │ │  r Reconnect all devices         │
│                            │ │  z Emulate a screen size         │
│                            │ │  i DevTools inspector bridge     │
└────────────────────────────┘ └──────────────────────────────────┘
  Tab/←/→ panels · j/k move · Enter run · hotkey = instant · q quit
```

It shells out to `tablet.sh` underneath. Enrollment happens fully in-console: `e` (USB) and `w` (QR) ask for the device name in a popup, then everything — the pairing QR code included — streams in the Output panel. Only the installer (`d` setup) suspends the console, runs in the plain terminal, and returns. One engine, two interfaces.

```bash
./tablet.sh ui        # builds on first run (needs the Rust toolchain), then launches
```

The shell scripts work fine without Rust; the console is a convenience layer.

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
setup.sh           one-shot installer (system deps + Rust + console + launcher)
tablet.sh          device enrollment, connections, tunnels, device utilities
proxy.js           zero-dependency HTTP proxy (Node.js)
start.sh           starts the proxy and prints/QRs the LAN access URL
proxy.env          proxy port, host spoofing, CORS, routes
devices.env        enrolled devices registry
urls.env           local URLs/ports to expose
DEPENDENCIES.txt   dependency reference and concept primer
commands.txt       one-page cheatsheet
tablet-ui/         optional Rust terminal UI (menu wrapper around tablet.sh)
```
