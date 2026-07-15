#!/usr/bin/env bash
# ==========================================================================
# tablet.sh — Ver tus proyectos LOCALES en una o VARIAS tablets (Android).
#
# TRES MODOS DE CONEXION, separados y EXCLUSIVOS (una tablet, UN transporte):
#
#   ./tablet.sh qr     [nombre]  -> enrola/conecta por QR (pairing inalambrico) -> WiFi
#   ./tablet.sh usb    [nombre]  -> conecta por CABLE (cable permanente)        -> USB
#   ./tablet.sh wifi   [nombre]  -> conecta a un endpoint WiFi ya conocido      -> WiFi
#
#   ./tablet.sh use              -> menu interactivo: elegis tablet y/o cambias su tipo
#   ./tablet.sh status           -> muestra cada tablet y POR DONDE esta
#   ./tablet.sh cap    [nombre]  -> captura de pantalla a /tmp con timestamp
#   ./tablet.sh url              -> elegis URL(s) + tablet(s) y las abre en Chrome
#   ./tablet.sh clear            -> limpia cache/cookies/service-worker de Chrome
#   ./tablet.sh stop             -> cierra Chrome
#   ./tablet.sh logs   [nombre]  -> logcat de Chromium en vivo
#   ./tablet.sh rec    [nombre]  -> graba la pantalla a /tmp (Ctrl+C para parar)
#   ./tablet.sh                  -> reconecta TODAS segun el tipo guardado
#
# Por que "un transporte a la vez": el tunel `adb reverse` se ATA a UN transporte.
# Si USB y WiFi estan conectados a la vez, el reverse se pega al USB (UsbFfs) y al
# soltar el cable se muere. Cada modo limpia los reverses de la tablet y registra
# el tunel sobre UN SOLO serial. Asi el doble-transporte es imposible por diseno.
#
# Config:
#   devices.env -> tablets:  nombre | serial | ip:puerto | tipo   (tipo = usb|wifi)
#   urls.env    -> URLs/puertos locales a exponer
#   proxy.env   -> puerto del proxy
# ==========================================================================
set -uo pipefail
cd "$(dirname "$0")"
ENVF="devices.env"
URLF="urls.env"
PROXY_PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
PROXY_PORT="${PROXY_PORT:-8090}"
SCAN_RANGE="${SCAN_RANGE:-30000-65535}"
CHROME="${CHROME:-com.android.chrome}"

command -v adb >/dev/null 2>&1 || { echo "  [x] Falta adb: sudo apt install -y android-tools-adb"; exit 1; }
[ -f "$ENVF" ] || printf '# nombre | serial | ip:puerto | tipo (usb|wifi)\n' > "$ENVF"
[ -f "$URLF" ] || printf '# URLs/puertos locales a exponer (una por linea)\nhttp://localhost:%s/App/#/login\n' "$PROXY_PORT" > "$URLF"

