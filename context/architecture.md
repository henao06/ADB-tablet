# Architecture

## Folder map

- `sh/tablet.sh` — public entry point: enrollment, connections, reverse tunnels, device utilities. All commands: `./sh/tablet.sh <cmd>` (the script cd's to the repo root).
- `setup.sh` (root) — public entry point: one-shot idempotent installer (system deps + Rust + console + `tab` launcher).
- `sh/start.sh` — starts the proxy standalone and prints/QRs the LAN URL (the no-ADB path, e.g. iPad).
- `config/` — the three plain-text env files: `devices.env` (registry, source of truth), `urls.env` (ports/URLs to expose), `proxy.env` (proxy port, routes, host spoof, CORS).
- `proxy/proxy.js` — zero-dependency Node.js HTTP proxy; resolves `config/proxy.env` relative to its own location (`__dirname/../config`).
- `docs/` — human reference: `DEPENDENCIES.txt` (dependency/concept primer), `commands.txt` (cheatsheet).
- `tablet-ui/` — Rust + ratatui full-screen console; a thin wrapper that shells out to `tablet.sh` and streams output. Binary: `tablet-ui/target/release/tablet-ui`, symlinked as `tab`.

## How the pieces fit

Tablet browser -> `adb reverse` tunnel (created by `tablet.sh` per port in `config/urls.env`) -> developer machine -> `proxy/proxy.js` (:8090 by default) -> local backends by URL prefix (longest prefix wins), with Host spoofing and CORS injection.

The TUI never implements device logic: every action runs `bash sh/tablet.sh <args>` non-interactively (args over prompts) and renders the streamed output; only `setup` suspends the console.

## Core design rule: one transport per tablet

An `adb reverse` tunnel binds to a single transport. If USB and WiFi are connected at once, the tunnel sticks to USB and dies when the cable is unplugged. Every mode clears existing reverses and re-registers them on exactly ONE serial, so the double-transport failure cannot happen. Network serials are classified by `is_net_serial` (ip:port or mDNS `_adb-tls-connect._tcp` forms), never by a bare colon test.
