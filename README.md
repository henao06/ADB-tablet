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
Proxy (proxy/proxy.js, default :8090)
      ├──►  ROUTE /api  → 127.0.0.1:8000      Host header spoofed to "localhost"
      └──►  ROUTE /     → 127.0.0.1:80        CORS headers injected
```

- **`tablet.sh`** manages device enrollment and connections over ADB, and registers the reverse tunnels for every port listed in `config/urls.env`.
- **`proxy/proxy.js`** is a single-file Node.js HTTP proxy (no npm packages) that fans requests out to one or more local backends by URL prefix — longest prefix wins. It can also rewrite JS bundles in transit — an optional, app-specific transform that stays off unless you set `BUNDLE_REWRITE_FROM`/`BUNDLE_REWRITE_TO` in `config/proxy.env`; when enabled it patches only the matching bundles that contain the marker, and is a clean pass-through otherwise.
- **One transport per device, by design.** An `adb reverse` tunnel binds to a single transport. If USB and WiFi are connected simultaneously, the tunnel sticks to USB and dies when the cable is unplugged. Every mode cleans up existing tunnels and re-registers them on exactly one transport, so that failure mode cannot happen.

> **iOS note:** iPads/iPhones have no ADB. For those, run `./sh/start.sh` and open the printed `http://<your-lan-ip>:8090/...` URL (or scan its QR code) in Safari — same proxy, no tunnel.

## Quick start

```bash
git clone <repo-url> && cd ADB-tablet
./setup.sh                   # one shot: system deps + Rust + console + 'tab' launcher
./sh/tablet.sh usb my-tablet    # enroll over USB cable, or:
./sh/tablet.sh qr my-tablet     # enroll wirelessly via QR pairing
```

`./setup.sh` is idempotent — re-run it anytime; it installs only what is missing. Use `./setup.sh --no-ui` to skip the Rust toolchain and console (the shell scripts alone are fully functional).

Then open the same URL you use locally (e.g. `http://localhost:5173`) in the tablet's browser. Done.

Day-to-day, a single command reconnects everything:

```bash
./sh/tablet.sh                  # reconnects ALL enrolled devices per their saved type
```

## Platform support

**Linux only.** The host machine must run Linux (any distro with `apt`, `dnf` or `pacman`). macOS and native Windows are not supported — the scripts refuse to run there and tell you why.

On the device side it works with **any Android tablet or phone** with Developer Options enabled (QR pairing needs Android 11+). iPads/iPhones have no ADB — use `./sh/start.sh` and open the printed LAN URL in Safari.

## Requirements

| Tool | Purpose | Required |
|---|---|---|
| `adb` | device pairing, connections, reverse tunnels | yes |
| `node` | runs the proxy | yes |
| `curl` | health checks | yes |
| `nmap` | WiFi auto-reconnect when the ADB port rotates | recommended |
| `qrencode` | renders the pairing/access QR codes in the terminal | recommended |
| `avahi-utils` | mDNS discovery for QR pairing (`avahi-browse`) | recommended |

`./setup.sh` (also reachable as `./sh/tablet.sh setup`) detects your package manager (`apt`, `dnf`, or `pacman`) and installs **only what is missing**, then sets up Rust, builds the console and installs the `tab` launcher. Every run of `tablet.sh` also verifies dependencies and prints exactly what is absent and how to install it.

> **Warning:** keep a single `adb` installation. Two different versions (e.g. the distro package plus Google platform-tools) fight over the ADB server on port 5037 — each client kills the other's server, which surfaces as `protocol fault / connection reset` mid-pairing. The script detects this and warns at startup.

## Commands

### Connecting

| Command | Description |
|---|---|
| `./setup.sh` | Full installer: system deps + Rust + console + launcher (idempotent) |
| `./sh/tablet.sh qr [name]` | Enroll/connect via QR wireless pairing → WiFi |
| `./sh/tablet.sh usb [name]` | Enroll/connect via USB cable → USB |
| `./sh/tablet.sh wifi [name]` | Reconnect an enrolled device over WiFi |
| `./sh/tablet.sh use` | Interactive menu: pick a device and/or switch its transport |
| `./sh/tablet.sh` | Reconnect all enrolled devices per their saved type |
| `./sh/tablet.sh status` | Show every device and how it is connected |

