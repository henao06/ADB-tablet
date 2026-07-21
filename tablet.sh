#!/usr/bin/env bash
# ==========================================================================
# tablet.sh — View your LOCAL projects on one or SEVERAL (Android) tablets.
#
# THREE CONNECTION MODES, separate and EXCLUSIVE (one tablet, ONE transport):
#
#   ./tablet.sh qr     [name]  -> enrolls/connects via QR (wireless pairing) -> WiFi
#   ./tablet.sh usb    [name]  -> connects via CABLE (permanent cable)       -> USB
#   ./tablet.sh wifi   [name]  -> connects to an already known WiFi endpoint -> WiFi
#
#   ./tablet.sh use            -> interactive menu: pick a tablet and/or change its type
#   ./tablet.sh status         -> shows each tablet and HOW it is connected
#   ./tablet.sh cap    [name]  -> screenshot to /tmp with timestamp
#   ./tablet.sh url            -> pick URL(s) + tablet(s) + browser and open them
#   ./tablet.sh clear          -> clears Chrome cache/cookies/service-worker
#   ./tablet.sh stop           -> closes Chrome
#   ./tablet.sh logs   [name]  -> live Chromium logcat
#   ./tablet.sh rec    [name]  -> records the screen to /tmp (Ctrl+C to stop)
#   ./tablet.sh                -> reconnects ALL tablets according to their saved type
#   ./tablet.sh setup          -> installs every missing dependency (apt/dnf/pacman)
#
# Why "one transport at a time": the `adb reverse` tunnel is BOUND to ONE
# transport. If USB and WiFi are connected at the same time, the reverse sticks
# to USB (UsbFfs) and dies when the cable is unplugged. Each mode clears the
# tablet's reverses and registers the tunnel on a SINGLE serial. This makes
# the double-transport problem impossible by design.
#
# Config:
#   devices.env -> tablets:  name | serial | ip:port | type   (type = usb|wifi)
#   urls.env    -> local URLs/ports to expose
#   proxy.env   -> proxy port
# ==========================================================================
set -uo pipefail
cd "$(dirname "$0")"
ENVF="devices.env"
URLF="urls.env"
PROXY_PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
PROXY_PORT="${PROXY_PORT:-8090}"
SCAN_RANGE="${SCAN_RANGE:-30000-65535}"
CHROME="${CHROME:-com.android.chrome}"

require() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "  [x] MISSING: $1 -> $2"
  echo "      Fix it with:  $3"
  return 1
}
suggest() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "  [!] OPTIONAL missing: $1 -> $2"
  echo "      Install it with:  $3"
}
check_adb_conflict() {
  local paths vers a
  paths="$(which -a adb 2>/dev/null | xargs -r -n1 realpath 2>/dev/null | sort -u)"
  [ -z "$paths" ] && return 0
  vers="$(while read -r a; do "$a" version 2>/dev/null | sed -n 's/.*Version \([^ ]*\).*/\1/p' | head -1; done <<<"$paths" | sort -u)"
  [ "$(grep -c . <<<"$vers")" -le 1 ] && return 0
  echo "  [!] WARNING: multiple adb versions are installed. They fight over the"
  echo "      adb server (port 5037): each client kills the other's server, which"
  echo "      causes 'protocol fault / connection reset' mid pairing/connect:"
  while read -r a; do
    echo "        $a  (Version $("$a" version 2>/dev/null | sed -n 's/.*Version \([^ ]*\).*/\1/p' | head -1))"
  done <<<"$paths"
  echo "      Fix it: keep ONE (the newest) and remove the rest, e.g.:"
  echo "        sudo apt remove -y adb android-tools-adb"
  echo ""
}
check_deps() {
  local ok=1
  require adb  "pairs/connects the tablet and creates the reverse tunnel" "sudo apt install -y android-tools-adb" || ok=0
  require node "runs the proxy (proxy.js) on port $PROXY_PORT"            "sudo apt install -y nodejs"            || ok=0
  require curl "health-checks that the proxy and the backends respond"    "sudo apt install -y curl"              || ok=0
  suggest nmap         "auto-reconnect: rescans the tablet when the adb port rotates" "sudo apt install -y nmap"
  suggest qrencode     "prints the QR to pair the tablet / open the app"              "sudo apt install -y qrencode"
  suggest avahi-browse "QR mode discovery (mDNS)"                                     "sudo apt install -y avahi-utils"
  check_adb_conflict
  if [ "$ok" = 0 ]; then
    echo ""
    echo "  Install EVERYTHING at once (see DEPENDENCIES.txt):"
    echo "      sudo apt update && sudo apt install -y nodejs android-tools-adb nmap curl qrencode"
    exit 1
  fi
}
mode_setup() {
  echo "  -- SETUP: install every dependency in one shot --"
  local mgr="" c p ok=1
  command -v apt >/dev/null 2>&1 && mgr=apt
  [ -z "$mgr" ] && command -v dnf >/dev/null 2>&1 && mgr=dnf
  [ -z "$mgr" ] && command -v pacman >/dev/null 2>&1 && mgr=pacman
  local -a pkgs=()
  for c in adb node curl nmap qrencode avahi-browse; do
    command -v "$c" >/dev/null 2>&1 && continue
    case "$mgr:$c" in
      apt:adb)             p=android-tools-adb ;;
      apt:avahi-browse)    p=avahi-utils ;;
      dnf:adb|pacman:adb)  p=android-tools ;;
      dnf:avahi-browse)    p=avahi-tools ;;
      pacman:avahi-browse) p=avahi ;;
      *:node)              p=nodejs ;;
      *)                   p="$c" ;;
    esac
    pkgs+=("$p")
  done
  if [ "${#pkgs[@]}" -eq 0 ]; then
    echo "  Everything is already installed:"
    for c in adb node curl nmap qrencode avahi-browse; do echo "    [OK] $c -> $(command -v "$c")"; done
    check_adb_conflict
    return 0
  fi
  echo "  Missing: ${pkgs[*]}"
  local cmd=""
  case "$mgr" in
    apt)    cmd="apt update && apt install -y ${pkgs[*]}" ;;
    dnf)    cmd="dnf install -y ${pkgs[*]}" ;;
    pacman) cmd="pacman -S --needed --noconfirm ${pkgs[*]}" ;;
    *)      echo "  [x] no supported package manager found (apt/dnf/pacman)."
            echo "      Install these manually: ${pkgs[*]}  (see DEPENDENCIES.txt)"
            return 1 ;;
  esac
  local SUDO="sudo"
  [ "$(id -u)" -eq 0 ] && SUDO=""
  if [ -n "$SUDO" ] && ! command -v sudo >/dev/null 2>&1; then
    echo "  [x] you are not root and 'sudo' is not available."
    echo "      Run the install as root, then re-run ./tablet.sh setup to verify:"
    echo "        su -c \"$cmd\""
    return 1
  fi
  echo "  Installing with $mgr (you may be asked for your password)..."
  if ! $SUDO sh -c "$cmd"; then
    echo "  [x] installation failed."
    echo "      If it was a permissions problem (sudo rejected your user), run it as root:"
    echo "        su -c \"$cmd\""
    echo "      or add your user to sudoers and retry:"
    echo "        su -c \"usermod -aG sudo $USER\"   (log out and back in, then ./tablet.sh setup)"
    return 1
  fi
  echo ""
  echo "  Verifying:"
  for c in adb node curl nmap qrencode avahi-browse; do
    command -v "$c" >/dev/null 2>&1 && echo "    [OK] $c" || { echo "    [x] $c still missing"; ok=0; }
  done
  check_adb_conflict
  [ "$ok" = 1 ] && echo "  Done. Enroll your first tablet with:  ./tablet.sh usb   or   ./tablet.sh qr"
}

case "${1:-}" in setup|help|-h|--help) : ;; *) check_deps ;; esac
[ -f "$ENVF" ] || printf '# name | serial | ip:port | type (usb|wifi)\n' > "$ENVF"
[ -f "$URLF" ] || printf '# Local URLs/ports to expose (one per line)\nhttp://localhost:%s/App/#/login\n' "$PROXY_PORT" > "$URLF"

