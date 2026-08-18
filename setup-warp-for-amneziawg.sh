#!/usr/bin/env bash
# warp.sh — единый упрощённый менеджер WARP для AmneziaWG-контейнеров.
# Аналог платного скрипта с меню, но без телеграм-бота, SOCKS5-меню и промо.
#
# Один механизм на всё: per-client ip rule (таблица 100) + iptables MASQUERADE
# через интерфейс warp. "Запустить/Остановить всем" — это тот же механизм,
# применённый ко всем/никому — конфликтов приоритетов не бывает.
#
# Имена клиентов — из родного /opt/amnezia/awg/clientsTable (сопоставление
# по PublicKey), с возможностью ручного переопределения.
#
# Запускать на ХОСТЕ, от root, там где стоит docker.

set -uo pipefail

TABLE=100
WG_CONF="/opt/amnezia/awg/awg0.conf"
START_SH="/opt/amnezia/start.sh"
CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
NAMES_FILE="/opt/amnezia/client_names.txt"
WARP_CONF="/opt/warp/warp.conf"
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"

# ───────────────────────── контейнеры ─────────────────────────

list_containers() {
  docker ps --format '{{.Names}}' | grep -E '^amnezia-awg' || true
}

pick_container() {
  local containers=($(list_containers))
  if [ ${#containers[@]} -eq 0 ]; then
    echo "Контейнеры amnezia-awg* не найдены." >&2
    return 1
  fi
  echo "Выберите контейнер:" >&2
  local i=1
  for c in "${containers[@]}"; do
    echo "  $i) $c" >&2
    i=$((i+1))
  done
  echo "  0) Отмена" >&2
  read -rp "> " sel
  if [ "$sel" = "0" ] || [ -z "$sel" ]; then return 1; fi
  if ! [ "$sel" -ge 1 ] 2>/dev/null || ! [ "$sel" -le "${#containers[@]}" ] 2>/dev/null; then
    echo "Нет такого номера." >&2
    return 1
  fi
  echo "${containers[$((sel-1))]}"
}

# ───────────────────────── клиенты и имена ─────────────────────────

# "pubkey<TAB>ip" для каждого реального [Peer] в awg0.conf
peer_records() {
  local c="$1"
  docker exec "$c" awk '
    /^\[Peer\]/{pk=""; ip=""}
    /^PublicKey/{split($0,a,"= "); pk=a[2]}
    /^AllowedIPs/{split($0,a,"= "); ip=a[2]; sub("/32","",ip); if(pk!="") print pk"\t"ip}
  ' "$WG_CONF" 2>/dev/null
}

# "pubkey<TAB>имя" из родного clientsTable Amnezia
native_names() {
  local c="$1"
  docker exec "$c" awk -F'"' '
    /"clientId"/{id=$4}
    /"clientName"/{if(id!=""){print id"\t"$4; id=""}}
  ' "$CLIENTS_TABLE" 2>/dev/null
}

manual_names_raw() {
  local c="$1"
  docker exec "$c" sh -c "touch $NAMES_FILE; cat $NAMES_FILE" 2>/dev/null
}

set_manual_name() {
  local c="$1" ip="$2" name="$3"
  docker exec "$c" sh -c "
    touch $NAMES_FILE
    grep -v \"^$ip=\" $NAMES_FILE > $NAMES_FILE.tmp 2>/dev/null
    echo '$ip=$name' >> $NAMES_FILE.tmp
    mv $NAMES_FILE.tmp $NAMES_FILE
  "
}

declare -A NNAMES MNAMES

load_name_caches() {
  local c="$1"
  NNAMES=()
  MNAMES=()
  local pk name ip
  while IFS=$'\t' read -r pk name; do
    [ -n "$pk" ] && NNAMES["$pk"]="$name"
  done < <(native_names "$c")
  while IFS='=' read -r ip name; do
    [ -n "$ip" ] && MNAMES["$ip"]="$name"
  done < <(manual_names_raw "$c")
}

name_for() {
  local pk="$1" ip="$2"
  if [ -n "${MNAMES[$ip]:-}" ]; then echo "${MNAMES[$ip]}"; return; fi
  if [ -n "${NNAMES[$pk]:-}" ]; then echo "${NNAMES[$pk]}"; return; fi
  echo "$ip"
}

# ───────────────────────── состояние WARP ─────────────────────────

is_installed() {
  local c="$1"
  docker exec "$c" test -f "$WARP_CONF" 2>/dev/null && echo yes || echo no
}

warp_ips() {
  local c="$1"
  docker exec "$c" awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b{f=1; next}
    $0==e{f=0}
    f && /ip rule add from/ {
      for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]}
    }
  ' "$START_SH" 2>/dev/null
}

