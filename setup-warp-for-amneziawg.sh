#!/usr/bin/env bash
# setup-warp-for-amneziawg.sh
# Заворачивает трафик клиентов AmneziaWG (Docker-контейнер amnezia-awg2)
# через Cloudflare WARP. Собственный трафик VPS не трогается.
set -eo pipefail

AWG_SUBNET="172.29.172.0/24"    # подсеть Docker-сети amnezia-dns-net (amn0)
AWG_CONTAINER="amnezia-awg2"    # имя контейнера с AmneziaWG
WARP_IFACE="warp"
WARP_TABLE="51888"
WARP_RULE_PRIO="100"

[[ $EUID -ne 0 ]] && { echo "Запускай от root (sudo bash $0)" >&2; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -q "^${AWG_CONTAINER}\$"; then
    echo "ВНИМАНИЕ: контейнер ${AWG_CONTAINER} не найден или не запущен!" >&2
    docker ps -a --format '  - {{.Names}} ({{.Status}})' 2>/dev/null
    read -rp "Продолжить всё равно? [y/N] " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || exit 1
fi

echo ">>> Установка пакетов"
apt-get update -y && apt-get install -y wireguard wireguard-tools curl jq iptables

ARCH=$(dpkg --print-architecture)
case "${ARCH}" in
    amd64) WGCF_ARCH="linux_amd64" ;;
    arm64) WGCF_ARCH="linux_arm64" ;;
    *) echo "Неподдерживаемая архитектура: ${ARCH}" >&2; exit 1 ;;
esac

if ! command -v wgcf &>/dev/null; then
    echo ">>> Скачиваем wgcf"
    WGCF_TAG=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r .tag_name)
    curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/${WGCF_TAG}/wgcf_${WGCF_TAG#v}_${WGCF_ARCH}" -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
fi

mkdir -p /etc/wgcf && cd /etc/wgcf
[[ ! -f wgcf-account.toml ]] && wgcf register --accept-tos || true
[[ ! -f wgcf-profile.conf ]] && wgcf generate || true

CONF="/etc/wireguard/${WARP_IFACE}.conf"
cp -f wgcf-profile.conf "${CONF}"
chmod 600 "${CONF}"

echo ">>> Правим конфиг WARP (чистим DNS, Table, оставляем только IPv4)"
sed -i -E 's/^([[:space:]]*Address[[:space:]]*=[[:space:]]*)([0-9.]+\/[0-9]+)(,.*)?$/\1\2/' "${CONF}"
sed -i -E 's/^[[:space:]]*AllowedIPs[[:space:]]*=.*/AllowedIPs = 0.0.0.0\/0/' "${CONF}"
sed -i -E 's/^[[:space:]]*DNS[[:space:]]*=.*//g' "${CONF}"
sed -i -E 's/^[[:space:]]*Table[[:space:]]*=.*//g' "${CONF}"
sed -i -E '/^[[:space:]]*$/d' "${CONF}"
sed -i "/\[Interface\]/a Table = off" "${CONF}"
sed -i '/^PostUp/d;/^PostDown/d' "${CONF}"

cat >> "${CONF}" <<EOF
PostUp = ip route replace default dev ${WARP_IFACE} table ${WARP_TABLE}
PostUp = ip rule add from ${AWG_SUBNET} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIO}
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE
PostDown = ip rule del from ${AWG_SUBNET} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIO} 2>/dev/null || true
PostDown = ip route flush table ${WARP_TABLE} 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE 2>/dev/null || true
EOF

echo ">>> Включаем ip_forward"
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

echo ">>> Запускаем WARP"
systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
systemctl restart "wg-quick@${WARP_IFACE}"
sleep 2

echo ""
echo "=================================================================="
echo "Готово!"
echo ""
echo "Проверка:"
echo "  wg show                              — интерфейс ${WARP_IFACE} должен быть активен"
echo "  ip rule list                         — должно быть: from ${AWG_SUBNET} lookup ${WARP_TABLE}"
echo "  curl --interface ${WARP_IFACE} https://www.cloudflare.com/cdn-cgi/trace   — warp=on"
echo ""
echo "Трафик клиентов AmneziaWG (${AWG_SUBNET}) теперь идёт через WARP."
echo "Публичный IP этого VPS для внешних сайтов должен быть скрыт под IP Cloudflare WARP."
echo "=================================================================="