QR enrollment relies on mDNS to discover the tablet for pairing, so `avahi-browse` (package `avahi-utils`) is recommended. After pairing it connects through up to three rounds of *stale-session cleanup → mDNS discovery → nmap port scan* against the IP learned during pairing, and never asks you to type an IP or port. On networks that block multicast, mDNS discovery may never resolve; QR pairing can then fail to complete, so QR mode warns you and points you to USB enrollment (`./sh/tablet.sh usb <name>`) instead of hard-failing.

### Operating

| Command | Description |
|---|---|
| `./sh/tablet.sh url [name url [pkg]]` | Pick URL(s), device(s) and a **browser** — it lists the browsers actually detected on each device (Chrome, Firefox, Brave, Mi Browser, …) and opens the URLs there. Fully scriptable: pass device, URL and optionally the browser package |
| `./sh/tablet.sh browsers [name]` | List the browsers detected on a device, one `package\|label` per line (intent handlers + known browsers + name matches — nothing hardcoded) |
| `./sh/tablet.sh size [preset]` | **Emulate other screens on one device**: `phone`, `phone-small`, `tablet-8`, `tablet-10`, `fold-open`, a custom `<WxH> <dpi>`, or `reset`. Uses `wm size`/`wm density` overrides — test every breakpoint with a single tablet |
| `./sh/tablet.sh rotate [name] <orient>` | **Rotate the screen** without touching the tablet: `portrait`, `landscape`, `left`/`right` (90° steps from the current orientation), or `reset` (re-enables auto-rotate). Locks auto-rotate off and sets `user_rotation` — omit the orientation for an interactive menu |
| `./sh/tablet.sh inspect [name]` | **Remote DevTools bridge**: forwards the device browser's DevTools socket so you get the full inspector (console, network, elements, screencast) via `chrome://inspect` or `http://localhost:9222/json` |
| `./sh/tablet.sh cap [name]` | Screenshot → `/tmp/<name>-<timestamp>.png` |
| `./sh/tablet.sh rec [name] [seconds]` | Screen recording → `/tmp` (Ctrl+C to stop, or auto-stop after `[seconds]`; bitrate via `REC_BITRATE`) |
| `./sh/tablet.sh logs [name]` | Live Chromium logcat stream |
| `./sh/tablet.sh clear` | Clear browser cache, cookies and service workers |
| `./sh/tablet.sh stop` | Force-stop the browser |
| `./sh/tablet.sh rm` | Pick device(s) and remove them from the registry (clears tunnels, disconnects) |
| `./sh/tablet.sh proxy <cmd>` | Proxy control: `start`, `stop`, `status`, `logs` |
| `./sh/tablet.sh off [name]` | **Tear down connections**: with a name, disconnect just that device (its tunnels and WiFi ADB session — proxy and ADB server stay up); without, everything — reverse tunnels, WiFi ADB sessions, the proxy, and the ADB server. Enrollment survives (`rm` is the one that unenrolls) |

`clear` and `stop` target Chrome by default; override with `CHROME=<package> ./sh/tablet.sh clear`.

Closing the console (or your terminal) does **not** drop anything — tunnels, WiFi ADB sessions, the proxy and the ADB server keep running in the background. When you want everything down for security or peace of mind, run `./sh/tablet.sh off`; reconnect later with `./sh/tablet.sh`.

## Interactive console (optional)

