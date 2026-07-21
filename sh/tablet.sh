#!/usr/bin/env bash
# ==========================================================================
# tablet.sh — View your LOCAL projects on one or SEVERAL (Android) tablets.
#
# THREE CONNECTION MODES, separate and EXCLUSIVE (one tablet, ONE transport):
#
#   ./sh/tablet.sh qr     [name]  -> enrolls/connects via QR (wireless pairing) -> WiFi
#   ./sh/tablet.sh usb    [name]  -> connects via CABLE (permanent cable)       -> USB
#   ./sh/tablet.sh wifi   [name]  -> connects to an already known WiFi endpoint -> WiFi
#
#   ./sh/tablet.sh use            -> interactive menu: pick a tablet and/or change its type
#   ./sh/tablet.sh status         -> shows each tablet and HOW it is connected
#   ./sh/tablet.sh cap    [name]  -> screenshot to /tmp with timestamp
#   ./sh/tablet.sh url [name url [pkg]] -> pick URL(s) + tablet(s) + browser and open them
#   ./sh/tablet.sh browsers [name] -> lists the browsers detected on the device
#   ./sh/tablet.sh clear          -> clears Chrome cache/cookies/service-worker
#   ./sh/tablet.sh stop           -> closes Chrome
#   ./sh/tablet.sh logs   [name]  -> live Chromium logcat
#   ./sh/tablet.sh rec  [name] [s] -> records the screen to /tmp (Ctrl+C or after [s] seconds)
#   ./sh/tablet.sh size   [preset] -> emulate other screen sizes (phone, fold, ...) or reset
#   ./sh/tablet.sh rotate [name] <orient> -> portrait | landscape | left | right | reset
#   ./sh/tablet.sh inspect [name] -> Chrome DevTools bridge for the device browser
#   ./sh/tablet.sh rm             -> pick device(s) and remove them from the registry
#   ./sh/tablet.sh proxy [cmd]    -> proxy control: start | stop | status | logs
#   ./sh/tablet.sh off    [name]  -> disconnects one tablet, or EVERYTHING (+proxy +adb)
#   ./sh/tablet.sh                -> reconnects ALL tablets according to their saved type
#   ./sh/tablet.sh setup          -> full installer (./setup.sh: deps + Rust + console)
#   ./sh/tablet.sh ui             -> full-screen interactive console (builds on first run)
#
# Why "one transport at a time": the `adb reverse` tunnel is BOUND to ONE
# transport. If USB and WiFi are connected at the same time, the reverse sticks
# to USB (UsbFfs) and dies when the cable is unplugged. Each mode clears the
# tablet's reverses and registers the tunnel on a SINGLE serial. This makes
# the double-transport problem impossible by design.
#
# Config (config/ folder):
#   config/devices.env -> tablets:  name | serial | ip:port | type  (usb|wifi)
#   config/urls.env    -> local URLs/ports to expose
#   config/proxy.env   -> proxy port
# ==========================================================================
set -uo pipefail
cd "$(dirname "$0")/.."
ENVF="config/devices.env"
URLF="config/urls.env"
PROXY_PORT="$(grep -E '^[[:space:]]*PORT[[:space:]]*=' config/proxy.env 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
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
  if [ "$(uname -s)" != "Linux" ]; then
    echo "  [x] this toolkit runs on Linux only (detected: $(uname -s))."
    exit 1
  fi
  local ok=1
  require adb  "pairs/connects the tablet and creates the reverse tunnel" "sudo apt install -y adb" || ok=0
  require node "runs the proxy (proxy/proxy.js) on port $PROXY_PORT"      "sudo apt install -y nodejs"            || ok=0
  require curl "health-checks that the proxy and the backends respond"    "sudo apt install -y curl"              || ok=0
  suggest nmap         "auto-reconnect: rescans the tablet when the adb port rotates" "sudo apt install -y nmap"
  suggest qrencode     "prints the QR to pair the tablet / open the app"              "sudo apt install -y qrencode"
  suggest avahi-browse "QR mode discovery (mDNS)"                                     "sudo apt install -y avahi-utils"
  if [ "$ok" = 0 ]; then
    echo ""
    echo "  Install EVERYTHING at once (deps + Rust + console, see docs/DEPENDENCIES.txt):"
    echo "      ./setup.sh"
    exit 1
  fi
}
case "${1:-}" in setup|help|-h|--help) : ;; *) check_deps ;; esac
[ -f "$ENVF" ] || printf '# name | serial | ip:port | type (usb|wifi)\n' > "$ENVF"
[ -f "$URLF" ] || printf '# Local URLs/ports to expose (one per line)\nhttp://localhost:%s\n' "$PROXY_PORT" > "$URLF"

