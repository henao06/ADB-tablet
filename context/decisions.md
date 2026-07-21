# Decisions (ADRs)

## 2026-07-21 — Browser choice: detection union + always-ask popup

- **Decision**: `browsers <name>` lists a device's browsers as the union of three live sources — http VIEW intent resolvers, installed packages matching the known-browser table, and installed packages named `*browser*` — labeled from the table when known. The TUI URL chain always ends with a browser popup (URL -> device -> browser); `url <name> <url> [pkg]` is the scriptable form.
- **Why**: MIUI hides non-default browsers from shell intent queries (only Chrome resolved while Mi Browser was installed), so single-source detection under-detects; the user wants to pick the browser explicitly every time.
- **Rejected**: intent query alone (under-detects on MIUI); the known-table alone (misses browsers not in the table); hardcoding any browser list as the only source.

## 2026-07-21 — In-console enrollment via popup + args, not an embedded PTY

- **Decision**: the TUI asks for the device name in a native popup, then runs `tablet.sh usb|qr <name>` non-interactively and streams the output (QR included, via ansi-to-tui).
- **Why**: `tablet.sh` flows are fully non-interactive once the name is an argument; a PTY layer would add complexity for zero capability.
- **Rejected**: embedded PTY (heavy, fragile resize/input handling); keeping Suspend mode for enrollment (drops the user to the raw terminal).

## 2026-07-21 — Device-targeted actions always show the device picker

- **Decision**: any action needing a target (`n`, `f`, `m`, `z`, `i`, `c`, `v`, `l`, `x`, `b`, URL open) opens the device-list popup whenever at least one device is enrolled — even with exactly one — and guards with the enroll hint at zero.
- **Why**: user wants to see and confirm the target explicitly before anything runs.
- **Rejected**: auto-run when exactly one device is enrolled (implemented first, reverted on user feedback); focusable Devices panel driving an implicit selection (removed from the Tab/arrow focus cycle for simpler navigation).

## 2026-07-21 — `is_net_serial` classifier instead of colon tests

- **Decision**: one helper decides whether an adb serial is a network connection: contains `:` OR matches `*._adb-tls-connect._tcp` / `*._adb._tcp`. Every transport test in `tablet.sh` uses it.
- **Why**: wireless-debugging mDNS serials have no colon; the old `[[ "$d" == *:* ]]` tests classified them as USB, so per-device disconnect missed them and enrollment wrote `type usb` for a WiFi device (real bug, reproduced live).
- **Rejected**: patching individual call sites with duplicated pattern checks.

## 2026-07-21 — Registry stores ip:port endpoints, never mDNS names

- **Decision**: `config/devices.env` endpoints are `ip:port`; `wifi_one` only upserts the live serial as endpoint when it has that shape, otherwise it keeps the previous saved endpoint.
- **Why**: the reconnect fallback derives the IP from the endpoint (`${ep%%:*}`) and nmap-scans it when the port rotates; an mDNS name breaks that, and this LAN blocks mDNS resolution, so ip:port is the only endpoint that self-heals.
- **Rejected**: storing the mDNS service name (only "stable" where mDNS actually resolves).

## 2026-07-21 — Entry scripts moved into sh/ (owner override)

- **Decision**: `tablet.sh` and `start.sh` live in `sh/`; both cd to the repo root on start, and every self-reference/doc says `./sh/tablet.sh`. `setup.sh` stays at root.
- **Why**: explicit owner preference, overriding the root-entry-point part of the layout ADR below.
- **Rejected**: reverting the move to keep root entry points (recommended, declined by owner).

## 2026-07-21 — Domain folder layout with root entry points

- **Decision**: `config/` (env files), `proxy/` (proxy.js), `docs/` (reference), `context/` (living docs); `tablet.sh`, `setup.sh`, `start.sh`, `README.md` stay at root.
- **Why**: folder-by-domain per engineering standards; the root scripts are the documented public contract (`./sh/tablet.sh ...`) and must not move.
- **Rejected**: moving the scripts into a `bin/` folder (breaks the public contract).
