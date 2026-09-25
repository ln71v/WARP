#!/usr/bin/env bash
# warp — менеджер Cloudflare WARP для AmneziaWG 2 (Docker, контейнер из приложения Amnezia).
# Репа: github.com/ln71v/WARP
#
# Запуск на хосте от root:
#   warp            — меню
#   warp api ...    — команды для Telegram-бота (без меню)
#
# Схема: клиент → amnezia-awg2 → интерфейс warp (внутри контейнера) → Cloudflare → интернет.
# Кто идёт через WARP — решается по IP клиента (ip rule, таблица 100). Остальные — напрямую.

set -uo pipefail

VERSION="1.1"
TABLE=100
WG_CONF="/opt/amnezia/awg/awg0.conf"
START_SH="/opt/amnezia/start.sh"
CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
NAMES_FILE="/opt/amnezia/client_names.txt"
PSK_FILE="/opt/amnezia/awg/wireguard_psk.key"
SRV_PUB_FILE="/opt/amnezia/awg/wireguard_server_public_key.key"
WARP_CONF="/opt/warp/warp.conf"
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"
WGCF_FALLBACK="v2.3.0"
CLIENTS_DIR="/root/warp-clients"
BOT_DIR="/opt/warp-bot"
BOT_ENV="$BOT_DIR/bot.env"
BOT_SVC="warp-bot"
LOCK="/run/warp-manager.lock"

MODE="menu"; [ "${1:-}" = "api" ] && MODE="api"

if [ "$MODE" = "menu" ] && [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; W=""; N=""
fi

[ "$(id -u)" = "0" ] || { echo "Запускай от root."; exit 1; }
command -v docker >/dev/null || { echo "Docker не найден."; exit 1; }

pause() { echo; read -rp "Enter..." _; }

# ───────────────────────── контейнер ─────────────────────────

find_container() {
  if docker ps --format '{{.Names}}' | grep -qx 'amnezia-awg2'; then
    echo amnezia-awg2; return 0
  fi
  local list
  list=$(docker ps --format '{{.Names}}' | grep -E '^amnezia-awg' || true)
  if [ "$(echo "$list" | grep -c .)" = "1" ]; then echo "$list"; return 0; fi
  return 1
}

C=$(find_container) || { echo "Не нашла запущенный контейнер AmneziaWG (amnezia-awg2). Поставь AmneziaWG (версия 2) через приложение Amnezia."; exit 1; }

dx() { docker exec "$C" "$@"; }

# блокировка, чтобы бот и меню не правили конфиги одновременно
with_lock() {
  exec 9>"$LOCK"
  flock -w 60 9 || { echo "Занято другим изменением, попробуй ещё раз."; return 1; }
  "$@"; local rc=$?
  flock -u 9
  return $rc
}

# ───────────────────────── клиенты и имена ─────────────────────────

# "pubkey<TAB>ip" для каждого [Peer] в awg0.conf
peer_records() {
  dx awk '
    /^\[Peer\]/{pk=""; ip=""}
    /^PublicKey/{sub(/^PublicKey[ \t]*=[ \t]*/,""); pk=$0}
    /^AllowedIPs/{sub(/^AllowedIPs[ \t]*=[ \t]*/,""); split($0,a,"/"); ip=a[1]; if(pk!="") print pk"\t"ip}
  ' "$WG_CONF" 2>/dev/null
}

# "pubkey<TAB>имя" из родного clientsTable Amnezia
native_names() {
  dx cat "$CLIENTS_TABLE" 2>/dev/null | python3 -c '
import json,sys
try:
    for c in json.load(sys.stdin):
        n=(c.get("userData") or {}).get("clientName","")
        if c.get("clientId") and n: print(c["clientId"]+"\t"+n.replace("\t"," ").replace("\n"," "))
except Exception: pass
'
}

declare -A NNAMES MNAMES

load_names() {
  NNAMES=(); MNAMES=()
  local pk name ip
  while IFS=$'\t' read -r pk name; do [ -n "$pk" ] && NNAMES["$pk"]="$name"; done < <(native_names)
  while IFS='=' read -r ip name; do [ -n "$ip" ] && MNAMES["$ip"]="$name"; done < <(dx sh -c "touch $NAMES_FILE; cat $NAMES_FILE" 2>/dev/null)
}

name_for() {
  local pk="$1" ip="$2"
  if [ -n "${MNAMES[$ip]:-}" ]; then echo "${MNAMES[$ip]}"; return; fi
  if [ -n "${NNAMES[$pk]:-}" ]; then echo "${NNAMES[$pk]}"; return; fi
  echo "без имени"
}

# ───────────────────────── состояние WARP ─────────────────────────

is_installed() { dx test -f "$WARP_CONF" 2>/dev/null; }

warp_ips() {
  dx awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b{f=1; next}
    $0==e{f=0}
    f && /ip rule add from/ { for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]} }
  ' "$START_SH" 2>/dev/null
}