env_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$ENVF"; }
url_lines()  { grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$URLF"; }
trim()       { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

ADB_TIMEOUT="${ADB_TIMEOUT:-10}"
TIMEOUT_BIN="$(command -v timeout || true)"
adbt() { if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$ADB_TIMEOUT" adb "$@"; else adb "$@"; fi; }

sq() { local q="${1//\'/\'\\\'\'}"; printf "'%s'" "$q"; }

valid_name() {
  local n="$1" ctx="${2:-usb}"
  case "$n" in
    -*)              echo "  [x] invalid name '$n': it cannot start with '-'." >&2
                     echo "      Use only letters, digits, '-' and '_':  ./sh/tablet.sh $ctx my-tablet" >&2; return 1 ;;
    *[!A-Za-z0-9_-]*) echo "  [x] invalid name '$n': only letters, digits, '-' and '_' are allowed." >&2
                     echo "      Fix it:  ./sh/tablet.sh $ctx my-tablet" >&2; return 1 ;;
  esac
  return 0
}

HWCACHE="${TMPDIR:-/tmp}/tablet-sh-hw.cache"
find "$HWCACHE" -mmin +60 -delete 2>/dev/null
hw_serial() {
  local id="$1" hw
  hw="$(awk -v i="$id" '$1==i{print $2;exit}' "$HWCACHE" 2>/dev/null)"
  if [ -z "$hw" ]; then
    hw="$(adbt -s "$id" shell getprop ro.serialno 2>/dev/null | tr -d '\r\n')"
    [ -n "$hw" ] && printf '%s %s\n' "$id" "$hw" >> "$HWCACHE"
  fi
  printf '%s\n' "$hw"
}

extract_port() {
  local s; s="$(echo "$1" | tr -d '[:space:]')"
  if [[ "$s" == *'['*']'* ]]; then
    if   [[ "$s" =~ \]:([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"
    elif [[ "$s" =~ ^https ]];      then echo 443
    elif [[ "$s" =~ ^http ]];       then echo 80
    fi
    return
  fi
  if   [[ "$s" =~ :([0-9]+) ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^[0-9]+$ ]];  then echo "$s"
  elif [[ "$s" =~ ^https ]];    then echo 443
  elif [[ "$s" =~ ^http ]];     then echo 80
  fi
}
exposed_ports() { url_lines | while read -r l; do extract_port "$l"; done | sort -un; }

device_field() {
  env_lines | S_="$1" F_="$2" awk -F'|' '
    { ser=$2; gsub(/[[:space:]]/,"",ser)
      if (ser==ENVIRON["S_"]) {
        n=$1; e=$3; t=$4
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",n)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",e)
        gsub(/^[[:space:]]+|[[:space:]]+$/,"",t)
        if (t=="") t="wifi"
        if      (ENVIRON["F_"]=="name") print n
        else if (ENVIRON["F_"]=="ep")   print e
        else                            print t
        exit
      } }'
}
is_registered() {
  env_lines | S_="$1" awk -F'|' '{gsub(/[[:space:]]/,"",$2)} $2==ENVIRON["S_"]{f=1} END{exit !f}'
}
upsert_device() {
  local tmp; tmp="$(mktemp)"
  NM_="$1" S_="$2" E_="$3" TP_="$4" awk -F'|' '
    BEGIN { nm=ENVIRON["NM_"]; s=ENVIRON["S_"]; e=ENVIRON["E_"]; tp=ENVIRON["TP_"] }
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
    { ser=$2; gsub(/[[:space:]]/,"",ser)
      if (ser==s) { printf "%s | %s | %s | %s\n", nm, s, e, tp; found=1 }
      else print }
    END { if (!found) printf "%s | %s | %s | %s\n", nm, s, e, tp }' \
    "$ENVF" > "$tmp" && mv "$tmp" "$ENVF"
}

is_net_serial() {
  case "$1" in
    *:*|*._adb-tls-connect._tcp|*._adb._tcp) return 0 ;;
    *) return 1 ;;
  esac
}
transport_for() {
  local d state _ hw
  while read -r d state _; do
    [ "$state" = "device" ] || continue
    case "$2" in
      usb) is_net_serial "$d" && continue ;;
      net) is_net_serial "$d" || continue ;;
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
proxy_up() { curl -s -o /dev/null --max-time 2 "http://localhost:$PROXY_PORT/"; }
ensure_proxy() {
  exposed_ports | grep -qx "$PROXY_PORT" || return 0
  mode_proxy start
}
mode_proxy() {
  case "${1:-status}" in
    start)
      if proxy_up; then echo "  Proxy already running (:$PROXY_PORT)"; return 0; fi
      echo "  Starting the proxy (:$PROXY_PORT)..."
      nohup setsid node proxy/proxy.js >/tmp/responsive-proxy.log 2>&1 </dev/null &
      sleep 1
      proxy_up && echo "  Proxy OK (:$PROXY_PORT)" || { echo "  [x] proxy did not come up (see: ./sh/tablet.sh proxy logs)"; return 1; } ;;
    stop)
      if pkill -f "node proxy/proxy.js" 2>/dev/null; then echo "  Proxy stopped."; else echo "  Proxy was not running."; fi ;;
    logs)
      if [ -f /tmp/responsive-proxy.log ]; then tail -n 40 /tmp/responsive-proxy.log; else echo "  no log yet (/tmp/responsive-proxy.log)"; fi ;;
    status)
      if proxy_up; then
        echo "  Proxy running (:$PROXY_PORT)  pid: $(pgrep -f 'node proxy/proxy.js' | head -1)"
      else
        echo "  Proxy NOT running -> start it with:  ./sh/tablet.sh proxy start"
      fi ;;
    *)
      echo "  usage: ./sh/tablet.sh proxy [ start | stop | status | logs ]"; return 1 ;;
  esac
}
mode_rm() {
  local -a recs=(); local rec name serial ep dtype t tmp
  if [ -n "${1:-}" ]; then
    rec="$(one_device "$1")" || return 1
    recs+=("$rec")
  else
    while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  fi
  [ "${#recs[@]}" -eq 0 ] && { echo "  nothing selected."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep dtype <<<"$rec"
    clear_reverses "$serial"
    t="$(transport_for "$serial" net)"
    [ -n "$t" ] && adb disconnect "$t" >/dev/null 2>&1
    tmp="$(mktemp)"
    S_="$serial" awk -F'|' '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      { ser=$2; gsub(/[[:space:]]/,"",ser); if (ser!=ENVIRON["S_"]) print }' \
      "$ENVF" > "$tmp" && mv "$tmp" "$ENVF"
    echo "  removed: $name ($serial) — tunnels cleared, WiFi disconnected"
  done
}
mode_off() {
  local name serial ep dtype any=0
  if [ "$#" -ge 1 ]; then
    if [ -z "$1" ]; then
      echo "  [x] no device name given. To turn off ONE tablet:  ./sh/tablet.sh off <name>"
      echo "      To tear down EVERYTHING (proxy + adb server), run it with no name:  ./sh/tablet.sh off"
      return 1
    fi
    local rec t
    rec="$(record_by_name "$1")"
    [ -z "$rec" ] && { echo "  [x] no tablet named '$1' in $ENVF (check with: ./sh/tablet.sh status)"; return 1; }
    IFS='|' read -r name serial ep dtype <<<"$rec"
    echo "  -- OFF $name: tunnels + WiFi adb for this device only (proxy and adb server stay up) --"
    clear_reverses "$serial"
    echo "  $name: reverse tunnels removed"
    t="$(transport_for "$serial" net)"
    if [ -n "$t" ]; then
      adb disconnect "$t" >/dev/null 2>&1
      echo "  $name: WiFi adb connection dropped ($t)"
    else
      echo "  $name: no WiFi adb connection to drop"
    fi
    [ -n "$ep" ] && adb disconnect "$ep" >/dev/null 2>&1
    echo "  Reconnect anytime with:  ./sh/tablet.sh wifi $name"
    return 0
  fi
  echo "  -- OFF: tearing down every connection (enrollment in $ENVF is kept) --"
  while IFS='|' read -r name serial ep dtype; do
    any=1
    clear_reverses "$serial"
    echo "  $name: reverse tunnels removed"
  done < <(registry_recs)
  [ "$any" = 1 ] || echo "  no tablets in $ENVF -> no tunnels to remove"
  local d net=0
  while read -r d _; do
    [ -n "$d" ] && is_net_serial "$d" && { net=1; break; }
  done < <(adb devices 2>/dev/null | tail -n +2)
  if [ "$net" = 1 ]; then
    adb disconnect >/dev/null 2>&1
    echo "  WiFi adb connections dropped"
  else
    echo "  no WiFi adb connections to drop"
  fi
  mode_proxy stop
  adb kill-server >/dev/null 2>&1
  echo "  adb server stopped (port 5037 no longer listening)"
  echo ""
  echo "  Everything is down. Reconnect anytime with:  ./sh/tablet.sh wifi   or   ./sh/tablet.sh usb"
  return 0
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
    echo "        then run ./sh/tablet.sh again to forward them."
  fi
  echo "  =================================================================="
}

registry_recs() {
  local name serial ep dtype
  while IFS='|' read -r name serial ep dtype; do
    name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"; dtype="$(trim "${dtype:-}")"
    [ -z "$serial" ] && continue
    [ -z "$dtype" ] && dtype="wifi"
    echo "$name|$serial|$ep|$dtype"
  done < <(env_lines)
}
record_by_name() {
  registry_recs | WANT_="$1" awk -F'|' '$1==ENVIRON["WANT_"]{print;exit}'
}
load_recs() {
  RECS=()
  local r
  while IFS= read -r r; do [ -n "$r" ] && RECS+=("$r"); done < <(registry_recs)
  [ "${#RECS[@]}" -gt 0 ]
}
print_recs_menu() {
  local i name serial ep dtype
  echo "  Registered tablets:" >&2
  for i in "${!RECS[@]}"; do
    IFS='|' read -r name serial ep dtype <<<"${RECS[$i]}"
    printf "    %d) %-16s [%-4s]  %s\n" "$((i+1))" "$name" "$dtype" "$serial" >&2
  done
}

pick_device() {
  local sel
  load_recs || { echo "  (no tablets in $ENVF -> enroll with: ./sh/tablet.sh qr  or  ./sh/tablet.sh usb)" >&2; return 1; }
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
  if [ "$sel" = "all" ] || [ "$sel" = "*" ]; then
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
  for d in $(adb devices 2>/dev/null | awk '/\tdevice$/{print $1}'); do
    is_net_serial "$d" || continue
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
  local have_avahi=1
  command -v avahi-browse >/dev/null 2>&1 || {
    have_avahi=0
    echo "  [!] avahi-browse missing -> falling back to adb's own mDNS resolver (less reliable)."
    echo "      For the smoothest pairing install it:  sudo apt install -y avahi-utils"
  }
  local want_name="${1:-}"
  [ -n "$want_name" ] && { valid_name "$want_name" qr || return 1; }
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
  local pe="" ip port
  if [ "$have_avahi" = 1 ]; then
    pe="$(wait_mdns '_adb-tls-pairing._tcp' "$name" 120)"
    [ -z "$pe" ] && pe="$(find_mdns '_adb-tls-pairing._tcp' '')"
  else
    local qstart=$SECONDS
    while [ $((SECONDS - qstart)) -lt 120 ]; do
      pe="$(adb mdns services 2>/dev/null | tr -d '\r' | awk '/_adb-tls-pairing/{print $NF; exit}')"
      [ -n "$pe" ] && break
      sleep 2
    done
  fi
  if [ -z "$pe" ]; then
    echo "  [x] no pairing service showed up over mDNS."
    [ "$have_avahi" = 1 ] || echo "      For reliable mDNS discovery install avahi:  sudo apt install -y avahi-utils"
    echo "      Then retry the QR, or enroll over cable instead:  ./sh/tablet.sh usb $want_name"
    return 1
  fi
  if [[ "$pe" == *" "* ]]; then ip="${pe% *}"; port="${pe##* }"; else ip="${pe%:*}"; port="${pe##*:}"; fi
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
    echo "      Nothing to type: fix the above and just re-run  ./sh/tablet.sh qr"
    echo "      Or enroll over cable instead:  ./sh/tablet.sh usb $want_name"
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
  [ -n "${1:-}" ] && { valid_name "$1" usb || return 1; }
  echo "  -- USB MODE (permanent cable) -> USB runtime --"
  echo "  adb in use: $(command -v adb)  ($(adb version | sed -n '2p'))"
  echo "  1) Plug the tablet in via USB and LEAVE the cable connected."
  echo "  2) Accept 'Allow USB debugging' (check 'always')."
  echo ""
  local d hw tries=0 warned=0 cand
  echo "  Waiting for an authorized USB device..."
  while :; do
    d=""
    for cand in $(adb devices | awk -F'\t' '$2=="device"{print $1}'); do
      is_net_serial "$cand" || { d="$cand"; break; }
    done
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
  if [ -n "$ep" ]; then
    adb disconnect "$ep" >/dev/null 2>&1
    if adb connect "$ep" >/dev/null 2>&1; then
      sleep 1
      netser="$(transport_for "$hw" net)"
      [ -n "$netser" ] && { echo "$netser"; return 0; }
    fi
    adb disconnect "$ep" >/dev/null 2>&1
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
    echo "       Nothing to type: re-enroll it with  ./sh/tablet.sh qr $name"
    echo "       (tip: a DHCP reservation on the router keeps its IP fixed forever)"
    return 1
  fi
  usbser="$(transport_for "$hw" usb)"
  [ -n "$usbser" ] && echo "   [!] a USB cable is connected ($usbser). In WiFi mode you should unplug it."
  if [[ "$netser" == *:* ]]; then
    upsert_device "$name" "$hw" "$netser" "wifi"
  else
    upsert_device "$name" "$hw" "$ep" "wifi"
  fi
  clear_reverses "$hw"
  activate "$netser" "$name" "wifi"
  return 0
}
mode_wifi() {
  echo "  -- WiFi MODE (known endpoint) -> WiFi runtime --"
  local rec name serial ep dtype
  if [ -n "${1:-}" ]; then
    rec="$(record_by_name "$1")"
    [ -z "$rec" ] && { echo "  [x] no tablet named '$1' in $ENVF (check with: ./sh/tablet.sh status)"; return 1; }
  else
    rec="$(pick_device)" || return 1
  fi
  IFS='|' read -r name serial ep dtype <<<"$(echo "$rec" | tr -s ' ')"
  name="$(trim "$name")"; serial="$(trim "$serial")"; ep="$(trim "$ep")"
  wifi_one "$name" "$serial" "$ep"
}

mode_use() {
  local rec name serial ep dtype choice
  rec="$(pick_device)" || return 1
  IFS='|' read -r name serial ep dtype <<<"$rec"
  echo "  Selected: $name  (current type: $dtype)"
  echo "    1) WiFi"
  echo "    2) USB (permanent cable)"
  read -rp "  Reconnect as [1/2] (enter = keep '$dtype'): " choice
  case "${choice:-}" in
    1) dtype="wifi" ;;
    2) dtype="usb" ;;
    "") : ;;
    *) echo "  invalid option."; return 1 ;;
  esac
  ensure_proxy
  if [ "$dtype" = "usb" ]; then
    upsert_device "$name" "$serial" "$ep" "usb"
    mode_usb "$name"
  else
    wifi_one "$name" "$serial" "$ep"
  fi
  print_urls
}