# ---------- helpers base ----------
env_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ENVF"; }
url_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$URLF"; }
trim()       { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
hw_serial()  { adb -s "$1" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n'; }

extract_port() {  # url o puerto -> numero de puerto
  local s; s="$(echo "$1" | tr -d '[:space:]')"
  if   [[ "$s" =~ :([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^[0-9]+$ ]];  then echo "$s"
  elif [[ "$s" =~ ^https ]];    then echo 443
  elif [[ "$s" =~ ^http ]];     then echo 80
  fi
}
exposed_ports() { url_lines | while read -r l; do extract_port "$l"; done | sort -un; }

# ---------- registro de tablets (devices.env, 4 columnas con compat 3-col) ----------
# Devuelve un campo del registro de una tablet por su serial de hardware.
device_field() {  # $1=serial  $2=name|ep|tipo
  env_lines | awk -F'|' -v s="$1" -v f="$2" '
    { ser=$2; gsub(/[[:space:]]/,"",ser)
      if (ser==s) {
        n=$1; e=$3; t=$4
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",e)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",t)
        if (t=="") t="wifi"
        if      (f=="name") print n
        else if (f=="ep")   print e
        else                print t
        exit
      } }'
}
is_registered() {  # $1=serial -> 0 si esta en devices.env
  env_lines | awk -F'|' -v s="$1" '{gsub(/[[:space:]]/,"",$2)} $2==s{f=1} END{exit !f}'
}
upsert_device() {  # $1=name $2=serial $3=ep $4=tipo  (inserta o reemplaza por serial)
  local tmp; tmp="$(mktemp)"
  awk -F'|' -v nm="$1" -v s="$2" -v e="$3" -v tp="$4" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    { ser=$2; gsub(/[[:space:]]/,"",ser)
      if (ser==s) { printf "%s | %s | %s | %s\n", nm, s, e, tp; found=1 }
      else print }
    END { if (!found) printf "%s | %s | %s | %s\n", nm, s, e, tp }' \
    "$ENVF" > "$tmp" && mv "$tmp" "$ENVF"
}

# ---------- transportes (un serial por tipo, para un mismo hardware) ----------
transport_for() {  # $1=hw  $2=usb|net  -> serial conectado de ese tipo, o vacio
  local d state _ hw
  while read -r d state _; do
    [ "$state" = "device" ] || continue
    case "$2" in
      usb) [[ "$d" == *:* ]] && continue ;;   # USB = sin ':'
      net) [[ "$d" == *:* ]] || continue ;;   # WiFi = ip:puerto
    esac
    hw="$(hw_serial "$d")"
    [ "$hw" = "$1" ] && { echo "$d"; return 0; }
  done < <(adb devices | tail -n +2)
  return 1
}

# ---------- el corazon del fix: reverse sobre UN SOLO transporte ----------
clear_reverses() {  # $1=hw  -> borra los reverse en TODOS los transportes de esa tablet
  local s
  for s in "$(transport_for "$1" usb)" "$(transport_for "$1" net)"; do
    [ -n "$s" ] && adb -s "$s" reverse --remove-all >/dev/null 2>&1
  done
}
forward_ports() {  # $1=serial (el UNICO transporte elegido)
  local p
  adb -s "$1" reverse --remove-all >/dev/null 2>&1
  for p in $(exposed_ports); do
    if [ "$p" -lt 1024 ]; then
      echo "        - $p OMITIDO (Android no permite <1024; usa el proxy)"; continue
    fi
    adb -s "$1" reverse tcp:$p tcp:$p >/dev/null 2>&1 \
      && echo "        - puerto $p OK" \
      || echo "        - puerto $p [x] fallo"
  done
}
activate() {  # $1=serial-transporte  $2=name  $3=tipo
  echo "   [OK] ${2:-?} via ${3}  ($1):"
  forward_ports "$1"
}

scan_connect() {  # $1=hw $2=ip  -> reconecta escaneando puertos, imprime ip:puerto
  command -v nmap >/dev/null 2>&1 || return 1
  local ip="$2" port ep
  for port in $(nmap -Pn -p "$SCAN_RANGE" --open -T4 -n "$ip" 2>/dev/null | grep -oE '^[0-9]+/tcp' | cut -d/ -f1); do
    ep="$ip:$port"; adb connect "$ep" >/dev/null 2>&1; sleep 1
    [ "$(hw_serial "$ep")" = "$1" ] && { echo "$ep"; return 0; }
    adb disconnect "$ep" >/dev/null 2>&1
  done
  return 1
}
device_wifi_ip() {  # $1=serial USB -> ip WiFi de la tablet
  local d="$1" ip
  ip="$(adb -s "$d" shell ip -f inet addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
  [ -z "$ip" ] && ip="$(adb -s "$d" shell ip route 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
  echo "$ip"
}

# ---------- proxy ----------
ensure_proxy() {
  exposed_ports | grep -qx "$PROXY_PORT" || return 0
  if ! curl -s -o /dev/null --max-time 3 "http://localhost:$PROXY_PORT/App/"; then
    echo "  Levantando el proxy (:$PROXY_PORT)..."
    nohup node proxy.js >/tmp/responsive-proxy.log 2>&1 &
    sleep 1
  fi
  curl -s -o /dev/null --max-time 3 "http://localhost:$PROXY_PORT/App/" \
    && echo "  Proxy OK (:$PROXY_PORT)" || echo "  [!] proxy no responde (tail /tmp/responsive-proxy.log)"
}
print_urls() {
  echo ""
  echo "  =================================================================="
  echo "    En la tablet (Chrome), abri la MISMA url que en tu local:"
  url_lines | while read -r l; do echo "        $(trim "$l")"; done
  echo "  =================================================================="
}

# ---------- menu interactivo: elegir tablet ----------
pick_device() {  # imprime "name|serial|ep|tipo" del elegido (prompts a stderr)
  local name serial ep tipo i sel
  local -a recs=()
  while IFS='|' read -r name serial ep tipo; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; tipo="$(trim "${tipo:-}")"
    [ -z "$serial" ] && continue
    [ -z "$tipo" ] && tipo="wifi"
    recs+=("$name|$serial|$ep|$tipo")
  done < <(env_lines)
  if [ "${#recs[@]}" -eq 0 ]; then echo "  (no hay tablets en $ENVF -> enrola con: ./tablet.sh qr  o  ./tablet.sh usb)" >&2; return 1; fi
  echo "  Tablets registradas:" >&2
  for i in "${!recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"${recs[$i]}"
    printf "    %d) %-16s [%-4s]  %s\n" "$((i+1))" "$name" "$tipo" "$serial" >&2
  done
  read -rp "  Elegi numero: " sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#recs[@]}" ]; then
    echo "  seleccion invalida." >&2; return 1
  fi
  echo "${recs[$((sel-1))]}"
}

pick_devices() {  # imprime UNO o VARIOS "name|serial|ep|tipo" (uno por linea)
  local name serial ep tipo i sel n out=0
  local -a recs=()
  while IFS='|' read -r name serial ep tipo; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; tipo="$(trim "${tipo:-}")"
    [ -z "$serial" ] && continue
    [ -z "$tipo" ] && tipo="wifi"
    recs+=("$name|$serial|$ep|$tipo")
  done < <(env_lines)
  if [ "${#recs[@]}" -eq 0 ]; then echo "  (no hay tablets en $ENVF)" >&2; return 1; fi
  echo "  Tablets registradas:" >&2
  for i in "${!recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"${recs[$i]}"
    printf "    %d) %-16s [%-4s]  %s\n" "$((i+1))" "$name" "$tipo" "$serial" >&2
  done
  read -rp "  Cuales? (numeros, ej: 1 2  o  'todos'): " sel
  if [ "$sel" = "todos" ] || [ "$sel" = "all" ] || [ "$sel" = "*" ]; then
    printf '%s\n' "${recs[@]}"; return 0
  fi
  sel="${sel//,/ }"
  for n in $sel; do
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#recs[@]}" ]; then
      echo "${recs[$((n-1))]}"; out=1
    else
      echo "  [!] ignoro '$n'" >&2
    fi
  done
  [ "$out" = 1 ] || return 1
}

# =====================================================================
#  MODO QR  -> runtime WiFi
# =====================================================================
find_mdns() {   # $1=tipo  $2=nombre(opcional)  ->  "ip puerto"
  avahi-browse -rpt "$1" 2>/dev/null | awk -F';' -v n="${2:-}" '
    $1=="=" && $3=="IPv4" { if (n=="" || $4==n) { print $8" "$9; exit } }'
}
wait_mdns() {   # $1=tipo  $2=nombre  $3=timeout_seg  ->  "ip puerto"
  local t=0 r
  while [ "$t" -lt "$3" ]; do
    r="$(find_mdns "$1" "$2")"; [ -n "$r" ] && { echo "$r"; return 0; }
    sleep 1; t=$((t+1))
  done
  return 1
}
print_qr() {    # $1=texto
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$1"
  elif python3 -c 'import qrcode' >/dev/null 2>&1; then
    python3 -c "import qrcode; q=qrcode.QRCode(border=2); q.add_data('$1'); q.make(); q.print_ascii(invert=True)"
  else
    return 1
  fi
}
mode_qr() {  # $1=nombre(opcional)
  command -v avahi-browse >/dev/null 2>&1 || { echo "  [x] falta avahi (sudo apt install avahi-utils)"; return 1; }
  local want_name="${1:-}"
  local rand name pass
  rand="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c8)"; rand="${rand:-$$abcd}"
  name="debug-$rand"
  pass="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c10)"; pass="${pass:-Pair123456}"
  echo "  -- MODO QR (pairing inalambrico) -> runtime WiFi --"
  echo "  adb en uso: $(command -v adb)  ($(adb version | sed -n '2p'))"
  echo ""
  echo "  En la tablet:  Opciones de desarrollador -> Depuracion inalambrica"
  echo "                 -> 'Vincular dispositivo con codigo QR'  y escanea esto:"
  echo ""
  print_qr "WIFI:T:ADB;S:${name};P:${pass};;" || { echo "  [x] no hay generador de QR (qrencode o python-qrcode)"; return 1; }
  echo ""
  echo "  Esperando a la tablet por mDNS (hasta 120s)..."
  local pe ip port
  pe="$(wait_mdns '_adb-tls-pairing._tcp' "$name" 120)"
  [ -z "$pe" ] && pe="$(find_mdns '_adb-tls-pairing._tcp' '')"
  [ -z "$pe" ] && { echo "  [x] no aparecio ningun servicio de pairing. Reintenta el QR."; return 1; }
  ip="${pe% *}"; port="${pe#* }"
  echo "  Pairing en $ip:$port -> vinculando..."
  adb pair "$ip:$port" "$pass" || { echo "  [x] adb pair fallo (si dice 'protocol fault', el adb no es el oficial)."; return 1; }
  echo "  vinculado. Buscando servicio de conexion..."
  local ce cip cport d hw netser
  ce="$(wait_mdns '_adb-tls-connect._tcp' '' 30)"
  if [ -n "$ce" ]; then cip="${ce% *}"; cport="${ce#* }"; adb connect "$cip:$cport" >/dev/null 2>&1; sleep 1; fi
  # localizar el transporte de red recien conectado
  netser=""
  for d in $(adb devices | awk '/\tdevice$/{print $1}' | grep ':'); do
    hw="$(hw_serial "$d")"; [ -n "$hw" ] && { netser="$d"; break; }
  done
  [ -z "${hw:-}" ] && { echo "  [!] vinculado pero no conecto aun. Corre: ./tablet.sh wifi"; return 0; }
  local nm; nm="$(device_field "$hw" name)"
  if [ -z "$nm" ]; then
    nm="$want_name"
    [ -z "$nm" ] && { read -rp "  Nombre para esta tablet (ej tablet-grande): " nm; }
    [ -z "$nm" ] && nm="device-$hw"
  fi
  upsert_device "$nm" "$hw" "$netser" "wifi"
  echo "  Registrada: $nm | $hw | $netser | wifi"
  # un solo transporte: limpiar y reenviar SOLO por WiFi
  clear_reverses "$hw"
  activate "$netser" "$nm" "wifi"
}

# =====================================================================
#  MODO USB  -> runtime USB (cable permanente)
# =====================================================================
mode_usb() {  # $1=nombre(opcional)
  echo "  -- MODO USB (cable permanente) -> runtime USB --"
  echo "  adb en uso: $(command -v adb)  ($(adb version | sed -n '2p'))"
  echo "  1) Enchufa la tablet por USB y DEJA el cable puesto."
  echo "  2) Acepta 'Permitir depuracion por USB' (marca 'siempre')."
  echo ""
  local d hw tries=0 warned=0
  echo "  Esperando dispositivo USB autorizado..."
  while :; do
    d="$(adb devices | awk -F'\t' '$2=="device"{print $1}' | grep -v ':' | head -1)"
    [ -n "$d" ] && break
    if [ "$warned" = 0 ] && adb devices | grep -q 'unauthorized'; then
      echo "  [!] Aparece 'unauthorized' -> acepta el dialogo en la tablet."; warned=1
    fi
    tries=$((tries+1)); [ "$tries" -ge 90 ] && { echo "  [x] no aparecio tablet por USB (revisa cable de DATOS, no solo carga)."; return 1; }
    sleep 1
  done
  hw="$(hw_serial "$d")"
  echo "  USB OK: $d  (serial $hw)"
  # exclusividad: si hay un transporte WiFi de la misma tablet, lo SACAMOS
  local netser; netser="$(transport_for "$hw" net)"
  [ -n "$netser" ] && { echo "  Desconectando su WiFi ($netser) para que el tunel quede SOLO en el cable..."; adb disconnect "$netser" >/dev/null 2>&1; }
  local nm; nm="$(device_field "$hw" name)"
  if [ -z "$nm" ]; then
    nm="${1:-}"
    [ -z "$nm" ] && { read -rp "  Nombre para esta tablet (ej tablet-grande): " nm; }
    [ -z "$nm" ] && nm="device-$hw"
  fi
  upsert_device "$nm" "$hw" "$d" "usb"
  echo "  Registrada: $nm | $hw | $d | usb"
  clear_reverses "$hw"
  activate "$d" "$nm" "usb"
  echo "        (deja el cable puesto: en modo usb el tunel viaja por el cable)"
}

# =====================================================================
#  MODO WIFI  -> runtime WiFi (endpoint ya conocido)
# =====================================================================
connect_wifi() {  # $1=name $2=serial $3=ep  -> imprime el serial de red conectado, o vacio
  local name="$1" hw="$2" ep="$3" ip newep netser
  netser="$(transport_for "$hw" net)"
  if [ -n "$netser" ]; then echo "$netser"; return 0; fi    # ya conectado por WiFi
  ip="${ep%%:*}"
  if [ -n "$ep" ] && adb connect "$ep" >/dev/null 2>&1 && sleep 1 && [ "$(hw_serial "$ep")" = "$hw" ]; then
    echo "$ep"; return 0
  fi
  echo "   endpoint guardado no responde. Escaneando $ip ..." >&2
  newep="$(scan_connect "$hw" "$ip")"
  [ -n "$newep" ] && { echo "$newep"; return 0; }
  return 1
}
wifi_one() {  # $1=name $2=serial $3=ep
  local name="$1" hw="$2" ep="$3" netser usbser
  echo "  Conectando $name por WiFi ($ep) ..."
  netser="$(connect_wifi "$name" "$hw" "$ep")"
  if [ -z "$netser" ]; then
    echo "   [!] no lo encontre (cambio la IP?). En la tablet: Depuracion inalambrica -> 'Direccion IP y puerto'."
    read -rp "       Nuevo IP:PUERTO de $name (vacio = saltar): " NEW
    [ -z "${NEW:-}" ] && { echo "   saltado."; return 1; }
    adb connect "$NEW" >/dev/null 2>&1; sleep 1
    [ "$(hw_serial "$NEW")" = "$hw" ] || { echo "   [x] no conecto a $NEW (re-vincula: ./tablet.sh qr)."; return 1; }
    netser="$NEW"
  fi
  # exclusividad: avisar si hay cable puesto (modo wifi quiere SOLO la red)
  usbser="$(transport_for "$hw" usb)"
  [ -n "$usbser" ] && echo "   [!] hay un cable USB conectado ($usbser). En modo WiFi conviene desenchufarlo."
  upsert_device "$name" "$hw" "$netser" "wifi"
  clear_reverses "$hw"
  activate "$netser" "$name" "wifi"
  return 0
}
mode_wifi() {  # $1=nombre(opcional)
  echo "  -- MODO WiFi (endpoint conocido) -> runtime WiFi --"
  local rec name serial ep tipo
  if [ -n "${1:-}" ]; then
    # buscar por nombre
    rec="$(env_lines | awk -F'|' -v want="$1" '
      { n=$1; gsub(/^[[:space:]]+|[[:space:]]+$/,"",n) }
      n==want { print; exit }')"
    [ -z "$rec" ] && { echo "  [x] no hay tablet llamada '$1' en $ENVF (vela con: ./tablet.sh status)"; return 1; }
  else
    rec="$(pick_device)" || return 1
  fi
  IFS='|' read -r name serial ep tipo <<<"$(echo "$rec" | tr -s ' ')"
  name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"
  wifi_one "$name" "$serial" "$ep"
}

# =====================================================================
#  USE  -> menu: elegir tablet y/o cambiar su tipo, y reconectar
# =====================================================================
mode_use() {
  local rec name serial ep tipo nuevo
  rec="$(pick_device)" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"
  echo "  Elegida: $name  (tipo actual: $tipo)"
  echo "    1) WiFi"
  echo "    2) USB (cable permanente)"
  read -rp "  Reconectar como [1/2] (enter = mantener '$tipo'): " nuevo
  case "${nuevo:-}" in
    1) tipo="wifi" ;;
    2) tipo="usb" ;;
    "") : ;;
    *) echo "  opcion invalida."; return 1 ;;
  esac
  ensure_proxy
  if [ "$tipo" = "usb" ]; then
    upsert_device "$name" "$serial" "$ep" "usb"
    mode_usb "$name"
  else
    wifi_one "$name" "$serial" "$ep"
  fi
  print_urls
}