env_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ENVF"; }
url_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$URLF"; }
trim()       { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }
hw_serial()  { adb -s "$1" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n'; }

extract_port() {
  local s; s="$(echo "$1" | tr -d '[:space:]')"
  if   [[ "$s" =~ :([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^[0-9]+$ ]];  then echo "$s"
  elif [[ "$s" =~ ^https ]];    then echo 443
  elif [[ "$s" =~ ^http ]];     then echo 80
  fi
}
exposed_ports() { url_lines | while read -r l; do extract_port "$l"; done | sort -un; }

device_field() {
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
is_registered() {
  env_lines | awk -F'|' -v s="$1" '{gsub(/[[:space:]]/,"",$2)} $2==s{f=1} END{exit !f}'
}
upsert_device() {
  local tmp; tmp="$(mktemp)"
  awk -F'|' -v nm="$1" -v s="$2" -v e="$3" -v tp="$4" '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    { ser=$2; gsub(/[[:space:]]/,"",ser)
      if (ser==s) { printf "%s | %s | %s | %s\n", nm, s, e, tp; found=1 }
      else print }
    END { if (!found) printf "%s | %s | %s | %s\n", nm, s, e, tp }' \
    "$ENVF" > "$tmp" && mv "$tmp" "$ENVF"
}

transport_for() {
  local d state _ hw
  while read -r d state _; do
    [ "$state" = "device" ] || continue
    case "$2" in
      usb) [[ "$d" == *:* ]] && continue ;;
      net) [[ "$d" == *:* ]] || continue ;;
    esac
    hw="$(hw_serial "$d")"
    [ "$hw" = "$1" ] && { echo "$d"; return 0; }
  done < <(adb devices | tail -n +2)
  return 1
}

clear_reverses() {
  local s
  for s in "$(transport_for "$1" usb)" "$(transport_for "$1" net)"; do
    [ -n "$s" ] && adb -s "$s" reverse --remove-all >/dev/null 2>&1
  done
}
forward_ports() {
  local p
  adb -s "$1" reverse --remove-all >/dev/null 2>&1
  for p in $(exposed_ports); do
    if [ "$p" -lt 1024 ]; then
      echo "        - $p SKIPPED (Android does not allow <1024; use the proxy)"; continue
    fi
    adb -s "$1" reverse tcp:$p tcp:$p >/dev/null 2>&1 \
      && echo "        - port $p OK" \
      || echo "        - port $p [x] failed"
  done
}
activate() {
  echo "   [OK] ${2:-?} via ${3}  ($1):"
  forward_ports "$1"
}

scan_connect() {
  command -v nmap >/dev/null 2>&1 || { echo "   [!] cannot rescan: nmap is missing (sudo apt install -y nmap)" >&2; return 1; }
  local ip="$2" port ep
  for port in $(nmap -Pn -p "$SCAN_RANGE" --open -T4 --min-rate 1000 -n "$ip" 2>/dev/null | grep -oE '^[0-9]+/tcp' | cut -d/ -f1); do
    ep="$ip:$port"; adb connect "$ep" >/dev/null 2>&1; sleep 1
    [ "$(hw_serial "$ep")" = "$1" ] && { echo "$ep"; return 0; }
    adb disconnect "$ep" >/dev/null 2>&1
  done
  return 1
}
device_wifi_ip() {
  local d="$1" ip
  ip="$(adb -s "$d" shell ip -f inet addr show wlan0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
  [ -z "$ip" ] && ip="$(adb -s "$d" shell ip route 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2}' | head -1)"
  echo "$ip"
}

ensure_proxy() {
  exposed_ports | grep -qx "$PROXY_PORT" || return 0
  if curl -s -o /dev/null --max-time 3 "http://localhost:$PROXY_PORT/App/"; then
    echo "  Proxy OK (:$PROXY_PORT)"; return 0
  fi
  echo "  Starting the proxy (:$PROXY_PORT)..."
  nohup node proxy.js >/tmp/responsive-proxy.log 2>&1 &
  sleep 1
  curl -s -o /dev/null --max-time 3 "http://localhost:$PROXY_PORT/App/" \
    && echo "  Proxy OK (:$PROXY_PORT)" || echo "  [!] proxy not responding (tail /tmp/responsive-proxy.log)"
}
print_urls() {
  echo ""
  echo "  =================================================================="
  if url_lines | grep -q .; then
    echo "    On the tablet (Chrome), open the SAME url as on your local machine:"
    url_lines | while read -r l; do echo "        $(trim "$l")"; done
  else
    echo "    [!] $URLF is empty -> add your local URLs there (one per line)"
    echo "        e.g.:  http://localhost:5173   or just a port like  3000"
    echo "        then run ./tablet.sh again to forward them."
  fi
  echo "  =================================================================="
}

registry_recs() {
  local name serial ep tipo
  while IFS='|' read -r name serial ep tipo; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; tipo="$(trim "${tipo:-}")"
    [ -z "$serial" ] && continue
    [ -z "$tipo" ] && tipo="wifi"
    echo "$name|$serial|$ep|$tipo"
  done < <(env_lines)
}
record_by_name() {
  registry_recs | awk -F'|' -v want="$1" '$1==want{print;exit}'
}
load_recs() {
  RECS=()
  local r
  while IFS= read -r r; do [ -n "$r" ] && RECS+=("$r"); done < <(registry_recs)
  [ "${#RECS[@]}" -gt 0 ]
}
print_recs_menu() {
  local i name serial ep tipo
  echo "  Registered tablets:" >&2
  for i in "${!RECS[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"${RECS[$i]}"
    printf "    %d) %-16s [%-4s]  %s\n" "$((i+1))" "$name" "$tipo" "$serial" >&2
  done
}

pick_device() {
  local sel
  load_recs || { echo "  (no tablets in $ENVF -> enroll with: ./tablet.sh qr  or  ./tablet.sh usb)" >&2; return 1; }
  print_recs_menu
  read -rp "  Pick a number: " sel
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#RECS[@]}" ]; then
    echo "  invalid selection." >&2; return 1
  fi
  echo "${RECS[$((sel-1))]}"
}

pick_devices() {
  local sel n out=0
  load_recs || { echo "  (no tablets in $ENVF)" >&2; return 1; }
  print_recs_menu
  read -rp "  Which ones? (numbers, e.g.: 1 2  or  'all'): " sel
  if [ "$sel" = "todos" ] || [ "$sel" = "all" ] || [ "$sel" = "*" ]; then
    printf '%s\n' "${RECS[@]}"; return 0
  fi
  sel="${sel//,/ }"
  for n in $sel; do
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#RECS[@]}" ]; then
      echo "${RECS[$((n-1))]}"; out=1
    else
      echo "  [!] ignoring '$n'" >&2
    fi
  done
  [ "$out" = 1 ] || return 1
}

find_mdns() {
  avahi-browse -rpt "$1" 2>/dev/null | awk -F';' -v n="${2:-}" '
    $1=="=" && $3=="IPv4" { if (n=="" || $4==n) { print $8" "$9; exit } }'
}
wait_mdns() {
  local start=$SECONDS r
  while [ $((SECONDS - start)) -lt "$3" ]; do
    r="$(find_mdns "$1" "$2")"; [ -n "$r" ] && { echo "$r"; return 0; }
    sleep 1
  done
  return 1
}
adb_mdns_connect() {
  adb mdns services 2>/dev/null | tr -d '\r' | awk '/_adb-tls-connect/{print $NF; exit}'
}
discover_connect_ep() {
  local e
  e="$(adb_mdns_connect)"
  [ -z "$e" ] && e="$(find_mdns '_adb-tls-connect._tcp' '' | awk 'NF==2{print $1":"$2}')"
  echo "$e"
}
try_connect_ep() {
  [ -n "$1" ] || return 1
  adb disconnect "$1" >/dev/null 2>&1
  adb connect "$1" >/dev/null 2>&1
  local i
  for i in 1 2 3 4; do
    sleep 1
    [ -n "$(hw_serial "$1")" ] && return 0
  done
  return 1
}
any_net_device() {
  local d
  for d in $(adb devices 2>/dev/null | awk '/\tdevice$/{print $1}' | grep ':'); do
    [ -n "$(hw_serial "$d")" ] && { echo "$d"; return 0; }
  done
  return 1
}
print_qr() {
  if command -v qrencode >/dev/null 2>&1; then
    qrencode -t ANSIUTF8 "$1"
  elif python3 -c 'import qrcode' >/dev/null 2>&1; then
    python3 -c "import qrcode; q=qrcode.QRCode(border=2); q.add_data('$1'); q.make(); q.print_ascii(invert=True)"
  else
    return 1
  fi
}
mode_qr() {
  command -v avahi-browse >/dev/null 2>&1 || { echo "  [x] MISSING: avahi-browse -> QR mode needs mDNS to discover the tablet"; echo "      Fix it with:  sudo apt install -y avahi-utils"; return 1; }
  local want_name="${1:-}"
  local rand name pass
  rand="$(tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c8)"; rand="${rand:-$$abcd}"
  name="debug-$rand"
  pass="$(tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c10)"; pass="${pass:-Pair123456}"
  echo "  -- QR MODE (wireless pairing) -> WiFi runtime --"
  echo "  adb in use: $(command -v adb)  ($(adb version | sed -n '2p'))"
  echo ""
  echo "  On the tablet:  Developer options -> Wireless debugging"
  echo "                  -> 'Pair device with QR code'  and scan this:"
  echo ""
  print_qr "WIFI:T:ADB;S:${name};P:${pass};;" || { echo "  [x] MISSING: no QR generator available (qrencode or python-qrcode)"; echo "      Fix it with:  sudo apt install -y qrencode"; return 1; }
  echo ""
  echo "  Waiting for the tablet via mDNS (up to 120s)..."
  local pe ip port
  pe="$(wait_mdns '_adb-tls-pairing._tcp' "$name" 120)"
  [ -z "$pe" ] && pe="$(find_mdns '_adb-tls-pairing._tcp' '')"
  [ -z "$pe" ] && { echo "  [x] no pairing service showed up. Retry the QR."; return 1; }
  ip="${pe% *}"; port="${pe#* }"
  echo "  Pairing at $ip:$port -> pairing..."
  adb pair "$ip:$port" "$pass" || { echo "  [x] adb pair failed (if it says 'protocol fault', adb is not the official one)."; return 1; }
  echo "  paired. Connecting automatically (mDNS + port scan, up to 3 rounds)..."
  local hw="" netser="" ep2 cport i round stale
  for round in 1 2 3; do
    for stale in $(adb devices 2>/dev/null | awk '{print $1}' | grep "^$ip:"); do
      adb disconnect "$stale" >/dev/null 2>&1
    done
    for i in 1 2 3; do
      ep2="$(discover_connect_ep)"
      if try_connect_ep "$ep2"; then netser="$ep2"; break 2; fi
      netser="$(any_net_device)" && break 2
      printf '.'
      sleep 1
    done
    if command -v nmap >/dev/null 2>&1; then
      echo ""
      echo "  round $round/3: scanning $ip for the adb connect port (nmap)..."
      for cport in $(nmap -Pn -p "$SCAN_RANGE" --open -T4 --min-rate 1000 -n "$ip" 2>/dev/null | grep -oE '^[0-9]+/tcp' | cut -d/ -f1); do
        echo "    trying $ip:$cport ..."
        if try_connect_ep "$ip:$cport"; then netser="$ip:$cport"; break 2; fi
        adb disconnect "$ip:$cport" >/dev/null 2>&1
      done
    fi
  done
  echo ""
  if [ -z "$netser" ]; then
    echo "  [x] paired OK, but could not auto-connect after 3 rounds. Usual causes:"
    echo "      - Wireless debugging got switched OFF on the tablet -> turn it back ON"
    echo "      - the tablet screen went to sleep -> keep it awake during enrollment"
    command -v nmap >/dev/null 2>&1 || echo "      - nmap is missing (needed on networks that block mDNS) -> sudo apt install -y nmap"
    echo "      Nothing to type: fix the above and just re-run  ./tablet.sh qr"
    return 1
  fi
  hw="$(hw_serial "$netser")"
  local nm; nm="$(device_field "$hw" name)"
  if [ -z "$nm" ]; then
    nm="$want_name"
    [ -z "$nm" ] && { read -rp "  Name for this tablet (e.g. big-tablet): " nm; }
    [ -z "$nm" ] && nm="device-$hw"
  fi
  upsert_device "$nm" "$hw" "$netser" "wifi"
  echo "  Registered: $nm | $hw | $netser | wifi"
  clear_reverses "$hw"
  activate "$netser" "$nm" "wifi"
}

mode_usb() {
  echo "  -- USB MODE (permanent cable) -> USB runtime --"
  echo "  adb in use: $(command -v adb)  ($(adb version | sed -n '2p'))"
  echo "  1) Plug the tablet in via USB and LEAVE the cable connected."
  echo "  2) Accept 'Allow USB debugging' (check 'always')."
  echo ""
  local d hw tries=0 warned=0
  echo "  Waiting for an authorized USB device..."
  while :; do
    d="$(adb devices | awk -F'\t' '$2=="device"{print $1}' | grep -v ':' | head -1)"
    [ -n "$d" ] && break
    if [ "$warned" = 0 ] && adb devices | grep -q 'unauthorized'; then
      echo "  [!] Showing 'unauthorized' -> accept the dialog on the tablet."; warned=1
    fi
    tries=$((tries+1)); [ "$tries" -ge 90 ] && { echo "  [x] no tablet showed up over USB (check it is a DATA cable, not charge-only)."; return 1; }
    sleep 1
  done
  hw="$(hw_serial "$d")"
  echo "  USB OK: $d  (serial $hw)"
  local netser; netser="$(transport_for "$hw" net)"
  [ -n "$netser" ] && { echo "  Disconnecting its WiFi ($netser) so the tunnel stays ONLY on the cable..."; adb disconnect "$netser" >/dev/null 2>&1; }
  local nm; nm="$(device_field "$hw" name)"
  if [ -z "$nm" ]; then
    nm="${1:-}"
    [ -z "$nm" ] && { read -rp "  Name for this tablet (e.g. big-tablet): " nm; }
    [ -z "$nm" ] && nm="device-$hw"
  fi
  upsert_device "$nm" "$hw" "$d" "usb"
  echo "  Registered: $nm | $hw | $d | usb"
  clear_reverses "$hw"
  activate "$d" "$nm" "usb"
  echo "        (leave the cable connected: in usb mode the tunnel travels over the cable)"
}

connect_wifi() {
  local name="$1" hw="$2" ep="$3" ip newep netser
  netser="$(transport_for "$hw" net)"
  if [ -n "$netser" ]; then echo "$netser"; return 0; fi
  ip="${ep%%:*}"
  if [ -n "$ep" ] && adb connect "$ep" >/dev/null 2>&1 && sleep 1 && [ "$(hw_serial "$ep")" = "$hw" ]; then
    echo "$ep"; return 0
  fi
  echo "   saved endpoint not responding. Scanning $ip ..." >&2
  newep="$(scan_connect "$hw" "$ip")"
  [ -n "$newep" ] && { echo "$newep"; return 0; }
  return 1
}
wifi_one() {
  local name="$1" hw="$2" ep="$3" netser usbser
  echo "  Connecting $name over WiFi ($ep) ..."
  netser="$(connect_wifi "$name" "$hw" "$ep")"
  if [ -z "$netser" ]; then
    echo "   [x] $name is unreachable (its IP probably changed, or Wireless debugging is off)."
    echo "       Nothing to type: re-enroll it with  ./tablet.sh qr $name"
    echo "       (tip: a DHCP reservation on the router keeps its IP fixed forever)"
    return 1
  fi
  usbser="$(transport_for "$hw" usb)"
  [ -n "$usbser" ] && echo "   [!] a USB cable is connected ($usbser). In WiFi mode you should unplug it."
  upsert_device "$name" "$hw" "$netser" "wifi"
  clear_reverses "$hw"
  activate "$netser" "$name" "wifi"
  return 0
}
mode_wifi() {
  echo "  -- WiFi MODE (known endpoint) -> WiFi runtime --"
  local rec name serial ep tipo
  if [ -n "${1:-}" ]; then
    rec="$(record_by_name "$1")"
    [ -z "$rec" ] && { echo "  [x] no tablet named '$1' in $ENVF (check with: ./tablet.sh status)"; return 1; }
  else
    rec="$(pick_device)" || return 1
  fi
  IFS='|' read -r name serial ep tipo <<<"$(echo "$rec" | tr -s ' ')"
  name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"
  wifi_one "$name" "$serial" "$ep"
}

mode_use() {
  local rec name serial ep tipo nuevo
  rec="$(pick_device)" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"
  echo "  Selected: $name  (current type: $tipo)"
  echo "    1) WiFi"
  echo "    2) USB (permanent cable)"
  read -rp "  Reconnect as [1/2] (enter = keep '$tipo'): " nuevo
  case "${nuevo:-}" in
    1) tipo="wifi" ;;
    2) tipo="usb" ;;
    "") : ;;
    *) echo "  invalid option."; return 1 ;;
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

