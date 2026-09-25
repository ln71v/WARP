#!/usr/bin/env bash
# warp — менеджер Cloudflare WARP для AmneziaWG 2 (Docker, контейнер из приложения Amnezia).
# Репа: github.com/ln71v/WARP
# Запуск на хосте от root: warp
#
# Схема: клиент → amnezia-awg2 → интерфейс warp (внутри контейнера) → Cloudflare → интернет.
# Кто идёт через WARP — решается по IP клиента (ip rule, таблица 100). Остальные — напрямую.

set -uo pipefail

VERSION="1.0"
TABLE=100
WG_CONF="/opt/amnezia/awg/awg0.conf"
START_SH="/opt/amnezia/start.sh"
CLIENTS_TABLE="/opt/amnezia/awg/clientsTable"
NAMES_FILE="/opt/amnezia/client_names.txt"
WARP_DIR="/opt/warp"
WARP_CONF="/opt/warp/warp.conf"
BEGIN_MARK="# --- WARP-MANAGER BEGIN ---"
END_MARK="# --- WARP-MANAGER END ---"
WGCF_FALLBACK="v2.3.0"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; W=$'\e[1m'; N=$'\e[0m'

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

C=$(find_container) || { echo "${R}Не нашла запущенный контейнер AmneziaWG (amnezia-awg2).${N}"; echo "Поставь AmneziaWG (версия 2) через приложение Amnezia."; exit 1; }

dx() { docker exec "$C" "$@"; }

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
  dx awk -F'"' '
    /"clientId"/{id=$4}
    /"clientName"/{if(id!=""){print id"\t"$4; id=""}}
  ' "$CLIENTS_TABLE" 2>/dev/null
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

# ───────────────────────── состояние ─────────────────────────

is_installed() { dx test -f "$WARP_CONF" 2>/dev/null; }

warp_ips() {
  dx awk -v b="$BEGIN_MARK" -v e="$END_MARK" '
    $0==b{f=1; next}
    $0==e{f=0}
    f && /ip rule add from/ { for(i=1;i<=NF;i++) if($i=="from"){split($(i+1),a,"/"); print a[1]} }
  ' "$START_SH" 2>/dev/null
}

# возраст последнего контакта с Cloudflare в секундах, пусто — нет контакта
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

# ───────────────────────── применение правил ─────────────────────────

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

# применяем сразу, без перезапуска
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

# общий кусок: регистрация аккаунта и сборка warp.conf (выполняется внутри контейнера)
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

cmd_install() {
  if is_installed; then echo "${Y}WARP уже установлен.${N} Для нового ключа — пункт 4."; return; fi
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
  [ $? -eq 0 ] || { echo "${R}Установка не удалась.${N}"; return; }
  apply_warp_ips   # пустой список: блок автозапуска в start.sh, клиенты пока напрямую
  echo "${G}Готово.${N} Клиенты пока идут напрямую — включи нужных в пункте 3."
}

cmd_reissue() {
  is_installed || { echo "WARP не установлен."; return; }
  echo "Перевыпускаю ключ..."
  docker exec -i "$C" bash -s <<REMOTE
set -e
wg-quick down /opt/warp/warp.conf >/dev/null 2>&1 || true
$MAKE_PROFILE
wg-quick up /opt/warp/warp.conf >/dev/null
sleep 3
REMOTE
  # маршрут в таблице 100 пропадает вместе с интерфейсом — возвращаем
  dx sh -c "ip route replace default dev warp table $TABLE" 2>/dev/null
  echo "Новый ключ выпущен. Клиенты остались как были."
  echo "Связь: $(warp_state)"
}

# ───────────────────────── пункты меню ─────────────────────────

cmd_status() {
  echo "${W}━━━ Статус ━━━${N}"
  echo "  Контейнер: $C ($(docker inspect -f '{{.State.Status}}' "$C"))"
  echo "  WARP:      $(warp_state)"
  if is_installed; then
    local age; age=$(hs_age)
    [ -n "$age" ] && echo "  Последний ответ Cloudflare: ${age}с назад (норма до 180)"
    local wip
    wip=$(dx sh -c "curl -s4 --max-time 5 --interface warp https://ifconfig.me" 2>/dev/null)
    echo "  IP сервера: $(curl -s4 --max-time 5 https://ifconfig.me)"
    echo "  IP WARP:    ${wip:-не отвечает}"
  fi
  echo
  echo "  Клиенты:"
  load_names
  local wl pk ip mark
  wl=$(warp_ips)
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    if echo "$wl" | grep -qx "$ip"; then mark="${G}WARP${N}"; else mark="напрямую"; fi
    printf "    %-12s %-28s %s\n" "$ip" "$(name_for "$pk" "$ip")" "$mark"
  done < <(peer_records)
}

cmd_clients() {
  is_installed || { echo "Сначала установи WARP (пункт 1)."; return; }
  load_names
  local ips=() names=() state=() pk ip wl
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip"); names+=("$(name_for "$pk" "$ip")")
  done < <(peer_records)
  [ ${#ips[@]} -eq 0 ] && { echo "Клиентов нет. Добавь в приложении Amnezia."; return; }
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
        apply_warp_ips "${on[@]}"
        return ;;
      ''|*[!0-9]*) ;;
      *)
        if [ "$sel" -ge 1 ] && [ "$sel" -le "${#ips[@]}" ]; then
          i=$((sel-1)); [ "${state[$i]}" = "1" ] && state[$i]=0 || state[$i]=1
        fi ;;
    esac
  done
}

cmd_rename() {
  load_names
  local ips=() pk ip i
  while IFS=$'\t' read -r pk ip; do
    [ -z "$ip" ] && continue
    ips+=("$ip"); echo "  ${#ips[@]}) $ip  $(name_for "$pk" "$ip")"
  done < <(peer_records)
  [ ${#ips[@]} -eq 0 ] && { echo "Клиентов нет."; return; }
  read -rp "Номер (Enter — отмена): " sel
  [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#ips[@]}" ] || return
  read -rp "Новое имя: " nn
  nn=$(echo "$nn" | tr -d "=\"'\\\\\`\$")
  [ -z "$nn" ] && return
  ip="${ips[$((sel-1))]}"
  dx sh -c "touch $NAMES_FILE; grep -v '^$ip=' $NAMES_FILE > $NAMES_FILE.tmp; echo '$ip=$nn' >> $NAMES_FILE.tmp; mv $NAMES_FILE.tmp $NAMES_FILE"
  echo "Ок."
}

cmd_remove() {
  echo "${R}Удалю WARP из $C: туннель, ключ, правила, блок в start.sh.${N}"
  echo "AmneziaWG и клиенты останутся, все пойдут напрямую."
  read -rp "Точно? Напиши yes: " ans
  [ "$ans" = "yes" ] || { echo "Отмена."; return; }
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
    echo "  Клиентов через WARP: $on из $all"
    echo
    echo "  1) Установить WARP"
    echo "  2) Статус"
    echo "  3) Клиенты WARP (вкл/выкл)"
    echo "  4) Перевыпуск ключа"
    echo "  5) Переименовать клиента"
    echo "  9) ${R}Удалить WARP${N}"
    echo "  0) Выход"
    read -rp "Выбор: " ch
    case "$ch" in
      1) cmd_install; pause ;;
      2) cmd_status; pause ;;
      3) cmd_clients; pause ;;
      4) cmd_reissue; pause ;;
      5) cmd_rename; pause ;;
      9) cmd_remove; pause ;;
      0) exit 0 ;;
    esac
  done
}

menu