# =====================================================================
#  STATUS  -> cada tablet y por donde esta
# =====================================================================
mode_status() {
  echo "  --- Tablets ($ENVF) ---"
  local name serial ep tipo usbser netser estado
  while IFS='|' read -r name serial ep tipo; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; tipo="$(trim "${tipo:-}")"
    [ -z "$serial" ] && continue
    [ -z "$tipo" ] && tipo="wifi"
    usbser="$(transport_for "$serial" usb)"
    netser="$(transport_for "$serial" net)"
    if [ "$tipo" = "usb" ]; then
      [ -n "$usbser" ] && estado="CONECTADA (usb $usbser)" || estado="caida (enchufa el cable)"
    else
      [ -n "$netser" ] && estado="CONECTADA (wifi $netser)" || estado="caida ($ep)"
    fi
    printf "    %-16s [%-4s]  %s  ->  %s\n" "$name" "$tipo" "$serial" "$estado"
    [ -n "$usbser" ] && [ -n "$netser" ] && echo "        [!] DOBLE transporte conectado (usb+wifi). En modo $tipo se usa solo uno."
  done < <(env_lines)
  echo "  --- URLs a exponer ($URLF) ---"; url_lines | while read -r l; do echo "    $(trim "$l")"; done
  echo "  --- adb devices ---"; adb devices | tail -n +2
}