mode_status() {
  echo "  --- Tablets ($ENVF) ---"
  local name serial ep tipo usbser netser estado
  while IFS='|' read -r name serial ep tipo; do
    usbser="$(transport_for "$serial" usb)"
    netser="$(transport_for "$serial" net)"
    if [ "$tipo" = "usb" ]; then
      [ -n "$usbser" ] && estado="CONNECTED (usb $usbser)" || estado="down (plug in the cable)"
    else
      [ -n "$netser" ] && estado="CONNECTED (wifi $netser)" || estado="down ($ep)"
    fi
    printf "    %-16s [%-4s]  %s  ->  %s\n" "$name" "$tipo" "$serial" "$estado"
    [ -n "$usbser" ] && [ -n "$netser" ] && echo "        [!] DOUBLE transport connected (usb+wifi). In $tipo mode only one is used."
  done < <(registry_recs)
  echo "  --- URLs to expose ($URLF) ---"; url_lines | while read -r l; do echo "    $(trim "$l")"; done
  echo "  --- adb devices ---"; adb devices | tail -n +2
}

reconnect_all() {
  local any=0 name serial ep tipo usbser
  while IFS='|' read -r name serial ep tipo; do
    any=1
    if [ "$tipo" = "usb" ]; then
      usbser="$(transport_for "$serial" usb)"
      if [ -z "$usbser" ]; then echo "  $name [usb]: cable not connected -> plug it in and run ./tablet.sh usb"; continue; fi
      local netser; netser="$(transport_for "$serial" net)"
      [ -n "$netser" ] && adb disconnect "$netser" >/dev/null 2>&1
      clear_reverses "$serial"
      activate "$usbser" "$name" "usb"
    else
      wifi_one "$name" "$serial" "$ep" || true
    fi
  done < <(registry_recs)
  [ "$any" = "1" ] || echo "  (no tablets in $ENVF -> enroll with ./tablet.sh qr  or  ./tablet.sh usb)"
}

