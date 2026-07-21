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
#   1) system packages : adb, node, curl, nmap, qrencode, avahi (apt/dnf/pacman)
#   2) Rust toolchain  : official rustup installer, non-interactive, minimal
#   3) console build   : cargo build --release in tablet-ui/
#   4) launcher        : symlink 'tab' into ~/.local/bin
#   5) verify          : every tool answers, or you get the exact fix command
# ==========================================================================
set -uo pipefail
cd "$(dirname "$0")"

NO_UI=0
[ "${1:-}" = "--no-ui" ] && NO_UI=1

step() { printf '\n==> %s\n' "$*"; }
fail() { printf '  [x] %s\n' "$*"; exit 1; }

[ "$(uname -s)" = "Linux" ] || fail "this toolkit runs on Linux only (detected: $(uname -s))"

if [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
  fail "run ./setup.sh as your normal user (it asks for sudo only when needed)"
fi

step "1/5 System dependencies"
MGR=""
command -v apt >/dev/null 2>&1 && MGR=apt
[ -z "$MGR" ] && command -v dnf >/dev/null 2>&1 && MGR=dnf
[ -z "$MGR" ] && command -v pacman >/dev/null 2>&1 && MGR=pacman
PKGS=()
for c in adb node curl nmap qrencode avahi-browse; do
  command -v "$c" >/dev/null 2>&1 && continue
  case "$MGR:$c" in
    apt:adb)             p=android-tools-adb ;;
    apt:avahi-browse)    p=avahi-utils ;;
    dnf:adb|pacman:adb)  p=android-tools ;;
    dnf:avahi-browse)    p=avahi-tools ;;
    pacman:avahi-browse) p=avahi ;;
    *:node)              p=nodejs ;;
    *)                   p="$c" ;;
  esac
  PKGS+=("$p")
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
  SUDO="sudo"
  [ "$(id -u)" -eq 0 ] && SUDO=""
  if [ -n "$SUDO" ] && ! command -v sudo >/dev/null 2>&1; then
    fail "you are not root and 'sudo' is missing. Run as root:  su -c \"$CMD\"  then re-run ./setup.sh"
  fi
  $SUDO sh -c "$CMD" || fail "package install failed. If sudo rejected you, run as root:  su -c \"$CMD\"  then re-run ./setup.sh"
fi

if [ "$NO_UI" = 0 ]; then
  step "2/5 Rust toolchain"
  if command -v cargo >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo" ]; then
    echo "  Rust already installed."
  else
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain stable \
      || fail "rustup failed (check your network and re-run ./setup.sh)"
  fi
  export PATH="$HOME/.cargo/bin:$PATH"

  step "3/5 Building the terminal console"
  (cd tablet-ui && cargo build --release) || fail "console build failed (re-run ./setup.sh; report the error above if it persists)"

  step "4/5 Installing the 'tab' launcher"
  mkdir -p "$HOME/.local/bin"
  ln -sf "$(pwd)/tablet-ui/target/release/tablet-ui" "$HOME/.local/bin/tab"
  echo "  ~/.local/bin/tab -> tablet-ui/target/release/tablet-ui"
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "  [!] ~/.local/bin is not in your PATH. Add this line to your shell config:"
       echo "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
  esac
else
  step "2/5 Rust toolchain — skipped (--no-ui)"
  step "3/5 Console build — skipped (--no-ui)"
  step "4/5 Launcher — skipped (--no-ui)"
fi

step "5/5 Verifying"
OK=1
for c in adb node curl nmap qrencode avahi-browse; do
  command -v "$c" >/dev/null 2>&1 && echo "  [OK] $c" || { echo "  [x] $c still missing"; OK=0; }
done
if [ "$NO_UI" = 0 ]; then
  [ -x tablet-ui/target/release/tablet-ui ] && echo "  [OK] tablet-ui console" || { echo "  [x] console binary missing"; OK=0; }
  [ -L "$HOME/.local/bin/tab" ] && echo "  [OK] 'tab' launcher" || { echo "  [x] 'tab' launcher missing"; OK=0; }
fi
VERS="$(which -a adb 2>/dev/null | xargs -r -n1 realpath 2>/dev/null | sort -u | wc -l)"
[ "$VERS" -gt 1 ] && { echo "  [!] multiple adb installs detected -> keep ONE (sudo apt remove -y adb android-tools-adb)"; }

if [ "$OK" = 1 ]; then
  echo ""
  echo "  Done. Next steps:"
  echo "    ./tablet.sh usb my-tablet     enroll over USB cable"
  echo "    ./tablet.sh qr  my-tablet     enroll wirelessly via QR"
  [ "$NO_UI" = 0 ] && echo "    tab                           open the interactive console"
  exit 0
fi
echo ""
echo "  Some tools are still missing — fix the lines marked [x] above and re-run ./setup.sh"
exit 1