# =====================================================================
#  Sin argumentos -> reconectar TODAS segun su tipo guardado
# =====================================================================
reconnect_all() {
  local any=0 name serial ep tipo usbser
  while IFS='|' read -r name serial ep tipo; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; tipo="$(trim "${tipo:-}")"
    [ -z "$serial" ] && continue
    [ -z "$tipo" ] && tipo="wifi"
    any=1
    if [ "$tipo" = "usb" ]; then
      usbser="$(transport_for "$serial" usb)"
      if [ -z "$usbser" ]; then echo "  $name [usb]: cable no conectado -> enchufalo y corre ./tablet.sh usb"; continue; fi
      # exclusividad
      local netser; netser="$(transport_for "$serial" net)"
      [ -n "$netser" ] && adb disconnect "$netser" >/dev/null 2>&1
      clear_reverses "$serial"
      activate "$usbser" "$name" "usb"
    else
      wifi_one "$name" "$serial" "$ep" || true
    fi
  done < <(env_lines)
  [ "$any" = "1" ] || echo "  (no hay tablets en $ENVF -> enrola con ./tablet.sh qr  o  ./tablet.sh usb)"
}

# =====================================================================
#  CAP  -> captura de pantalla a /tmp con timestamp
# =====================================================================
mode_cap() {  # $1=nombre(opcional)
  local d hw name ts out
  if [ -n "${1:-}" ]; then
    hw="$(env_lines | awk -F'|' -v want="$1" '{n=$1;gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)} n==want{s=$2;gsub(/[[:space:]]/,"",s);print s;exit}')"
    [ -z "$hw" ] && { echo "  [x] no hay tablet '$1' en $ENVF"; return 1; }
    d="$(transport_for "$hw" usb)"; [ -z "$d" ] && d="$(transport_for "$hw" net)"
    [ -z "$d" ] && { echo "  [x] '$1' no esta conectada (corre ./tablet.sh usb  o  wifi)"; return 1; }
    name="$1"
  else
    d="$(adb devices | awk '/\tdevice$/{print $1}' | head -1)"
    [ -z "$d" ] && { echo "  [x] no hay ninguna tablet conectada."; return 1; }
    hw="$(hw_serial "$d")"; name="$(device_field "$hw" name)"; [ -z "$name" ] && name="tablet"
  fi
  ts="$(date +%Y%m%d-%H%M%S)"
  out="/tmp/${name}-${ts}.png"
  adb -s "$d" exec-out screencap -p > "$out" 2>/dev/null
  if [ -s "$out" ]; then echo "  captura -> $out"; else rm -f "$out"; echo "  [x] fallo la captura ($d)."; fi
}