mode_cap() {
  local d hw name ts out
  if [ -n "${1:-}" ]; then
    hw="$(record_by_name "$1" | cut -d'|' -f2)"
    [ -z "$hw" ] && { echo "  [x] no tablet '$1' in $ENVF"; return 1; }
    d="$(transport_for "$hw" usb)"; [ -z "$d" ] && d="$(transport_for "$hw" net)"
    [ -z "$d" ] && { echo "  [x] '$1' is not connected (run ./tablet.sh usb  or  wifi)"; return 1; }
    name="$1"
  else
    d="$(adb devices | awk '/\tdevice$/{print $1}' | head -1)"
    [ -z "$d" ] && { echo "  [x] no tablet connected."; return 1; }
    hw="$(hw_serial "$d")"; name="$(device_field "$hw" name)"; [ -z "$name" ] && name="tablet"
  fi
  ts="$(date +%Y%m%d-%H%M%S)"
  out="/tmp/${name}-${ts}.png"
  adb -s "$d" exec-out screencap -p > "$out" 2>/dev/null
  if [ -s "$out" ]; then echo "  screenshot -> $out"; else rm -f "$out"; echo "  [x] screenshot failed ($d)."; fi
}

KNOWN_BROWSERS="com.android.chrome|Chrome
org.mozilla.firefox|Firefox
com.brave.browser|Brave
com.microsoft.emmx|Edge
com.opera.browser|Opera
com.opera.mini.native|Opera Mini
com.sec.android.app.sbrowser|Samsung Internet
com.duckduckgo.mobile.android|DuckDuckGo
org.mozilla.focus|Firefox Focus
com.vivaldi.browser|Vivaldi
com.kiwibrowser.browser|Kiwi
com.UCMobile.intl|UC Browser
com.mi.globalbrowser|Mi Browser
com.huawei.browser|Huawei Browser
com.android.browser|AOSP Browser"