mode_status() {
  echo "  --- Tablets ($ENVF) ---"
  local name serial ep dtype usbser netser state
  while IFS='|' read -r name serial ep dtype; do
    usbser="$(transport_for "$serial" usb)"
    netser="$(transport_for "$serial" net)"
    if [ "$dtype" = "usb" ]; then
      [ -n "$usbser" ] && state="CONNECTED (usb $usbser)" || state="down (plug in the cable)"
    else
      [ -n "$netser" ] && state="CONNECTED (wifi $netser)" || state="down ($ep)"
    fi
    printf "    %-16s [%-4s]  %s  ->  %s\n" "$name" "$dtype" "$serial" "$state"
    [ -n "$usbser" ] && [ -n "$netser" ] && echo "        [!] DOUBLE transport connected (usb+wifi). In $dtype mode only one is used."
  done < <(registry_recs)
  echo "  --- URLs to expose ($URLF) ---"; url_lines | while read -r l; do echo "    $(trim "$l")"; done
  echo "  --- adb devices ---"; adb devices | tail -n +2
  check_adb_conflict
}

reconnect_all() {
  local any=0 name serial ep dtype usbser
  while IFS='|' read -r name serial ep dtype; do
    any=1
    if [ "$dtype" = "usb" ]; then
      usbser="$(transport_for "$serial" usb)"
      if [ -z "$usbser" ]; then echo "  $name [usb]: cable not connected -> plug it in and run ./sh/tablet.sh usb"; continue; fi
      local netser; netser="$(transport_for "$serial" net)"
      [ -n "$netser" ] && adb disconnect "$netser" >/dev/null 2>&1
      clear_reverses "$serial"
      activate "$usbser" "$name" "usb"
    else
      if ! wifi_one "$name" "$serial" "$ep"; then
        usbser="$(transport_for "$serial" usb)"
        if [ -n "$usbser" ]; then
          echo "   [!] $name: WiFi unreachable but the USB cable is plugged in -> using USB for now."
          clear_reverses "$serial"
          activate "$usbser" "$name" "usb"
        fi
      fi
    fi
  done < <(registry_recs)
  [ "$any" = "1" ] || echo "  (no tablets in $ENVF -> enroll with ./sh/tablet.sh qr  or  ./sh/tablet.sh usb)"
}

