#!/usr/bin/env bash
# ==========================================================================
# setup.sh — One-shot installer for the ADB Tablet Proxy toolkit.
#
#   ./setup.sh            -> system dependencies + Rust + terminal console
#   ./setup.sh --no-ui    -> system dependencies only (skip Rust/console)
#
# Idempotent: safe to re-run at any time, it installs only what is missing.
# Do NOT run the whole script with sudo — it asks for elevation only for
# the package manager step. Everything else stays in your user account.
#
# What it does, in order:
#   1) config files    : create config/ and seed devices.env, urls.env,
#                         proxy.env if absent (never overwrites existing ones)
#   2) system packages : adb, node, curl (required); nmap, qrencode, avahi
#                         (optional) via apt/dnf/pacman
#   3) Rust toolchain  : official rustup installer, non-interactive, minimal.
#                         Requires Cargo >= 1.78 (tablet-ui/Cargo.lock is
#                         lockfile v4); an older pre-installed toolchain is
#                         upgraded instead of being silently reused.
#   4) console build   : cargo build --release in tablet-ui/
#   5) launcher        : symlink 'tab' into ~/.local/bin
#   6) verify          : required tools must answer; optional tools only warn,
#                         each with the exact fix command
# ==========================================================================
set -uo pipefail
cd "$(dirname "$0")"

NO_UI=0
[ "${1:-}" = "--no-ui" ] && NO_UI=1

CARGO_MIN="1.78"

REQUIRED_TOOLS="adb node curl"
OPTIONAL_TOOLS="nmap qrencode avahi-browse"

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '  [x] %s\n' "$*"; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "this toolkit runs on Linux only (detected: $(uname -s))"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  fail "run ./setup.sh as your normal user (it asks for sudo only when needed)"
fi

MGR=""
command -v apt >/dev/null 2>&1 && MGR=apt
[ -z "$MGR" ] && command -v dnf >/dev/null 2>&1 && MGR=dnf
[ -z "$MGR" ] && command -v pacman >/dev/null 2>&1 && MGR=pacman

SUDO="sudo"
[ "$(id -u)" -eq 0 ] && SUDO=""

pkg_for() {
  case "$MGR:$1" in
    apt:adb)              echo adb ;;
    apt:avahi-browse)     echo avahi-utils ;;
    dnf:adb|pacman:adb)   echo android-tools ;;
    dnf:avahi-browse)     echo avahi-tools ;;
    pacman:avahi-browse)  echo avahi ;;
    *:node)               echo nodejs ;;
    *)                    echo "$1" ;;
  esac
}

install_cmd() {
  case "$MGR" in
    apt)    echo "${SUDO:+$SUDO }apt update && ${SUDO:+$SUDO }apt install -y $1" ;;
    dnf)    echo "${SUDO:+$SUDO }dnf install -y $1" ;;
    pacman) echo "${SUDO:+$SUDO }pacman -S --needed --noconfirm $1" ;;
    *)      echo "install '$1' with your package manager" ;;
  esac
}

cargo_ok() {
  local have want wmaj wmin hmaj hmin rest
  have="$("$1" --version 2>/dev/null | awk '{print $2}')"
  [ -n "$have" ] || return 1
  want="$CARGO_MIN"
  wmaj="${want%%.*}"; wmin="${want#*.}"; wmin="${wmin%%.*}"
  hmaj="${have%%.*}"; rest="${have#*.}"; hmin="${rest%%.*}"
  case "$hmaj:$hmin" in *[!0-9]*) return 1 ;; esac
  [ "$hmaj" -gt "$wmaj" ] && return 0
  [ "$hmaj" -eq "$wmaj" ] && [ "$hmin" -ge "$wmin" ] && return 0
  return 1
}

seed_file() {
  local path="$1" content="$2" line
  [ -f "$path" ] && { echo "  keeping existing $path"; return 0; }
  if printf '%s\n' "$content" > "$path" 2>/dev/null; then
    echo "  created $path"
  else
    echo "  [x] could not create $path (check permissions on $(pwd)/config)."
    echo "      Create it by hand with exactly this content:"
    printf '%s\n' "$content" | while IFS= read -r line; do echo "          $line"; done
    CONFIG_MANUAL=1
  fi
}

step "1/6 Config files"
CONFIG_MANUAL=0
if [ ! -d config ]; then
  mkdir -p config 2>/dev/null || {
    echo "  [x] could not create the config/ directory."
    echo "      Create it by hand:  mkdir -p \"$(pwd)/config\""
    CONFIG_MANUAL=1
  }
fi
if [ -d config ]; then
  if [ -f config/proxy.env ]; then
    echo "  keeping existing config/proxy.env"
  elif [ -f config/proxy.env.example ]; then
    if cp config/proxy.env.example config/proxy.env 2>/dev/null; then
      echo "  created config/proxy.env (from config/proxy.env.example)"
    else
      echo "  [x] could not create config/proxy.env (check permissions on $(pwd)/config)."
      echo "      Copy it by hand:  cp config/proxy.env.example config/proxy.env"
      CONFIG_MANUAL=1
    fi
  else
    seed_file "config/proxy.env" "$(printf '# Proxy configuration.\nPORT=8090\n')"
  fi
  PROXY_PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' config/proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
  PROXY_PORT="${PROXY_PORT:-8090}"
  seed_file "config/devices.env" "$(printf '# name | serial | ip:port | type (usb|wifi)\n')"
  seed_file "config/urls.env" "$(printf '# Local URLs/ports to expose (one per line)\nhttp://localhost:%s\n' "$PROXY_PORT")"
