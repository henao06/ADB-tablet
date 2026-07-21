#!/usr/bin/env bash
# Starts the responsiveness proxy.
# Detects the LAN IP, prints the EXACT URL for the tablet and, if 'qrencode'
# is available, a QR code you can scan with the tablet camera (iPad or Android).
set -e
cd "$(dirname "$0")/.."

command -v node >/dev/null 2>&1 || {
  echo "  [x] MISSING: node -> runs the proxy (proxy/proxy.js)."
  echo "      Fix it with:  sudo apt install -y nodejs"
  echo "      (see docs/DEPENDENCIES.txt to install everything at once)"
  exit 1
}

PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' config/proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
PORT="${PORT:-${PROXY_PORT:-8090}}"

IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
[ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<your-PC-IP>}"

URL="http://${IP}:${PORT}"

echo ""
echo "  =================================================================="
echo "    Paste / scan on the tablet (iPad or Android):"
echo ""
echo "      $URL"
echo "  =================================================================="
echo ""

if command -v qrencode >/dev/null 2>&1; then
  echo "  Scan this QR with the tablet camera and it opens by itself:"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$URL"
  echo ""
else
  echo "  [!] OPTIONAL missing: qrencode -> prints a scannable QR for the tablet."
  echo "      Install it with:  sudo apt install -y qrencode   and run ./sh/start.sh again"
  echo ""
fi

exec node proxy/proxy.js
