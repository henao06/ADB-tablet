#!/usr/bin/env bash
# Arranca el proxy de responsividad.
# Detecta la IP de la LAN, muestra la URL EXACTA para la tablet y, si esta
# 'qrencode', un QR para abrirla escaneando con la camara (iPad o Android).
set -e
cd "$(dirname "$0")"

PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
PORT="${PORT:-${PROXY_PORT:-8090}}"

# IP de la LAN: la de la ruta por defecto (evita docker/vpn). Fallback: hostname -I
IP="$(ip route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}')"
[ -z "$IP" ] && IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
IP="${IP:-<IP-de-tu-PC>}"

URL="http://${IP}:${PORT}/App/#/login"

echo ""
echo "  =================================================================="
echo "    Pegar / escanear en la tablet (iPad o Android):"
echo ""
echo "      $URL"
echo "  =================================================================="
echo ""

if command -v qrencode >/dev/null 2>&1; then
  echo "  Escanea este QR con la camara de la tablet y se abre solo:"
  echo ""
  qrencode -t ANSIUTF8 -m 2 "$URL"
  echo ""
else
  echo "  (Para un QR escaneable instala qrencode una vez:"
  echo "      sudo apt install -y qrencode"
  echo "   y volve a correr ./start.sh)"
  echo ""
fi

exec node proxy.js
