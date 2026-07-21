# Conventions

- **English only** — every string, message, doc, and identifier is neutral English (public project).
- **Header comments only** — code files carry one explanatory header block; no inline comments anywhere. The `tablet.sh` header doubles as the `help` output (`grep '^#'`), so keep its format and alignment.
- **Nothing hardcoded** — no fixed IPs, ports, device names, or paths in logic; configuration lives in `config/*.env` and environment overrides (`SCAN_RANGE`, `CHROME`, `REC_BITRATE`, `INSPECT_PORT`).
- **Never prompt for IPs/ports** — the scripts discover endpoints themselves (mDNS, then nmap scan). The only thing ever asked is a device name, and in the TUI it is asked via popup, not stdin.
- **Args over prompts** — every command must run fully non-interactively when its data is passed as arguments; interactive menus are the fallback for bare invocations only.
- **Errors include the fix** — every `[x]`/`[!]` message states the exact command that fixes the problem or the exact re-run to perform.
- **Registry is the source of truth** — `config/devices.env` is edited by the scripts (`upsert`) and by deleting lines; `rm` unenrolls, `off` never touches it.