# сколько секунд назад отвечал Cloudflare; пусто — не отвечал
hs_age() {
  local hs
  hs=$(dx wg show warp latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
  if [ -z "$hs" ] || [ "$hs" = "0" ]; then echo ""; return; fi
  echo $(( $(date +%s) - hs ))
}

warp_state() {
  if ! is_installed; then echo "${Y}не установлен${N}"; return; fi
  local age; age=$(hs_age)
  if [ -z "$age" ]; then echo "${R}нет связи${N}"
  elif [ "$age" -gt 180 ]; then echo "${R}завис (${age}с без ответа)${N}"
  else echo "${G}подключён${N}"; fi
}

# ───────────────────────── применение правил WARP ─────────────────────────

# $@ = список IP, которые идут через WARP. Остальные — напрямую.
apply_warp_ips() {
  docker exec -i "$C" bash -s -- "$@" <<'REMOTE'
set -e
TABLE=100
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"
START_SH="/opt/amnezia/start.sh"

[ -f /opt/warp/warp.conf ] || { echo "WARP не установлен. Сначала пункт 1."; exit 1; }
wg show warp >/dev/null 2>&1 || wg-quick up /opt/warp/warp.conf >/dev/null 2>&1 || true

cp "$START_SH" "${START_SH}.bak"

OLD_IPS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b{f=1; next} $0==e{f=0}
  f && /ip rule add from/ { for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]} }
' "$START_SH")
for ip in $OLD_IPS; do
  while ip rule del from "$ip/32" table $TABLE 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "$ip/32" -o warp -j MASQUERADE 2>/dev/null; do :; done
done

# вырезаем старый блок, новый вставляем ПЕРЕД "tail -f /dev/null", иначе он не выполнится
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$START_SH" > /tmp/start.clean

BLOCK=/tmp/warp.block
{
  echo "$BEGIN_MARK"
  echo "if [ -f /opt/warp/warp.conf ]; then wg-quick up /opt/warp/warp.conf || true; sleep 3; fi"
  echo "ip route replace default dev warp table $TABLE 2>/dev/null || true"
  echo "iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true"
  prio=100
  for ip in "$@"; do
    echo "ip rule add from $ip/32 table $TABLE priority $prio 2>/dev/null || true"
    echo "iptables -t nat -C POSTROUTING -s $ip/32 -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s $ip/32 -o warp -j MASQUERADE"
    prio=$((prio+1))
  done
  echo "$END_MARK"
} > "$BLOCK"

if grep -q '^tail -f /dev/null' /tmp/start.clean; then
  awk -v blk="$BLOCK" '/^tail -f \/dev\/null/ && !done { while ((getline l < blk) > 0) print l; done=1 } {print}' /tmp/start.clean > /tmp/start.new
else
  cat /tmp/start.clean "$BLOCK" > /tmp/start.new
fi
cat /tmp/start.new > "$START_SH"
chmod +x "$START_SH"
rm -f /tmp/start.clean /tmp/start.new "$BLOCK"

ip route replace default dev warp table $TABLE 2>/dev/null || true
iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
prio=100
for ip in "$@"; do
  ip rule add from "$ip/32" table $TABLE priority $prio 2>/dev/null || true
  iptables -t nat -C POSTROUTING -s "$ip/32" -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$ip/32" -o warp -j MASQUERADE
  prio=$((prio+1))
done
echo "Применено. Через WARP: $# клиент(ов)."
REMOTE
}

# ───────────────────────── WARP-профиль ─────────────────────────

MAKE_PROFILE='
cd /opt/warp
rm -f wgcf-account.toml wgcf-profile.conf warp.conf
wgcf register --accept-tos >/dev/null
wgcf generate >/dev/null
# DNS убираем (в Alpine ломает wg-quick), Table=off (не трогаем основной маршрут),
# PersistentKeepalive=25 (иначе туннель отваливается от простоя)
awk "
  /^DNS/ {next}
  /^\[Interface\]/ {print; print \"Table = off\"; next}
  /^\[Peer\]/ {print; print \"PersistentKeepalive = 25\"; next}
  {print}
" wgcf-profile.conf > warp.conf
chmod 600 warp.conf wgcf-account.toml
'

do_install() {
  if is_installed; then echo "WARP уже установлен. Для нового ключа — перевыпуск."; return 0; fi
  echo "Ставлю WARP в $C..."
  docker exec -i "$C" bash -s "$WGCF_FALLBACK" <<REMOTE
set -e
command -v wg-quick >/dev/null || apk add --no-cache wireguard-tools >/dev/null
command -v curl >/dev/null || apk add --no-cache curl >/dev/null
case "\$(uname -m)" in
  x86_64) A=amd64 ;; aarch64) A=arm64 ;; armv7l) A=armv7 ;;
  *) echo "Неизвестная архитектура"; exit 1 ;;