`tablet-ui/` contains a full-screen terminal console (Rust + ratatui) in the spirit of lazygit: a big "ADB Tablet" banner, a device panel with live connection state, an action panel with single-key shortcuts, and an **Output panel where command results stream live** — you never leave the console. Popups pick the URL, screen preset or screen orientation (`a` — portrait/landscape/left/right/reset), name a new device, `Esc` stops a running command (recordings are still pulled), and `1/2/3` open the env files in your `$EDITOR`. Quitting the console does **not** drop connections — the `s` action (Disconnect everything) runs `./sh/tablet.sh off` for that, `f` disconnects a single device, `r` reconnects every enrolled device, and `n` connects a single one. Device-targeted actions always ask which device in a popup, so the target is explicit and confirmed before anything runs.

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
./sh/tablet.sh ui        # builds on first run (needs the Rust toolchain), then launches
```

The shell scripts work fine without Rust; the console is a convenience layer.

## Configuration

Everything lives in three plain-text env files next to the scripts.

### `config/proxy.env` — proxy behavior

| Key | Default | Description |
|---|---|---|
| `PORT` | `8090` | Port the proxy listens on |
| `BIND` | `127.0.0.1` | Interface it binds to (`0.0.0.0` exposes it to the LAN — see the file's security note) |
| `HOST_SPOOF` | `localhost` | `Host` header sent to backends (empty = forward the original) |
| `CORS` | `on` | Inject permissive CORS headers (`off` to disable) |
| `CORS_ORIGIN` | — | Empty reflects the caller Origin without credentials; a single explicit origin enables credentials for it; `*` allows any origin without credentials |
| `DEFAULT_TARGET` | `127.0.0.1:80` | Fallback backend used only when no `ROUTE` lines are defined |
| `ROUTE <prefix> <host:port>` | — | Prefix → backend mapping, one per line; longest prefix wins |

```
ROUTE /api   127.0.0.1:3000
ROUTE /      127.0.0.1:5173
```

If no `ROUTE` lines are defined, the proxy serves a single `/` route pointing at `DEFAULT_TARGET` (default `127.0.0.1:80`). An optional, app-specific bundle rewrite is also available: set `BUNDLE_REWRITE_FROM`/`BUNDLE_REWRITE_TO` (and optionally `BUNDLE_MATCH`) in `config/proxy.env` to patch a marker inside matching JS bundles in transit; left unset, the proxy is a clean pass-through.

### `config/devices.env` — enrolled devices (source of truth)

```
name | serial | ip:port | type
```

- `serial` is the hardware serial (`ro.serialno`) — it never changes, so a device is recognized even after its IP or ADB port rotates.
- `ip:port` is the last known WiFi endpoint (ignored in USB mode).
- `type` is `usb` or `wifi`.

Devices self-register on successful enrollment. To remove one, delete its line.

### `config/urls.env` — what to expose

One local URL (or bare port number) per line. Every listed port gets an `adb reverse` tunnel on connect.

```
http://localhost:8090
http://localhost:5173
8080
```

> Ports below 1024 cannot be reverse-forwarded on Android. Serve those through the proxy instead (e.g. put port 80 behind a `ROUTE` and expose the proxy's high port).

### Environment overrides

| Variable | Default | Description |
|---|---|---|
| `SCAN_RANGE` | `30000-65535` | Port range nmap scans during WiFi reconnection |
| `CHROME` | `com.android.chrome` | Browser package used by `clear`/`stop`/`logs` |
| `REC_BITRATE` | device default | Bitrate for `rec` screen recordings (e.g. `8000000`) |
| `INSPECT_PORT` | `9222` | Local port the `inspect` DevTools bridge forwards to |

## Troubleshooting

**`protocol fault (couldn't read status): Connection reset by peer` during pairing**
Two `adb` installations are fighting over the server. Keep one: `sudo apt remove -y adb` (if you use Google platform-tools) or delete the manually installed copy. The startup check reports the conflicting paths and versions.

**QR pairing succeeds but the connection takes a while**
Your network is probably blocking mDNS multicast, so discovery falls back to an nmap port scan (~30–60 s). This is expected and automatic. A DHCP reservation for the device on your router makes every later reconnection instant.

**QR pairing never finds the tablet at all**
Pairing discovery itself is mDNS-based, so if the network blocks multicast the pairing service may never resolve and QR enrollment cannot complete. Enroll over USB instead: `./sh/tablet.sh usb <name>`.

**`wifi` says the device is unreachable**
Its IP changed or Wireless debugging was switched off. Re-enroll with `./sh/tablet.sh qr <name>` — and consider a DHCP reservation so it stops happening.

**The tablet shows stale content**
Almost always a service worker. Run `./sh/tablet.sh clear` and reload.

**`status` warns about a DOUBLE transport**
The device is connected over USB and WiFi at the same time. Unplug the cable (WiFi mode) or run `./sh/tablet.sh` to let the script normalize the tunnels.

## Project layout

```
setup.sh               one-shot installer (system deps + Rust + console + launcher)
sh/
  tablet.sh            device enrollment, connections, tunnels, device utilities
  start.sh             starts the proxy and prints/QRs the LAN access URL
config/
  proxy.env            proxy port, host spoofing, CORS, routes
  devices.env          enrolled devices registry
  urls.env             local URLs/ports to expose
proxy/
  proxy.js             zero-dependency HTTP proxy (Node.js)
docs/
  DEPENDENCIES.txt     dependency reference and concept primer
  commands.txt         one-page cheatsheet
context/               living project documentation (architecture, stack, decisions, conventions)
tablet-ui/             optional Rust terminal UI (menu wrapper around tablet.sh)
```