# Применяет заданный список IP как "через WARP", остальные — напрямую.
# $1 = контейнер, далее — список IP.
apply_warp_ips() {
  local c="$1"; shift
  docker exec -i "$c" bash -s -- "$@" <<'REMOTE'
set -e
TABLE=100
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"
START_SH="/opt/amnezia/start.sh"

if [ ! -f /opt/warp/warp.conf ]; then
  echo "WARP не установлен (нет /opt/warp/warp.conf). Сначала пункт 'Установить WARP'."
  exit 1
fi

wg show warp >/dev/null 2>&1 || wg-quick up /opt/warp/warp.conf || true

cp "$START_SH" "${START_SH}.bak.$(date +%s)"

OLD_IPS=$(awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b{f=1; next}
  $0==e{f=0}
  f && /ip rule add from/ {
    for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]}
  }
' "$START_SH")

for ip in $OLD_IPS; do
  ip rule del from "$ip/32" table $TABLE 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "$ip/32" -o warp -j MASQUERADE 2>/dev/null || true
done

awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
  $0==b{skip=1}
  !skip{print}
  $0==e{skip=0}
' "$START_SH" > "${START_SH}.stripped"

{
  echo "$BEGIN_MARK"
  echo "if [ -f '/opt/warp/warp.conf' ]; then"
  echo "  wg-quick up '/opt/warp/warp.conf' || true"
  echo "  sleep 3"
  echo "fi"
  echo "ip route add default dev warp table $TABLE 2>/dev/null || ip route replace default dev warp table $TABLE 2>/dev/null || true"
  echo "iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true"
  prio=100
  for ip in "$@"; do
    echo "ip rule add from $ip/32 table $TABLE priority $prio 2>/dev/null || true"
    echo "iptables -t nat -C POSTROUTING -s $ip/32 -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s $ip/32 -o warp -j MASQUERADE"
    prio=$((prio+1))
  done
  echo "$END_MARK"
} >> "${START_SH}.stripped"

mv "${START_SH}.stripped" "$START_SH"
chmod +x "$START_SH"

prio=100
for ip in "$@"; do
  ip route add default dev warp table $TABLE 2>/dev/null || ip route replace default dev warp table $TABLE 2>/dev/null || true
  ip rule add from "$ip/32" table $TABLE priority $prio 2>/dev/null || true
  iptables -t nat -C POSTROUTING -s "$ip/32" -o warp -j MASQUERADE 2>/dev/null || iptables -t nat -I POSTROUTING 1 -s "$ip/32" -o warp -j MASQUERADE
  prio=$((prio+1))
done
echo "Применено."
REMOTE
}

# ───────────────────────── установка / ключ ─────────────────────────

cmd_install() {
  local c="$1"
  docker exec -i "$c" bash -s <<REMOTE
set -e
if [ -f '$WARP_CONF' ]; then
  echo "Уже установлено ($WARP_CONF существует)."
  exit 0
fi
echo "Ставлю пакеты..."
apk add --no-cache wireguard-tools curl >/dev/null

ARCH=\$(uname -m)
case "\$ARCH" in
  x86_64) WGCF_ARCH=amd64 ;;
  aarch64) WGCF_ARCH=arm64 ;;
  armv7l) WGCF_ARCH=armv7 ;;
  *) echo "Неизвестная архитектура: \$ARCH"; exit 1 ;;
