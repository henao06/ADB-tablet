# Stack

Versions live here and only here.

- **Bash** — `tablet.sh`, `setup.sh`, `start.sh` (Linux only; apt/dnf/pacman supported by the installer).
- **Node.js** — `proxy/proxy.js`, standard library only (`http`, `fs`, `path`); zero npm dependencies by design.
- **Rust 2021 edition** — `tablet-ui` v0.3.0, release profile with `strip` + `lto`.
  - `ratatui` 0.29
  - `tui-big-text` 0.7
  - `ansi-to-tui` 7
- **External CLI tools** — required: `adb`, `node`, `curl`; recommended: `nmap` (port-scan reconnect fallback), `qrencode` (pairing/access QR); optional: `avahi-browse` (mDNS discovery).