device_browsers() {
  local pkgs pkg label
  pkgs="$(adb -s "$1" shell pm list packages 2>/dev/null | tr -d '\r' | sed 's/^package://')"
  [ -z "$pkgs" ] && return 1
  while IFS='|' read -r pkg label; do
    [ -z "$pkg" ] && continue
    echo "$pkgs" | grep -qx "$pkg" && echo "$pkg|$label"
  done <<<"$KNOWN_BROWSERS"
}

pick_browser() {
  local -a bs=()
  local b i sel
  while IFS= read -r b; do [ -n "$b" ] && bs+=("$b"); done < <(device_browsers "$1")
  if [ "${#bs[@]}" -eq 0 ]; then
    echo "  [!] no known browser detected on this device -> using the system default" >&2
    echo ""; return 0
  fi
  echo "  Browsers available on this device:" >&2
  for i in "${!bs[@]}"; do
    printf "    %d) %-18s (%s)\n" "$((i+1))" "${bs[$i]#*|}" "${bs[$i]%%|*}" >&2
  done
  echo "    0) system default (let Android decide)" >&2
  read -rp "  Open with [1]: " sel
  sel="${sel:-1}"
  if [ "$sel" = "0" ]; then echo ""; return 0; fi
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#bs[@]}" ]; then
    echo "  [!] invalid choice -> using ${bs[0]#*|}" >&2; sel=1
  fi
  echo "${bs[$((sel-1))]%%|*}"
}