mode_cap() {
  local d hw name ts out
  if [ -n "${1:-}" ]; then
    hw="$(record_by_name "$1" | cut -d'|' -f2)"
    [ -z "$hw" ] && { echo "  [x] no tablet '$1' in $ENVF"; return 1; }
    d="$(resolve_transport "$hw")"
    [ -z "$d" ] && { echo "  [x] '$1' is not connected (run ./sh/tablet.sh usb  or  wifi)"; return 1; }
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
  local d="$1" resolved installed known="" pkgs pkg label
  resolved="$(adbt -s "$d" shell cmd package query-activities --brief -a android.intent.action.VIEW -d 'https://example.com' 2>/dev/null \
    | tr -d '\r' | awk -F'/' 'NF>1{gsub(/^[[:space:]]+/,"",$1); if ($1 ~ /^[A-Za-z0-9._]+$/) print $1}')"
  installed="$(adbt -s "$d" shell pm list packages 2>/dev/null | tr -d '\r' | sed 's/^package://')"
  if [ -n "$installed" ]; then
    while IFS='|' read -r pkg label; do
      [ -z "$pkg" ] && continue
      echo "$installed" | grep -qx "$pkg" && known="$known$pkg"$'\n'
    done <<<"$KNOWN_BROWSERS"
  fi
  pkgs="$(printf '%s\n%s\n%s\n' "$resolved" "$known" "$(echo "$installed" | grep -i 'browser')" | grep -v '^$' | sort -u)"
  [ -z "$pkgs" ] && return 1
  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    label="$(awk -F'|' -v p="$pkg" '$1==p{print $2;exit}' <<<"$KNOWN_BROWSERS")"
    echo "$pkg|${label:-$pkg}"
  done <<<"$pkgs"
}
mode_browsers() {
  local rec name serial d
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial _ <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)." >&2; return 1; }
  device_browsers "$d" || { echo "  [x] could not list packages on $name (reconnect with: ./sh/tablet.sh wifi $name)" >&2; return 1; }
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
  local url; url="$(sq "$2")"
  if [ -n "$3" ]; then
    adb -s "$1" shell "am start -a android.intent.action.VIEW -d $url $3" >/dev/null 2>&1 && return 0
    echo "    [!] $3 refused the intent -> falling back to the system default" >&2
  fi
  adb -s "$1" shell "am start -a android.intent.action.VIEW -d $url" >/dev/null 2>&1
}