esac
URL=\$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest | grep browser_download_url | grep "linux_\$A\"" | cut -d '"' -f4 | head -1)
if [ -z "\$URL" ]; then V=\$1; URL="https://github.com/ViRb3/wgcf/releases/download/\$V/wgcf_\${V#v}_linux_\$A"; fi
echo "Качаю wgcf: \$URL"
curl -fsSL -o /usr/local/bin/wgcf "\$URL"
chmod +x /usr/local/bin/wgcf
/usr/local/bin/wgcf --help >/dev/null 2>&1 || { echo "wgcf скачался битым"; rm -f /usr/local/bin/wgcf; exit 1; }
mkdir -p /opt/warp
echo "Регистрирую WARP-аккаунт..."
$MAKE_PROFILE
wg-quick up /opt/warp/warp.conf >/dev/null
sleep 3
echo "WARP поднят."
REMOTE
  [ $? -eq 0 ] || { echo "Установка не удалась."; return 1; }
  apply_warp_ips
  echo "Готово. Клиенты пока идут напрямую — включи нужных в «Клиенты WARP»."
}

do_reissue() {
  is_installed || { echo "WARP не установлен."; return 1; }
  echo "Перевыпускаю ключ..."
  docker exec -i "$C" bash -s <<REMOTE
set -e
wg-quick down /opt/warp/warp.conf >/dev/null 2>&1 || true
$MAKE_PROFILE
wg-quick up /opt/warp/warp.conf >/dev/null
sleep 3
REMOTE
  dx sh -c "ip route replace default dev warp table $TABLE" 2>/dev/null
  echo "Новый ключ выпущен. Клиенты остались как были."
  echo "Связь: $(warp_state)"
}

do_status() {
  echo "Контейнер: $C ($(docker inspect -f '{{.State.Status}}' "$C"))"
  echo "WARP: $(warp_state)"
  if is_installed; then
    local age wip
    age=$(hs_age)
    [ -n "$age" ] && echo "Последний ответ Cloudflare: ${age}с назад (норма до 180)"
    wip=$(dx sh -c "curl -s4 --max-time 5 --interface warp https://ifconfig.me" 2>/dev/null)
    echo "IP сервера: $(curl -s4 --max-time 5 https://ifconfig.me)"
    echo "IP WARP: ${wip:-не отвечает}"
  fi
  echo
  echo "Клиенты:"
  load_names
  local wl pk ip mark
  wl=$(warp_ips)
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    if echo "$wl" | grep -qx "$ip"; then mark="${G}WARP${N}"; else mark="напрямую"; fi
    printf "  %-12s %-24s %s\n" "$ip" "$(name_for "$pk" "$ip")" "$mark"
  done < <(peer_records)
}

do_remove_warp() {
  docker exec -i "$C" bash -s <<'REMOTE'
START_SH="/opt/amnezia/start.sh"
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"
for ip in $(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{f=1;next} $0==e{f=0} f && /ip rule add from/ {for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]}}' "$START_SH"); do
  while ip rule del from "$ip/32" table 100 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -s "$ip/32" -o warp -j MASQUERADE 2>/dev/null; do :; done
done
while iptables -t mangle -D FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
wg-quick down /opt/warp/warp.conf >/dev/null 2>&1 || true
cp "$START_SH" "${START_SH}.bak"
awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$START_SH" > /tmp/s && cat /tmp/s > "$START_SH" && rm -f /tmp/s
rm -rf /opt/warp /usr/local/bin/wgcf
echo "WARP удалён."
REMOTE
}

# ───────────────────────── клиенты AmneziaWG: добавить / удалить ─────────────────────────

safe_name() { echo "$1" | tr -cd 'A-Za-z0-9_-' | cut -c1-24; }