open_url() {
  if [ -n "$3" ]; then
    adb -s "$1" shell "am start -a android.intent.action.VIEW -d '$2' $3" >/dev/null 2>&1 && return 0
    echo "    [!] $3 refused the intent -> falling back to the system default" >&2
  fi
  adb -s "$1" shell "am start -a android.intent.action.VIEW -d '$2'" >/dev/null 2>&1
}

mode_url() {
  local -a urls=() picks=()
  local l i usel n url
  while read -r l; do l="$(trim "$l")"; [ -n "$l" ] && urls+=("$l"); done < <(url_lines)
  [ "${#urls[@]}" -eq 0 ] && { echo "  [x] no URLs in $URLF"; echo "      Add one per line (e.g. http://localhost:5173) and run ./tablet.sh again to forward it."; return 1; }
  echo "  URLs (from $URLF):"
  for i in "${!urls[@]}"; do printf "    %d) %s\n" "$((i+1))" "${urls[$i]}"; done
  read -rp "  Which ones to open? (numbers, e.g.: 1 3 4): " usel
  usel="${usel//,/ }"
  for n in $usel; do
    if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#urls[@]}" ]; then
      picks+=("${urls[$((n-1))]}")
    else
      echo "  [!] ignoring '$n' (out of range)"
    fi
  done
  [ "${#picks[@]}" -eq 0 ] && { echo "  you did not pick any valid URL."; return 1; }

  local -a recs=()
  local rec name serial ep tipo d opened=0 total=0
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick any device."; return 1; }

  local browser
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"
    d="$(transport_for "$serial" usb)"; [ -z "$d" ] && d="$(transport_for "$serial" net)"
    if [ -z "$d" ]; then echo "  [x] $name is not connected -> skipping"; continue; fi
    echo "  $name ($d):"
    browser="$(pick_browser "$d")"
    for url in "${picks[@]}"; do
      total=$((total+1))
      if open_url "$d" "$url" "$browser"; then
        echo "    OK  -> $url"; opened=$((opened+1))
      else
        echo "    [x] -> $url"
      fi
      sleep 1
    done
  done
  echo "  Done: $opened/$total opened."
}