mode_url() {
  if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    local rec name serial ep dtype d
    rec="$(one_device "$1")" || return 1
    IFS='|' read -r name serial ep dtype <<<"$rec"
    d="$(resolve_transport "$(trim "$serial")")"
    [ -z "$d" ] && { echo "  [x] $1 is not connected (run ./sh/tablet.sh first)."; return 1; }
    if open_url "$d" "$2" "${3:-}"; then echo "  OK  -> $2"; else echo "  [x] -> $2"; return 1; fi
    return 0
  fi
  local -a urls=() picks=()
  local l i usel n url
  while read -r l; do l="$(trim "$l")"; [ -n "$l" ] && urls+=("$l"); done < <(url_lines)
  [ "${#urls[@]}" -eq 0 ] && { echo "  [x] no URLs in $URLF"; echo "      Add one per line (e.g. http://localhost:5173) and run ./sh/tablet.sh again to forward it."; return 1; }
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
  local rec name serial ep dtype d opened=0 total=0
  while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick any device."; return 1; }

  local browser
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep dtype <<<"$rec"
    d="$(resolve_transport "$serial")"
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
    [ -z "$rec" ] && { echo "  [x] no tablet '$1' in $ENVF (check with: ./sh/tablet.sh status)" >&2; return 1; }
    echo "$rec"
  else
    pick_device
  fi
}