# =====================================================================
#  URL  -> abrir una URL de urls.env en una tablet (Chrome)
# =====================================================================
mode_url() {
  # 1) elegir UNA o VARIAS URLs (ej: 1 3 4  o  1,3,4)
  local -a urls=() picks=()
  local l i usel n url
  while read -r l; do l="$(trim "$l")"; [ -n "$l" ] && urls+=("$l"); done < <(url_lines)
  [ "${#urls[@]}" -eq 0 ] && { echo "  [x] no hay URLs en $URLF"; return 1; }
  echo "  URLs (de $URLF):"
  for i in "${!urls[@]}"; do printf "    %d) %s\n" "$((i+1))" "${urls[$i]}"; done
  read -rp "  Cuales abrir? (numeros, ej: 1 3 4): " usel
  usel="${usel//,/ }"   # comas -> espacios
  for n in $usel; do
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#urls[@]}" ]; then
      picks+=("${urls[$((n-1))]}")
    else
      echo "  [!] ignoro '$n' (fuera de rango)"
    fi
  done
  [ "${#picks[@]}" -eq 0 ] && { echo "  no elegiste ninguna URL valida."; return 1; }

  # 2) elegir UNO o VARIOS dispositivos
  local -a recs=()
  local rec name serial ep tipo d opened=0 total=0
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  no elegiste ningun dispositivo."; return 1; }

  # 3) abrir cada URL en cada dispositivo (Chrome, fallback al navegador por defecto)
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"
    d="$(transport_for "$serial" usb)"; [ -z "$d" ] && d="$(transport_for "$serial" net)"
    if [ -z "$d" ]; then echo "  [x] $name no esta conectada -> salteo"; continue; fi
    echo "  $name ($d):"
    for url in "${picks[@]}"; do
      total=$((total+1))
      if adb -s "$d" shell "am start -n com.android.chrome/com.google.android.apps.chrome.Main -d '$url'" >/dev/null 2>&1 \
         || adb -s "$d" shell "am start -a android.intent.action.VIEW -d '$url'" >/dev/null 2>&1; then
        echo "    OK  -> $url"; opened=$((opened+1))
      else
        echo "    [x] -> $url"
      fi
      sleep 1   # respiro para que Chrome las abra como pestanas separadas
    done
  done
  echo "  Listo: $opened/$total abierta(s)."
}

