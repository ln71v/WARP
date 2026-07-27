#!/usr/bin/env bash
# setup-warp-for-amneziawg.sh
set -eo pipefail

AWG_IFACE="awg0"
AWG_SUBNET="10.8.1.0/24"
WARP_IFACE="warp"
WARP_TABLE="51888"
WARP_RULE_PRIO="100"

[[ $EUID -ne 0 ]] && { echo "Запускай от root (sudo bash $0)" >&2; exit 1; }

if [[ ! -d "/sys/class/net/${AWG_IFACE}" ]]; then
    echo "ВНИМАНИЕ: Интерфейс ${AWG_IFACE} не найден в 'ip a'!" >&2
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

echo ">>> Правим конфиг WARP (чистим DNS, Table, оставляет только IPv4)"
# Оставляем только IPv4 в Address
sed -i -E 's/^([[:space:]]*Address[[:space:]]*=[[:space:]]*)([0-9.]+\/[0-9]+)(,.*)?$/\1\2/' "${CONF}"
# Оставляем только IPv4 в AllowedIPs (вырезаем ::/0)
sed -i -E 's/^[[:space:]]*AllowedIPs[[:space:]]*=.*/AllowedIPs = 0.0.0.0\/0/' "${CONF}"
# Сносим DNS и Table
sed -i -E 's/^[[:space:]]*DNS[[:space:]]*=.*//g' "${CONF}"
sed -i -E 's/^[[:space:]]*Table[[:space:]]*=.*//g' "${CONF}"
sed -i -E '/^[[:space:]]*$/d' "${CONF}"

# Отключаем автоматический дефолтный маршрут
sed -i "/\[Interface\]/a Table = off" "${CONF}"

# Чистим старые правила если перезапускаешь
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

echo ">>> Перезапускаем WARP"
systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
systemctl restart "wg-quick@${WARP_IFACE}"

sleep 2

echo ""
echo "=================================================================="
echo "Готово!"
echo "Проверка работы WARP:"
echo "  curl --interface ${WARP_IFACE} https://www.cloudflare.com/cdn-cgi/trace"
echo "=================================================================="