esac

echo "Качаю wgcf..."
URL=\$(curl -s https://api.github.com/repos/ViRb3/wgcf/releases/latest \
  | grep browser_download_url | grep "linux_\${WGCF_ARCH}" | cut -d '"' -f4)
if [ -z "\$URL" ]; then echo "Не нашёл ссылку на wgcf-бинарник"; exit 1; fi
curl -L -o /usr/local/bin/wgcf "\$URL"
chmod +x /usr/local/bin/wgcf

mkdir -p /opt/warp
cd /opt/warp
echo "Регистрирую WARP-аккаунт..."
wgcf register --accept-tos
wgcf generate
cp wgcf-profile.conf warp.conf
awk '/^\[Interface\]/{print; print "Table = off"; next}{print}' warp.conf > warp.conf.new && mv warp.conf.new warp.conf
echo "Установка завершена."
REMOTE
}

cmd_reissue() {
  local c="$1"
  docker exec -i "$c" bash -s <<REMOTE
set -e
if [ ! -f '$WARP_CONF' ]; then
  echo "WARP не установлен."
  exit 1
fi
wg-quick down '$WARP_CONF' 2>/dev/null || true
cd /opt/warp
rm -f wgcf-account.toml wgcf-profile.conf warp.conf
echo "Регистрирую новый WARP-аккаунт..."
wgcf register --accept-tos
wgcf generate
cp wgcf-profile.conf warp.conf
awk '/^\[Interface\]/{print; print "Table = off"; next}{print}' warp.conf > warp.conf.new && mv warp.conf.new warp.conf
wg-quick up '$WARP_CONF'
sleep 2
echo "Новый ключ выпущен, интерфейс поднят. Правила клиентов не трогал — кто был через WARP, тот и остался."
wg show warp
REMOTE
}

# ───────────────────────── меню-действия ─────────────────────────

cmd_start_all() {
  local c
  c=$(pick_container) || return
  local all=()
  while IFS=$'\t' read -r pk ip; do
    [ -n "$ip" ] && all+=("$ip")
  done < <(peer_records "$c")
  if [ ${#all[@]} -eq 0 ]; then echo "Клиентов нет."; return; fi
  apply_warp_ips "$c" "${all[@]}"
}

cmd_stop_all() {
  local c
  c=$(pick_container) || return
  apply_warp_ips "$c"
}

show_clients() {
  for c in $(list_containers); do
    echo "=== $c ==="
    load_name_caches "$c"
    local warp_list
    warp_list=$(warp_ips "$c")
    while IFS=$'\t' read -r pk ip; do
      [ -z "$ip" ] && continue
      local name mark
      name=$(name_for "$pk" "$ip")
      if echo "$warp_list" | grep -qx "$ip"; then mark="WARP"; else mark="direct"; fi
      printf "  %-15s %-25s %s\n" "$ip" "$name" "$mark"
    done < <(peer_records "$c")
  done
}

toggle_menu() {
  local c
  c=$(pick_container) || return
  load_name_caches "$c"

  local ips=() names=()
  local pk ip
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip")
    names+=("$(name_for "$pk" "$ip")")
  done < <(peer_records "$c")

  if [ ${#ips[@]} -eq 0 ]; then echo "Клиентов нет."; return; fi

  local warp_list
  warp_list=$(warp_ips "$c")
  local state=()
  for ip in "${ips[@]}"; do
    if echo "$warp_list" | grep -qx "$ip"; then state+=(1); else state+=(0); fi
  done

  while true; do
    echo "━━━ Управление клиентами WARP ━━━"
    echo "  Контейнер: $c"
    local i=1
    for ip in "${ips[@]}"; do
      local box
      if [ "${state[$((i-1))]}" = "1" ]; then box="✅"; else box="☐ "; fi
      printf "   %d) %s   %s (%s)\n" "$i" "$box" "$ip" "${names[$((i-1))]}"
      i=$((i+1))
    done
    local on=0
    for s in "${state[@]}"; do if [ "$s" = "1" ]; then on=$((on+1)); fi; done
    echo "  Через WARP: $on из ${#ips[@]}"
    echo "  all) Включить всех   none) Выключить всех"
    echo "  ok)  Применить        0) Отмена (без изменений)"
    read -rp "> " sel
    case "$sel" in
      0) return ;;
      ok)
        local enabled=()
        for idx in "${!ips[@]}"; do
          if [ "${state[$idx]}" = "1" ]; then enabled+=("${ips[$idx]}"); fi
        done
        apply_warp_ips "$c" "${enabled[@]}"
        return
        ;;
      all) for idx in "${!state[@]}"; do state[$idx]=1; done ;;
      none) for idx in "${!state[@]}"; do state[$idx]=0; done ;;
      ''|*[!0-9]*) echo "Неверный ввод" ;;
      *)
        if [ "$sel" -ge 1 ] && [ "$sel" -le "${#ips[@]}" ]; then
          local idx=$((sel-1))
          if [ "${state[$idx]}" = "1" ]; then state[$idx]=0; else state[$idx]=1; fi
        else
          echo "Нет такого номера"
        fi
        ;;
    esac
  done
}