mode_clear() {
  local -a recs=(); local rec name serial ep dtype d ok=0
  if [ -n "${1:-}" ]; then
    rec="$(one_device "$1")" || return 1
    recs+=("$rec")
  else
    while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  fi
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick a device."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep dtype <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name not connected -> skipping (run ./sh/tablet.sh first)"; continue; }
    adb -s "$d" shell pm clear "$CHROME" >/dev/null 2>&1 \
      && { echo "  $name: Chrome cleared (cache + cookies + service worker)"; ok=$((ok+1)); } \
      || echo "  $name: [x] could not clear"
  done
  echo "  Done: $ok cleared."
}

mode_stop() {
  local -a recs=(); local rec name serial ep dtype d
  if [ -n "${1:-}" ]; then
    rec="$(one_device "$1")" || return 1
    recs+=("$rec")
  else
    while IFS= read -r rec; do [ -n "$rec" ] && recs+=("$rec"); done < <(pick_devices)
  fi
  [ "${#recs[@]}" -eq 0 ] && { echo "  you did not pick a device."; return 1; }
  for rec in "${recs[@]}"; do
    IFS='|' read -r name serial ep dtype <<<"$rec"; serial="$(trim "$serial")"
    d="$(resolve_transport "$serial")"
    [ -z "$d" ] && { echo "  [x] $name not connected -> skipping (run ./sh/tablet.sh first)"; continue; }
    adb -s "$d" shell am force-stop "$CHROME" >/dev/null 2>&1 && echo "  $name: Chrome closed" || echo "  $name: [x] failed"
  done
}

mode_logs() {
  local rec name serial ep dtype d
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep dtype <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)."; return 1; }
  echo "  Chromium logs on $name (Ctrl+C to exit)..."
  adb -s "$d" logcat -v time | grep --line-buffered -iE 'chromium|console'
}

mode_rec() {
  local rec name serial ep dtype d ts remote out secs="${2:-}"
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial ep dtype <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)."; return 1; }
  if [ -n "$secs" ] && ! [[ "$secs" =~ ^[0-9]+$ ]]; then
    echo "  [x] duration must be seconds, e.g.:  ./sh/tablet.sh rec $name 30"; return 1
  fi
  ts="$(date +%Y%m%d-%H%M%S)"; remote="/sdcard/rec-${ts}.mp4"; out="/tmp/${name}-${ts}.mp4"
  if [ -n "$secs" ]; then
    echo "  Recording $name for ${secs}s ..."
  else
    echo "  Recording $name ... (Ctrl+C to stop, max 180s)"
  fi
  trap ':' INT
  adb -s "$d" shell screenrecord ${secs:+--time-limit "$secs"} ${REC_BITRATE:+--bit-rate "$REC_BITRATE"} "$remote"
  trap - INT
  sleep 2
  if adb -s "$d" pull "$remote" "$out" >/dev/null 2>&1; then
    echo "  video -> $out ($(du -h "$out" 2>/dev/null | cut -f1))"
  else
    echo "  [x] could not pull the video"
  fi
  adb -s "$d" shell rm -f "$remote" >/dev/null 2>&1
}