resolve_transport() {  # $1=serial hw -> transporte conectado (usb o net), o vacio
  local d; d="$(transport_for "$1" usb)"; [ -z "$d" ] && d="$(transport_for "$1" net)"; echo "$d"
}
# resuelve un registro por nombre (o menu si no se pasa nombre); imprime "name|serial|ep|tipo"
one_device() {  # $1=nombre opcional
  local rec
  if [ -n "${1:-}" ]; then
    rec="$(env_lines | awk -F'|' -v want="$1" '{n=$1;gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)} n==want{print;exit}')"
    [ -z "$rec" ] && { echo "  [x] no hay tablet '$1' en $ENVF" >&2; return 1; }
    echo "$rec"
  else
    pick_device
  fi
}

# =====================================================================
#  CLEAR  -> limpia cache/cookies/service-worker de Chrome (uno o varios)
# =====================================================================
mode_clear() {
  local -a recs=(); local rec name serial ep tipo d ok=0
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  no elegiste dispositivo."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name no conectada -> salteo"; continue; }
    adb -s "$d" shell pm clear "$CHROME" >/dev/null 2>&1 \
      && { echo "  $name: Chrome limpiado (cache + cookies + service worker)"; ok=$((ok+1)); } \
      || echo "  $name: [x] no pude limpiar"
  done
  echo "  Listo: $ok limpiada(s)."
}