rename_menu() {
  local c
  c=$(pick_container) || return
  load_name_caches "$c"

  local ips=() names=()
  local pk ip
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip")
    names+=("$(name_for "$pk" "$ip")")
  done < <(peer_records "$c")

  local i=1
  for ip in "${ips[@]}"; do
    echo "  $i) $ip (${names[$((i-1))]})"
    i=$((i+1))
  done
  read -rp "Номер клиента: " sel
  if [ -z "$sel" ]; then return; fi
  local idx=$((sel-1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "${#ips[@]}" ]; then
    echo "Нет такого номера"
    return
  fi
  read -rp "Новое имя: " newname
  set_manual_name "$c" "${ips[$idx]}" "$newname"
  echo "Ок."
}

status_menu() {
  for c in $(list_containers); do
    local inst
    inst=$(is_installed "$c")
    echo "=== $c ==="
    echo "  Установлен: $inst"
    if [ "$inst" = "yes" ]; then
      local hs
      hs=$(docker exec "$c" wg show warp latest-handshakes 2>/dev/null | awk '{print $2}')
      if [ -z "$hs" ] || [ "$hs" = "0" ]; then
        echo "  WARP handshake: НЕТ (туннель не поднят)"
      else
        local age=$(( $(date +%s) - hs ))
        echo "  WARP handshake: ${age}с назад"
      fi
      local total on
      total=$(peer_records "$c" | wc -l)
      on=$(warp_ips "$c" | grep -c . || true)
      echo "  Через WARP: $on из $total клиентов"
    fi
  done
}

check_containers() {
  for c in $(list_containers); do
    local status
    status=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)
    echo "=== $c ($status) ==="
  done
}

# ───────────────────────── главное меню ─────────────────────────

menu() {
  while true; do
    echo ""
    echo "=== WARP-manager: AmneziaWG ==="
    echo "1) Установить WARP"
    echo "2) Запустить WARP (всем клиентам)"
    echo "3) Остановить WARP (всем клиентам)"
    echo "4) Статус"
    echo "5) Перевыпуск ключа"
    echo "6) Список клиентов"
    echo "7) Управление клиентами WARP (по одному)"
    echo "8) Проверить контейнеры"
    echo "9) Переименовать клиента"
    echo "0) Выход"
    read -rp "Выбор: " ch
    case "$ch" in
      1) c=$(pick_container) && cmd_install "$c" ;;
      2) cmd_start_all ;;
      3) cmd_stop_all ;;
      4) status_menu ;;
      5) c=$(pick_container) && cmd_reissue "$c" ;;
      6) show_clients ;;
      7) toggle_menu ;;
      8) check_containers ;;
      9) rename_menu ;;
      0) exit 0 ;;
      *) echo "Неверный выбор" ;;
    esac
  done
}

menu