fi
[ "$CONFIG_MANUAL" = 1 ] && echo "  [!] finish the manual steps above, then re-run ./setup.sh"

step "2/6 System dependencies"
PKGS=()
for c in $REQUIRED_TOOLS $OPTIONAL_TOOLS; do
  command -v "$c" >/dev/null 2>&1 && continue
  PKGS+=("$(pkg_for "$c")")
done
if [ "${#PKGS[@]}" -eq 0 ]; then
  echo "  all system dependencies already installed."
else
  echo "  missing: ${PKGS[*]}"
  case "$MGR" in
    apt)    CMD="apt update && apt install -y ${PKGS[*]}" ;;
    dnf)    CMD="dnf install -y ${PKGS[*]}" ;;
    pacman) CMD="pacman -S --needed --noconfirm ${PKGS[*]}" ;;
    *)      fail "no supported package manager (apt/dnf/pacman). Install manually: ${PKGS[*]}" ;;
  esac
  if [ -n "$SUDO" ] && ! command -v sudo >/dev/null 2>&1; then
    fail "you are not root and 'sudo' is missing. Run as root:  su -c \"$CMD\"  then re-run ./setup.sh"
  fi
  $SUDO sh -c "$CMD" || fail "package install failed. If sudo rejected you, run as root:  su -c \"$CMD\"  then re-run ./setup.sh"
fi

if [ "$NO_UI" = 0 ]; then
  step "3/6 Rust toolchain"
  RUSTUP_INSTALL="curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable"
  CARGO_BIN=""
  command -v cargo >/dev/null 2>&1 && CARGO_BIN="cargo"
  [ -z "$CARGO_BIN" ] && [ -x "$HOME/.cargo/bin/cargo" ] && CARGO_BIN="$HOME/.cargo/bin/cargo"

  if [ -n "$CARGO_BIN" ] && cargo_ok "$CARGO_BIN"; then
    echo "  Rust ready ($("$CARGO_BIN" --version 2>/dev/null))."
  elif [ -n "$CARGO_BIN" ]; then
    echo "  Rust $("$CARGO_BIN" --version 2>/dev/null | awk '{print $2}') is too old (need >= $CARGO_MIN for tablet-ui/Cargo.lock v4)."
    if [ -x "$HOME/.cargo/bin/rustup" ]; then
      "$HOME/.cargo/bin/rustup" update stable \
        || fail "could not update Rust. Run:  \"\$HOME/.cargo/bin/rustup\" update stable  then re-run ./setup.sh"
      "$HOME/.cargo/bin/rustup" default stable >/dev/null 2>&1
    else
      echo "  installing an up-to-date toolchain via rustup..."
      eval "$RUSTUP_INSTALL" \
        || fail "rustup failed (check your network). Run:  $RUSTUP_INSTALL  then re-run ./setup.sh"
    fi
  else
    eval "$RUSTUP_INSTALL" \
      || fail "rustup failed (check your network). Run:  $RUSTUP_INSTALL  then re-run ./setup.sh"
  fi
  export PATH="$HOME/.cargo/bin:$PATH"

  step "4/6 Building the terminal console"
  (cd tablet-ui && cargo build --release) \
    || fail "console build failed. Confirm Rust >= $CARGO_MIN (run: cargo --version), then re-run ./setup.sh; report the error above if it persists"

  step "5/6 Installing the 'tab' launcher"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(pwd)/tablet-ui/target/release/tablet-ui" "$HOME/.local/bin/tab"
  echo "  ~/.local/bin/tab -> tablet-ui/target/release/tablet-ui"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  [!] ~/.local/bin is not in your PATH. Add this line to your shell config:"
       echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
else
  step "3/6 Rust toolchain — skipped (--no-ui)"
  step "4/6 Console build — skipped (--no-ui)"
  step "5/6 Launcher — skipped (--no-ui)"
fi

step "6/6 Verifying"
OK=1
for c in $REQUIRED_TOOLS; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [OK] $c"
  else
    echo "  [x] $c missing (required) -> $(install_cmd "$(pkg_for "$c")")"
    OK=0
  fi
done
for c in $OPTIONAL_TOOLS; do
  if command -v "$c" >/dev/null 2>&1; then
    echo "  [OK] $c"
  else
    echo "  [!] $c missing (optional) -> $(install_cmd "$(pkg_for "$c")")"
  fi
done
if [ "$NO_UI" = 0 ]; then
  [ -x tablet-ui/target/release/tablet-ui ] && echo "  [OK] tablet-ui console" || { echo "  [x] console binary missing -> re-run ./setup.sh"; OK=0; }
  [ -L "$HOME/.local/bin/tab" ] && echo "  [OK] 'tab' launcher" || { echo "  [x] 'tab' launcher missing -> re-run ./setup.sh"; OK=0; }
fi
VERS="$(which -a adb 2>/dev/null | xargs -r -n1 realpath 2>/dev/null | sort -u | wc -l)"
[ "$VERS" -gt 1 ] && echo "  [!] multiple adb installs detected -> keep only one on your PATH (remove duplicates from snap, /usr/local/bin, or a second package)"

if [ "$OK" = 1 ]; then
  echo ""
  echo "  Done. Next steps:"
  echo "    ./sh/tablet.sh usb my-tablet     enroll over USB cable"
  echo "    ./sh/tablet.sh qr  my-tablet     enroll wirelessly via QR"
  [ "$NO_UI" = 0 ] && echo "    tab                           open the interactive console"
  exit 0
fi
echo ""
echo "  Some required tools are still missing — run the fix command on each line marked [x] above, then re-run ./setup.sh"
exit 1