# =====================================================================
#  STOP  -> cierra Chrome (uno o varios)
# =====================================================================
mode_stop() {
  local -a recs=(); local rec name serial ep tipo d
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  no elegiste dispositivo."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name no conectada -> salteo"; continue; }
    adb -s "$d" shell am force-stop "$CHROME" >/dev/null 2>&1 && echo "  $name: Chrome cerrado" || echo "  $name: [x] fallo"
  done
}

# =====================================================================
#  LOGS  -> logcat de Chromium en vivo (un dispositivo)
# =====================================================================
mode_logs() {  # $1=nombre opcional
  local rec name serial ep tipo d
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name no conectada."; return 1; }
  echo "  Logs de Chromium en $name (Ctrl+C para salir)..."
  adb -s "$d" logcat -v time | grep --line-buffered -iE 'chromium|console'
}

# =====================================================================
#  REC  -> graba la pantalla; Ctrl+C para parar; baja el mp4 a /tmp
# =====================================================================
mode_rec() {  # $1=nombre opcional
  local rec name serial ep tipo d ts remote out
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name no conectada."; return 1; }
  ts="$(date +%Y%m%d-%H%M%S)"; remote="/sdcard/rec-${ts}.mp4"; out="/tmp/${name}-${ts}.mp4"
  echo "  Grabando $name ... (Ctrl+C para parar, max 180s)"
  trap ':' INT                 # Ctrl+C corta la grabacion pero seguimos al pull
  adb -s "$d" shell screenrecord "$remote"
  trap - INT
  sleep 2                      # que el device cierre bien el mp4
  adb -s "$d" pull "$remote" "$out" >/dev/null 2>&1 && echo "  video -> $out" || echo "  [x] no pude bajar el video"
  adb -s "$d" shell rm -f "$remote" >/dev/null 2>&1
}

# =====================================================================
#  Dispatch
# =====================================================================
case "${1:-}" in
  qr)     mode_qr "${2:-}"   && { ensure_proxy; print_urls; } ;;
  usb)    mode_usb "${2:-}"  && { ensure_proxy; print_urls; } ;;
  wifi)   ensure_proxy; mode_wifi "${2:-}" && print_urls ;;
  use)    mode_use ;;
  status) mode_status ;;
  cap)    mode_cap "${2:-}" ;;
  url)    mode_url ;;
  clear)  mode_clear ;;
  stop)   mode_stop ;;
  logs)   mode_logs "${2:-}" ;;
  rec)    mode_rec "${2:-}" ;;
  "")     ensure_proxy; reconnect_all; print_urls ;;
  -h|--help|help)
    grep -E '^#( |=)' "$0" | sed -E 's/^# ?//' | head -40 ;;
  *)
    echo "  [x] comando desconocido: '$1'"
    echo "      uso: ./tablet.sh [ qr | usb | wifi | use | status | cap | url | clear | stop | logs | rec ]"
    exit 1 ;;
esac