SIZE_PRESETS="phone|1080x2400|420
phone-small|720x1600|320
tablet-8|1200x1920|320
tablet-10|1800x2560|320
fold-open|1812x2176|420"

mode_size() {
  local a1="${1:-}" a2="${2:-}" a3="${3:-}" preset="" res="" den="" name="" line sel
  case "$a1" in
    "")    ;;
    reset) preset="reset"; name="$a2" ;;
    *x*)   res="$a1"
           if [[ "$a2" =~ ^[0-9]+$ ]]; then den="$a2"; name="$a3"; else name="$a2"; fi
           [ -z "$den" ] && { echo "  [x] custom size needs a density too:  ./sh/tablet.sh size ${res} <dpi> [name]"; return 1; } ;;
    *)     line="$(awk -F'|' -v p="$a1" '$1==p{print;exit}' <<<"$SIZE_PRESETS")"
           if [ -n "$line" ]; then preset="$a1"; IFS='|' read -r _ res den <<<"$line"; name="$a2"
           else name="$a1"; fi ;;
  esac
  if [ -z "$preset$res" ]; then
    echo "  Size presets (turn one device into many):"
    local i=1 pn pr pd
    local -a plines=()
    while IFS= read -r line; do plines+=("$line"); done <<<"$SIZE_PRESETS"
    for line in "${plines[@]}"; do
      IFS='|' read -r pn pr pd <<<"$line"
      printf "    %d) %-12s %s @ %s dpi\n" "$i" "$pn" "$pr" "$pd"; i=$((i+1))
    done
    echo "    0) reset (back to the device's native screen)"
    read -rp "  Pick [0]: " sel
    sel="${sel:-0}"
    if [ "$sel" = "0" ]; then preset="reset"
    elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#plines[@]}" ]; then
      IFS='|' read -r preset res den <<<"${plines[$((sel-1))]}"
    else echo "  invalid selection."; return 1; fi
  fi
  local rec serial d
  rec="$(one_device "$name")" || return 1
  IFS='|' read -r name serial _ <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)."; return 1; }
  if [ "$preset" = "reset" ]; then
    adb -s "$d" shell wm size reset >/dev/null 2>&1
    adb -s "$d" shell wm density reset >/dev/null 2>&1
    echo "  $name: native size and density restored."
  else
    adb -s "$d" shell wm size "$res" >/dev/null 2>&1
    adb -s "$d" shell wm density "$den" >/dev/null 2>&1
    echo "  $name is now emulating '${preset:-custom}': $res @ $den dpi"
    echo "  Undo anytime with:  ./sh/tablet.sh size reset"
  fi
  echo "  Reported by the device:"
  adb -s "$d" shell wm size 2>/dev/null | tr -d '\r' | sed 's/^/    /'
  adb -s "$d" shell wm density 2>/dev/null | tr -d '\r' | sed 's/^/    /'
}

mode_rotate() {
  local a1="${1:-}" a2="${2:-}" orient="" name="" sel cur target label rec serial d
  case "$a1" in
    portrait|landscape|left|right|reset|portrait-reverse|landscape-reverse)
      orient="$a1"; name="$a2" ;;
    "") ;;
    *) name="$a1"; orient="$a2" ;;
  esac
  if [ -z "$orient" ]; then
    echo "  Screen orientation:"
    echo "    1) portrait          (natural, 0°)"
    echo "    2) landscape         (90°)"
    echo "    3) rotate left       (90° counter-clockwise from current)"
    echo "    4) rotate right      (90° clockwise from current)"
    echo "    0) reset (re-enable auto-rotate — the sensor decides)"
    read -rp "  Pick [0]: " sel
    sel="${sel:-0}"
    case "$sel" in
      0) orient="reset" ;;
      1) orient="portrait" ;;
      2) orient="landscape" ;;
      3) orient="left" ;;
      4) orient="right" ;;
      *) echo "  invalid selection."; return 1 ;;
    esac
  fi
  rec="$(one_device "$name")" || return 1
  IFS='|' read -r name serial _ <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)."; return 1; }
  if [ "$orient" = "reset" ]; then
    if adb -s "$d" shell settings put system accelerometer_rotation 1 >/dev/null 2>&1; then
      echo "  $name: auto-rotate re-enabled (the sensor controls orientation again)."
    else
      echo "  [x] could not re-enable auto-rotate on $name."
      echo "      Try it manually:  adb -s $d shell settings put system accelerometer_rotation 1"
      return 1
    fi
    return 0
  fi
  cur="$(adb -s "$d" shell settings get system user_rotation 2>/dev/null | tr -d '\r')"
  [[ "$cur" =~ ^[0-3]$ ]] || cur=0
  case "$orient" in
    portrait)          target=0 ;;
    landscape)         target=1 ;;
    portrait-reverse)  target=2 ;;
    landscape-reverse) target=3 ;;
    left)              target=$(( (cur + 3) % 4 )) ;;
    right)             target=$(( (cur + 1) % 4 )) ;;
  esac
  adb -s "$d" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1
  if adb -s "$d" shell settings put system user_rotation "$target" >/dev/null 2>&1; then
    case "$target" in
      0) label="portrait (natural, 0°)" ;;
      1) label="landscape (90°)" ;;
      2) label="portrait-reverse (180°)" ;;
      3) label="landscape-reverse (270°)" ;;
    esac
    echo "  $name is now $label."
    echo "  Undo anytime with:  ./sh/tablet.sh rotate reset"
  else
    echo "  [x] could not set orientation on $name."
    echo "      Try it manually:  adb -s $d shell settings put system user_rotation $target"
    return 1
  fi
  echo "  Reported by the device:"
  adb -s "$d" shell settings get system user_rotation 2>/dev/null | tr -d '\r' | sed 's/^/    user_rotation /'
}