resolve_transport() {
  local d; d="$(transport_for "$1" usb)"; [ -z "$d" ] && d="$(transport_for "$1" net)"; echo "$d"
}
one_device() {
  local rec
  if [ -n "${1:-}" ]; then
    rec="$(record_by_name "$1")"
    [ -z "$rec" ] && { echo "  [x] no tablet '$1' in $ENVF" >&2; return 1; }
    echo "$rec"
  else
    pick_device
  fi
}

mode_clear() {
  local -a recs=(); local rec name serial ep tipo d ok=0
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick a device."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name not connected -> skipping"; continue; }
    adb -s "$d" shell pm clear "$CHROME" >/dev/null 2>&1 \
      && { echo "  $name: Chrome cleared (cache + cookies + service worker)"; ok=$((ok+1)); } \
      || echo "  $name: [x] could not clear"
  done
  echo "  Done: $ok cleared."
}

mode_stop() {
  local -a recs=(); local rec name serial ep tipo d
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick a device."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep tipo <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name not connected -> skipping"; continue; }
    adb -s "$d" shell am force-stop "$CHROME" >/dev/null 2>&1 && echo "  $name: Chrome closed" || echo "  $name: [x] failed"
  done
}

mode_logs() {
  local rec name serial ep tipo d
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected."; return 1; }
  echo "  Chromium logs on $name (Ctrl+C to exit)..."
  adb -s "$d" logcat -v time | grep --line-buffered -iE 'chromium|console'
}

mode_rec() {
  local rec name serial ep tipo d ts remote out
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep tipo <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected."; return 1; }
  ts="$(date +%Y%m%d-%H%M%S)"; remote="/sdcard/rec-${ts}.mp4"; out="/tmp/${name}-${ts}.mp4"
  echo "  Recording $name ... (Ctrl+C to stop, max 180s)"
  trap ':' INT
  adb -s "$d" shell screenrecord "$remote"
  trap - INT
  sleep 2
  adb -s "$d" pull "$remote" "$out" >/dev/null 2>&1 && echo "  video -> $out" || echo "  [x] could not pull the video"
  adb -s "$d" shell rm -f "$remote" >/dev/null 2>&1
}

case "${1:-}" in
  setup)  mode_setup ;;
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
    echo "  [x] unknown command: '$1'"
    echo "      usage: ./tablet.sh [ setup | qr | usb | wifi | use | status | cap | url | clear | stop | logs | rec ]"
    exit 1 ;;
esac