server_ip() {
  local ip
  ip=$(curl -s4 --max-time 5 https://ifconfig.me 2>/dev/null)
  [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
  echo "$ip"
}

# $1 = имя. Печатает путь к готовому .conf последней строкой.
do_add_client() {
  local name="$1"
  name=$(echo "$name" | tr -d "\"'\\\\\`\$=|" | cut -c1-32)
  [ -z "$name" ] && { echo "Пустое имя."; return 1; }

  local used ip n
  used=$(peer_records | cut -f2)
  ip=""
  for n in $(seq 1 254); do
    if ! echo "$used" | grep -qx "10.8.1.$n"; then ip="10.8.1.$n"; break; fi
  done
  [ -z "$ip" ] && { echo "Свободных адресов нет."; return 1; }

  local priv pub psk spub port params endpoint
  priv=$(dx awg genkey) || { echo "awg genkey не сработал."; return 1; }
  pub=$(echo "$priv" | docker exec -i "$C" awg pubkey)
  psk=$(dx cat "$PSK_FILE" | tr -d '\r\n')
  spub=$(dx cat "$SRV_PUB_FILE" | tr -d '\r\n')
  port=$(dx awk -F'=' '/^ListenPort/{gsub(/[ \t]/,"",$2); print $2}' "$WG_CONF")
  params=$(dx awk '/^\[Interface\]/{f=1;next} /^\[/{f=0} f && /^(Jc|Jmin|Jmax|S[1-4]|H[1-4]|I[1-5])[ \t]*=/' "$WG_CONF")
  endpoint="$(server_ip):$port"
  [ -z "$pub" ] || [ -z "$spub" ] || [ -z "$port" ] && { echo "Не смогла прочитать ключи/порт сервера."; return 1; }

  dx cp "$WG_CONF" "$WG_CONF.bak"
  printf '\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s/32\n' "$pub" "$psk" "$ip" \
    | docker exec -i "$C" sh -c "cat >> $WG_CONF"
  dx bash -c "awg syncconf awg0 <(awg-quick strip $WG_CONF)" || { echo "Не применилось на лету — перезапусти контейнер."; }

  # в clientsTable, чтобы клиента видело приложение Amnezia
  dx cat "$CLIENTS_TABLE" 2>/dev/null | python3 -c '
import json,sys,time
pub,name=sys.argv[1],sys.argv[2]
try: t=json.load(sys.stdin)
except Exception: t=[]
t=[c for c in t if c.get("clientId")!=pub]
t.append({"clientId":pub,"userData":{"clientName":name,"creationDate":time.strftime("%a %b %d %H:%M:%S %Y")}})
print(json.dumps(t,indent=4,ensure_ascii=False))
' "$pub" "$name" > /tmp/ct.json && docker exec -i "$C" sh -c "cat > $CLIENTS_TABLE" < /tmp/ct.json
  rm -f /tmp/ct.json

  mkdir -p "$CLIENTS_DIR"; chmod 700 "$CLIENTS_DIR"
  local fn file
  fn=$(safe_name "$name"); [ -z "$fn" ] && fn="client"
  file="$CLIENTS_DIR/${fn}_${ip##*.}.conf"
  {
    echo "[Interface]"
    echo "PrivateKey = $priv"
    echo "Address = $ip/32"
    echo "DNS = 1.1.1.1, 1.0.0.1"
    echo "$params"
    echo
    echo "[Peer]"
    echo "PublicKey = $spub"
    echo "PresharedKey = $psk"
    echo "AllowedIPs = 0.0.0.0/0, ::/0"
    echo "Endpoint = $endpoint"
    echo "PersistentKeepalive = 25"
  } > "$file"
  chmod 600 "$file"
  echo "Клиент $name добавлен: $ip (напрямую; через WARP — включи в «Клиенты WARP»)."
  echo "$file"
}

# $1 = IP клиента
do_del_client() {
  local ip="$1" pub wl keep=() x
  pub=$(peer_records | awk -F'\t' -v ip="$ip" '$2==ip{print $1}')
  [ -z "$pub" ] && { echo "Клиента $ip нет."; return 1; }

  # если шёл через WARP — убираем из списка
  wl=$(warp_ips)
  if echo "$wl" | grep -qx "$ip"; then
    for x in $wl; do [ "$x" != "$ip" ] && keep+=("$x"); done
    apply_warp_ips "${keep[@]}" >/dev/null
  fi

  dx cp "$WG_CONF" "$WG_CONF.bak"
  dx awk -v ip="$ip" '
    function flush(){ if(buf!="" && !del) printf "%s", buf; buf=""; del=0 }
    /^\[/ { flush() }
    { buf = buf $0 "\n" }
    /^AllowedIPs/ { a=$0; sub(/^AllowedIPs[ \t]*=[ \t]*/,"",a); split(a,p,"/"); if(p[1]==ip) del=1 }
    END { flush() }
  ' "$WG_CONF" > /tmp/awg0.new
  docker exec -i "$C" sh -c "cat > $WG_CONF" < /tmp/awg0.new
  rm -f /tmp/awg0.new
  dx awg set awg0 peer "$pub" remove 2>/dev/null

  dx cat "$CLIENTS_TABLE" 2>/dev/null | python3 -c '
import json,sys
pub=sys.argv[1]
try: t=json.load(sys.stdin)
except Exception: t=[]
print(json.dumps([c for c in t if c.get("clientId")!=pub],indent=4,ensure_ascii=False))
' "$pub" > /tmp/ct.json && docker exec -i "$C" sh -c "cat > $CLIENTS_TABLE" < /tmp/ct.json
  rm -f /tmp/ct.json
  dx sh -c "touch $NAMES_FILE; grep -v '^$ip=' $NAMES_FILE > $NAMES_FILE.tmp; mv $NAMES_FILE.tmp $NAMES_FILE"
  rm -f "$CLIENTS_DIR"/*_"${ip##*.}".conf
  echo "Клиент $ip удалён."
}

do_rename() {
  local ip="$1" nn="$2"
  nn=$(echo "$nn" | tr -d "=\"'\\\\\`\$|")
  [ -z "$nn" ] && return 1
  dx sh -c "touch $NAMES_FILE; grep -v '^$ip=' $NAMES_FILE > $NAMES_FILE.tmp; echo '$ip=$nn' >> $NAMES_FILE.tmp; mv $NAMES_FILE.tmp $NAMES_FILE"
}

# ───────────────────────── API для бота ─────────────────────────

api() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    clients)   # ip|имя|1-через WARP/0-напрямую
      load_names
      local wl pk ip
      wl=$(warp_ips)
      while IFS=$'\t' read -r pk ip; do
        [ -z "$ip" ] && continue
        echo "$ip|$(name_for "$pk" "$ip")|$(echo "$wl" | grep -qx "$ip" && echo 1 || echo 0)"
      done < <(peer_records) ;;
    installed) is_installed && echo yes || echo no ;;
    status)    do_status ;;
    apply)     with_lock apply_warp_ips "$@" ;;
    reissue)   with_lock do_reissue ;;
    add)       with_lock do_add_client "$*" ;;
    del)       with_lock do_del_client "$1" ;;
    *) echo "Команды: clients | installed | status | apply IP... | reissue | add ИМЯ | del IP"; return 1 ;;
  esac
}

if [ "$MODE" = "api" ]; then
  shift
  api "$@"
  exit $?
fi

# ───────────────────────── Telegram-бот ─────────────────────────

write_bot_py() {
  mkdir -p "$BOT_DIR"
  cat > "$BOT_DIR/bot.py" <<'PYBOT'
#!/usr/bin/env python3
# Бот управления WARP. Все действия — через `warp api ...`.
import os, subprocess, tempfile
import telebot
from telebot.types import InlineKeyboardMarkup as KB, InlineKeyboardButton as Btn

TOKEN = os.environ["BOT_TOKEN"]
ADMIN_ID = int(os.environ["ADMIN_ID"])
NOPE = "Съебался в ужасе."

bot = telebot.TeleBot(TOKEN, parse_mode=None)
sel = {}   # chat_id -> {ip: bool} — черновик переключателей WARP


def api(*args, timeout=180):
    try:
        r = subprocess.run(["/usr/local/bin/warp", "api", *args],
                           capture_output=True, text=True, timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return "Не дождалась ответа (таймаут)."


def clients():
    out = []
    for line in api("clients").splitlines():
        p = line.split("|")
        if len(p) == 3:
            out.append((p[0], p[1], p[2] == "1"))
    return out


def mine(uid):
    return uid == ADMIN_ID


def edit(call, text, kb=None):
    try:
        bot.edit_message_text(text, call.message.chat.id, call.message.message_id, reply_markup=kb)
    except Exception:
        bot.send_message(call.message.chat.id, text, reply_markup=kb)


def main_kb():
    kb = KB(row_width=2)
    kb.add(Btn("📊 Статус", callback_data="status"), Btn("👥 Клиенты WARP", callback_data="warp"))
    kb.add(Btn("➕ Новый клиент", callback_data="add"), Btn("🗑 Удалить клиента", callback_data="del"))
    kb.add(Btn("🔑 Перевыпуск ключа WARP", callback_data="reissue"))
    return kb


def back_kb():
    return KB().add(Btn("⬅️ Назад", callback_data="main"))


@bot.message_handler(commands=["start", "menu"])
def start(m):
    if not mine(m.from_user.id):
        return bot.reply_to(m, NOPE)
    bot.send_message(m.chat.id, "🛰 Управление WARP", reply_markup=main_kb())


@bot.message_handler(func=lambda m: not mine(m.from_user.id))
def stranger(m):
    bot.reply_to(m, NOPE)


# ── клиенты WARP ──
def warp_kb(chat_id, names):
    kb = KB(row_width=1)
    for ip, on in sel[chat_id].items():
        kb.add(Btn(f"{'✅' if on else '❌'} {ip} ({names.get(ip, ip)})", callback_data=f"t|{ip}"))
    kb.row(Btn("Включить всех", callback_data="all"), Btn("Выключить всех", callback_data="none"))
    kb.row(Btn("💾 ПРИМЕНИТЬ", callback_data="apply"), Btn("⬅️ Назад", callback_data="main"))
    return kb


names_cache = {}


def show_warp(call, reload=True):
    cid = call.message.chat.id
    if reload:
        cl = clients()
        sel[cid] = {ip: on for ip, _, on in cl}
        names_cache[cid] = {ip: n for ip, n, _ in cl}
    if not sel.get(cid):
        return edit(call, "Клиентов нет.", back_kb())
    edit(call, "👥 Клиенты WARP\n(жми для переключения, потом ПРИМЕНИТЬ)", warp_kb(cid, names_cache.get(cid, {})))


@bot.callback_query_handler(func=lambda c: True)
def on_call(call):
    if not mine(call.from_user.id):
        return bot.answer_callback_query(call.id, NOPE, show_alert=True)
    cid, d = call.message.chat.id, call.data
    bot.answer_callback_query(call.id)

    if d == "main":
        return edit(call, "🛰 Управление WARP", main_kb())

    if d == "status":
        edit(call, "⏳ Проверяю...")
        return edit(call, api("status"), back_kb())

    if d == "warp":
        if api("installed") != "yes":
            return edit(call, "WARP не установлен. Поставь из меню warp на сервере.", back_kb())
        return show_warp(call)

    if d.startswith("t|") or d in ("all", "none"):
        if cid not in sel:
            return show_warp(call)
        if d == "all":
            for ip in sel[cid]: sel[cid][ip] = True
        elif d == "none":
            for ip in sel[cid]: sel[cid][ip] = False
        else:
            ip = d[2:]
            if ip in sel[cid]: sel[cid][ip] = not sel[cid][ip]
        return show_warp(call, reload=False)

    if d == "apply":
        if cid not in sel:
            return show_warp(call)
        edit(call, "⏳ Применяю...")
        res = api("apply", *[ip for ip, on in sel[cid].items() if on])
        bot.send_message(cid, res)
        return show_warp(call)

    if d == "reissue":
        kb = KB().row(Btn("Да, перевыпустить", callback_data="reissue_yes"), Btn("⬅️ Назад", callback_data="main"))
        return edit(call, "Перевыпустить ключ WARP? Секунд 10 интернет у WARP-клиентов пропадёт.", kb)

    if d == "reissue_yes":
        edit(call, "⏳ Перевыпускаю...")
        return edit(call, api("reissue"), back_kb())

    if d == "add":
        msg = bot.send_message(cid, "Имя нового клиента (например: Света телефон):")
        return bot.register_next_step_handler(msg, add_client)

    if d == "del":
        kb = KB(row_width=1)
        for ip, n, _ in clients():
            kb.add(Btn(f"🗑 {ip} ({n})", callback_data=f"d|{ip}"))
        kb.add(Btn("⬅️ Назад", callback_data="main"))
        return edit(call, "Кого удалить?", kb)

    if d.startswith("d|"):
        ip = d[2:]
        kb = KB().row(Btn(f"Да, удалить {ip}", callback_data=f"dy|{ip}"), Btn("⬅️ Назад", callback_data="del"))
        return edit(call, f"Удалить {ip}? Его ключ перестанет работать.", kb)

    if d.startswith("dy|"):
        edit(call, "⏳ Удаляю...")
        return edit(call, api("del", d[3:]), back_kb())


def add_client(m):
    if not mine(m.from_user.id):
        return
    name = (m.text or "").strip()
    if not name or name.startswith("/"):
        return bot.send_message(m.chat.id, "Отмена.", reply_markup=main_kb())
    bot.send_message(m.chat.id, "⏳ Создаю...")
    out = api("add", name)
    lines = out.splitlines()
    path = lines[-1] if lines else ""
    if not path.endswith(".conf") or not os.path.exists(path):
        return bot.send_message(m.chat.id, "Не вышло:\n" + out, reply_markup=main_kb())
    info = "\n".join(lines[:-1])
    with open(path, "rb") as f:
        bot.send_document(m.chat.id, f, visible_file_name=os.path.basename(path), caption=info)
    with tempfile.NamedTemporaryFile(suffix=".png") as png:
        r = subprocess.run(["qrencode", "-o", png.name, "-r", path], capture_output=True)
        if r.returncode == 0:
            with open(png.name, "rb") as f:
                bot.send_photo(m.chat.id, f, caption="QR для AmneziaVPN / AmneziaWG")
        else:
            bot.send_message(m.chat.id, "QR не влез — импортируй файл.")
    bot.send_message(m.chat.id, "🛰 Управление WARP", reply_markup=main_kb())


bot.infinity_polling(timeout=20, long_polling_timeout=20)
PYBOT
  chmod 700 "$BOT_DIR/bot.py"
}

bot_setup() {
  echo "${W}━━━ Настройка Telegram-бота ━━━${N}"
  echo
  echo "${Y}Шаг 1/3.${N} Токен бота"
  echo "  Получить: @BotFather → /newbot → скопировать токен"
  local token me uname id
  while true; do
    read -rp "  Токен (Enter — отмена): " token
    [ -z "$token" ] && return
    me=$(curl -s --max-time 10 "https://api.telegram.org/bot${token}/getMe")
    if echo "$me" | grep -q '"ok":true'; then
      uname=$(echo "$me" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["username"])')
      echo "  ${G}Ок, бот @$uname${N}"; break
    fi
    echo "  ${R}Telegram не принял токен, проверь.${N}"
  done
  echo
  echo "${Y}Шаг 2/3.${N} Твой Telegram ID (цифры, не ник)"
  echo "  Узнать: напиши @userinfobot — он ответит числом Id"
  while true; do
    read -rp "  ID: " id
    [[ "$id" =~ ^[0-9]{5,15}$ ]] && break
    echo "  ${R}Нужны только цифры.${N}"
  done
  echo
  echo "${Y}Шаг 3/3.${N} Ставлю..."
  export DEBIAN_FRONTEND=noninteractive
  command -v qrencode >/dev/null || apt-get install -y -qq qrencode >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq qrencode >/dev/null 2>&1; }
  python3 -c 'import telebot' 2>/dev/null || {
    command -v pip3 >/dev/null || apt-get install -y -qq python3-pip >/dev/null 2>&1 || { apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq python3-pip >/dev/null 2>&1; }
    pip3 install -q --break-system-packages pyTelegramBotAPI >/dev/null 2>&1
  }
  python3 -c 'import telebot' 2>/dev/null || { echo "${R}Не встала библиотека pyTelegramBotAPI.${N}"; return; }

  write_bot_py
  umask 077
  printf 'BOT_TOKEN=%s\nADMIN_ID=%s\n' "$token" "$id" > "$BOT_ENV"
  chmod 600 "$BOT_ENV"
  cat > "/etc/systemd/system/$BOT_SVC.service" <<EOF
[Unit]
Description=WARP Manager Telegram bot
After=network-online.target docker.service
Wants=network-online.target

[Service]
EnvironmentFile=$BOT_ENV
ExecStart=/usr/bin/python3 $BOT_DIR/bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$BOT_SVC" >/dev/null 2>&1
  sleep 3
  if systemctl is-active -q "$BOT_SVC"; then
    curl -s --max-time 10 "https://api.telegram.org/bot${token}/sendMessage" \
      -d chat_id="$id" -d text="🛰 Бот на связи. Жми /start" >/dev/null
    echo "${G}Готово. Бот @$uname запущен — в Telegram должно прийти сообщение.${N}"
  else
    echo "${R}Бот не запустился. Лог:${N}"
    journalctl -u "$BOT_SVC" -n 20 --no-pager
  fi
}

bot_menu() {
  while true; do
    clear
    echo "${W}━━━ Telegram-бот ━━━${N}"
    if [ -f "/etc/systemd/system/$BOT_SVC.service" ]; then
      if systemctl is-active -q "$BOT_SVC"; then echo "  Состояние: ${G}работает${N}"; else echo "  Состояние: ${R}остановлен${N}"; fi
      echo
      echo "  1) Перенастроить (другой токен / ID)"
      echo "  2) Перезапустить"
      echo "  3) Последние записи лога"
      echo "  9) ${R}Удалить бота с сервера${N}"
    else
      echo "  Состояние: не установлен"
      echo
      echo "  1) Установить и настроить"
    fi
    echo "  0) Назад"
    read -rp "Выбор: " ch
    case "$ch" in
      1) bot_setup; pause ;;
      2) write_bot_py; systemctl restart "$BOT_SVC"; sleep 2; systemctl is-active "$BOT_SVC"; pause ;;
      3) journalctl -u "$BOT_SVC" -n 30 --no-pager; pause ;;
      9) read -rp "Удалить бота с сервера? Напиши yes: " a
         if [ "$a" = "yes" ]; then
           systemctl disable --now "$BOT_SVC" >/dev/null 2>&1
           rm -f "/etc/systemd/system/$BOT_SVC.service"; systemctl daemon-reload
           rm -rf "$BOT_DIR"
           echo "Удалён. Сам бот в Telegram остался — удалить через @BotFather → /deletebot."
         fi; pause ;;
      0) return ;;
    esac
  done
}

bot_state() {
  if [ ! -f "/etc/systemd/system/$BOT_SVC.service" ]; then echo "не установлен"
  elif systemctl is-active -q "$BOT_SVC"; then echo "${G}работает${N}"
  else echo "${R}остановлен${N}"; fi
}

# ───────────────────────── пункты меню ─────────────────────────

cmd_clients() {
  is_installed || { echo "Сначала установи WARP (пункт 1)."; return; }
  load_names
  local ips=() names=() state=() pk ip wl
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip"); names+=("$(name_for "$pk" "$ip")")
  done < <(peer_records)
  [ ${#ips[@]} -eq 0 ] && { echo "Клиентов нет."; return; }
  wl=$(warp_ips)
  for ip in "${ips[@]}"; do echo "$wl" | grep -qx "$ip" && state+=(1) || state+=(0); done

  while true; do
    clear
    echo "${W}━━━ Клиенты WARP ━━━${N}  (номер — переключить)"
    local i
    for i in "${!ips[@]}"; do
      local box="❌"; [ "${state[$i]}" = "1" ] && box="✅"
      printf "   %d) %s %-12s %s\n" "$((i+1))" "$box" "${ips[$i]}" "${names[$i]}"
    done
    echo
    echo "   a) всех через WARP    n) всех напрямую"
    echo "   s) ${G}ПРИМЕНИТЬ${N}          0) назад без изменений"
    read -rp "> " sel
    case "$sel" in
      0) return ;;
      a|A) for i in "${!state[@]}"; do state[$i]=1; done ;;
      n|N) for i in "${!state[@]}"; do state[$i]=0; done ;;
      s|S)
        local on=()
        for i in "${!ips[@]}"; do [ "${state[$i]}" = "1" ] && on+=("${ips[$i]}"); done
        with_lock apply_warp_ips "${on[@]}"
        return ;;
      ''|*[!0-9]*) ;;
      *)
        if [ "$sel" -ge 1 ] && [ "$sel" -le "${#ips[@]}" ]; then
          i=$((sel-1)); [ "${state[$i]}" = "1" ] && state[$i]=0 || state[$i]=1
        fi ;;
    esac
  done
}

# выбор клиента по номеру; печатает IP
pick_client() {
  load_names
  local ips=() pk ip
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip"); echo "  ${#ips[@]}) $ip  $(name_for "$pk" "$ip")" >&2
  done < <(peer_records)
  [ ${#ips[@]} -eq 0 ] && { echo "Клиентов нет." >&2; return 1; }
  read -rp "Номер (Enter — отмена): " sel
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ips[@]}" ] || return 1
  echo "${ips[$((sel-1))]}"
}

cmd_add() {
  read -rp "Имя нового клиента (Enter — отмена): " nm
  [ -z "$nm" ] && return
  local out file
  out=$(with_lock do_add_client "$nm")
  file=$(echo "$out" | tail -1)
  echo "$out" | sed '$d'
  if [ -f "$file" ]; then
    echo "Конфиг: ${W}$file${N}"
    command -v qrencode >/dev/null || apt-get install -y -qq qrencode >/dev/null 2>&1
    command -v qrencode >/dev/null && qrencode -t ansiutf8 -r "$file" 2>/dev/null || echo "(QR не влез — импортируй файл)"
  else
    echo "$file"
  fi
}

cmd_del() {
  local ip
  ip=$(pick_client) || return
  read -rp "Удалить $ip? Ключ перестанет работать. Напиши yes: " a
  [ "$a" = "yes" ] && with_lock do_del_client "$ip"
}

cmd_rename() {
  local ip nn
  ip=$(pick_client) || return
  read -rp "Новое имя: " nn
  do_rename "$ip" "$nn" && echo "Ок."
}

cmd_remove() {
  echo "${R}Удалю WARP из $C: туннель, ключ, правила, блок в start.sh.${N}"
  echo "AmneziaWG и клиенты останутся, все пойдут напрямую."
  read -rp "Точно? Напиши yes: " ans
  [ "$ans" = "yes" ] || { echo "Отмена."; return; }
  with_lock do_remove_warp
}

# ───────────────────────── меню ─────────────────────────

menu() {
  while true; do
    clear
    local all on
    all=$(peer_records | grep -c . || true)
    on=$(warp_ips | grep -c . || true)
    echo "${B}════════════════════════════════════════${N}"
    echo "${W}  WARP Manager v$VERSION${N}"
    echo "${B}════════════════════════════════════════${N}"
    echo "  Контейнер: $C"
    echo "  WARP:      $(warp_state)"
    echo "  Через WARP: $on из $all клиентов"
    echo "  Бот:       $(bot_state)"
    echo
    echo "  ${B}── WARP ──${N}"
    echo "  1) Установить WARP"
    echo "  2) Статус"
    echo "  3) Клиенты WARP (вкл/выкл)"
    echo "  4) Перевыпуск ключа"
    echo "  ${B}── Клиенты AmneziaWG ──${N}"
    echo "  5) Добавить клиента"
    echo "  6) Удалить клиента"
    echo "  7) Переименовать клиента"
    echo "  ${B}── Прочее ──${N}"
    echo "  8) Telegram-бот"
    echo "  9) ${R}Удалить WARP${N}"
    echo "  0) Выход"
    read -rp "Выбор: " ch
    case "$ch" in
      1) with_lock do_install; pause ;;
      2) echo "${W}━━━ Статус ━━━${N}"; do_status; pause ;;
      3) cmd_clients; pause ;;
      4) with_lock do_reissue; pause ;;
      5) cmd_add; pause ;;
      6) cmd_del; pause ;;
      7) cmd_rename; pause ;;
      8) bot_menu ;;
      9) cmd_remove; pause ;;
      0) exit 0 ;;
    esac
  done
}

menu