mode_inspect() {
  local rec name serial d port="${INSPECT_PORT:-9222}"
  rec="$(one_device "${1:-}")" || return 1
  IFS='|' read -r name serial _ <<<"$rec"; name="$(trim "$name")"; serial="$(trim "$serial")"
  d="$(resolve_transport "$serial")"
  [ -z "$d" ] && { echo "  [x] $name not connected (run ./sh/tablet.sh first)."; return 1; }
  adb -s "$d" forward "tcp:$port" localabstract:chrome_devtools_remote >/dev/null 2>&1 \
    || { echo "  [x] could not create the DevTools forward on tcp:$port (busy? set INSPECT_PORT=<port>)"; return 1; }
  echo "  DevTools bridge ready for $name ($d):"
  echo "    A) full UI + screencast: open  chrome://inspect/#devices  in desktop Chrome"
  echo "    B) raw endpoint:         http://localhost:$port/json  (works from any tool)"
  echo "  The browser must be RUNNING on the device (Chromium-based, e.g. Chrome)."
  echo "  Stop the bridge with:  adb -s $d forward --remove tcp:$port"
}

mode_ui() {
  local bin="tablet-ui/target/release/tablet-ui"
  if [ ! -x "$bin" ]; then
    if command -v cargo >/dev/null 2>&1 || [ -x "$HOME/.cargo/bin/cargo" ]; then
      echo "  Building the interactive console (first time only)..."
      (cd tablet-ui && PATH="$HOME/.cargo/bin:$PATH" cargo build --release) || return 1
    else
      echo "  [x] the console is not built and Rust (cargo) is missing."
      echo "      Install Rust:  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y"
      echo "      then run:      ./sh/tablet.sh ui"
      return 1
    fi
  fi
  exec "$bin"
}

case "${1:-}" in
  setup)  [ -x ./setup.sh ] || { echo "  [x] setup.sh not found next to tablet.sh"; exit 1; }
          exec ./setup.sh "${2:-}" ;;
  ui)     mode_ui ;;
  qr)     mode_qr "${2:-}"   && { ensure_proxy; print_urls; } ;;
  usb)    mode_usb "${2:-}"  && { ensure_proxy; print_urls; } ;;
  wifi)   ensure_proxy; mode_wifi "${2:-}" && print_urls ;;
  use)    mode_use ;;
  status) mode_status ;;
  cap)    mode_cap "${2:-}" ;;
  url)    mode_url "${2:-}" "${3:-}" "${4:-}" ;;
  browsers) mode_browsers "${2:-}" ;;
  clear)  mode_clear "${2:-}" ;;
  stop)   mode_stop "${2:-}" ;;
  logs)   mode_logs "${2:-}" ;;
  rec)    mode_rec "${2:-}" "${3:-}" ;;
  size)   mode_size "${2:-}" "${3:-}" "${4:-}" ;;
  rotate) mode_rotate "${2:-}" "${3:-}" ;;
  inspect) mode_inspect "${2:-}" ;;
  rm)     mode_rm "${2:-}" ;;
  proxy)  mode_proxy "${2:-}" ;;
  off)    mode_off "${@:2}" ;;
  "")     ensure_proxy; reconnect_all; print_urls ;;
  -h|--help|help)
    grep -E '^#( |=)' "$0" | sed -E 's/^# ?//' | head -40 ;;
  *)
    echo "  [x] unknown command: '$1'"
    echo "      usage: ./sh/tablet.sh [ setup | qr | usb | wifi | use | status | cap | url | browsers | size | rotate | inspect | rm | proxy | off | clear | stop | logs | rec ]"
    exit 1 ;;
esac
