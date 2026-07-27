#!/usr/bin/env bash
# setup-warp-for-amneziawg.sh (Gema edition)
set -eo pipefail

WARP_IFACE="warp"
WARP_TABLE="51888"
WARP_RULE_PRIO="100"
FWMARK="0x1e0"

[[ $EUID -ne 0 ]] && { echo "Запускай от root (sudo bash $0)" >&2; exit 1; }

if ! command -v docker &>/dev/null; then
    echo "ОШИБКА: docker не найден." >&2
    exit 1
fi

echo ">>> Ищем контейнер AmneziaWG"
AWG_CONTAINER=$(docker ps --format '{{.Names}}' | grep -im1 'awg')
[[ -z "$AWG_CONTAINER" ]] && { echo "ОШИБКА: Не найден контейнер с 'awg'." >&2; exit 1; }
echo "    Найден: ${AWG_CONTAINER}"

echo ">>> Определяем параметры сети"
AWG_NETWORK=$(docker inspect "$AWG_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{if ne $k "bridge"}}{{$k}}{{end}}{{end}}')
[[ -z "${AWG_NETWORK}" ]] && { echo "ОШИБКА: docker-сеть не найдена." >&2; exit 1; }
echo "    Сеть: ${AWG_NETWORK}"

# Жестко режем IPv6, берем только IPv4
AWG_SUBNET=$(docker network inspect "$AWG_NETWORK" --format '{{range .IPAM.Config}}{{println .Subnet}}{{end}}' | grep -v ':' | head -n 1)
[[ -z "${AWG_SUBNET}" ]] && { echo "ОШИБКА: IPv4 подсеть не найдена." >&2; exit 1; }
echo "    Подсеть (IPv4): ${AWG_SUBNET}"

AWG_BRIDGE=$(docker network inspect "$AWG_NETWORK" --format '{{index .Options "com.docker.network.bridge.name"}}')
[[ -z "$AWG_BRIDGE" ]] && AWG_BRIDGE="br-$(docker network inspect "$AWG_NETWORK" --format '{{.Id}}' | cut -c1-12)"
[[ ! -d "/sys/class/net/${AWG_BRIDGE}" ]] && { echo "ОШИБКА: bridge ${AWG_BRIDGE} не существует в системе." >&2; exit 1; }
echo "    Bridge: ${AWG_BRIDGE}"

AWG_PORT=$(docker port "$AWG_CONTAINER" | grep -m1 'udp' | awk -F ':' '{print $NF}')
[[ -z "${AWG_PORT}" ]] && { echo "ОШИБКА: UDP-порт не найден." >&2; exit 1; }
echo "    UDP-порт: ${AWG_PORT}"

echo ">>> Установка пакетов"
apt-get update -y && apt-get install -y wireguard wireguard-tools curl jq iptables

ARCH=$(dpkg --print-architecture)
case "${ARCH}" in
    amd64) WGCF_ARCH="linux_amd64" ;;
    arm64) WGCF_ARCH="linux_arm64" ;;
    *) echo "Неподдерживаемая архитектура: ${ARCH}" >&2; exit 1 ;;
esac

if [[ ! -x /usr/local/bin/wgcf ]] || [[ ! -s /usr/local/bin/wgcf ]]; then
    echo ">>> Скачиваем wgcf"
    WGCF_TAG=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r .tag_name)
    curl -fL "https://github.com/ViRb3/wgcf/releases/download/${WGCF_TAG}/wgcf_${WGCF_TAG#v}_${WGCF_ARCH}" -o /usr/local/bin/wgcf
    chmod +x /usr/local/bin/wgcf
fi

mkdir -p /etc/wgcf && cd /etc/wgcf
[[ ! -f wgcf-account.toml ]] && wgcf register --accept-tos
[[ ! -f wgcf-profile.conf ]] && wgcf generate

echo ">>> Собираем конфиг ${WARP_IFACE}"
PRIVATE_KEY=$(grep -m1 -E '^\s*PrivateKey\s*=' wgcf-profile.conf | sed -E 's/^\s*PrivateKey\s*=\s*//')
ADDRESS_V4=$(grep -m1 -E '^\s*Address\s*=' wgcf-profile.conf | sed -E 's/^\s*Address\s*=\s*//' | tr ',' '\n' | grep -m1 -E '^[0-9.]+/[0-9]+\s*$' | tr -d '[:space:]')
PEER_PUBLIC_KEY=$(grep -m1 -E '^\s*PublicKey\s*=' wgcf-profile.conf | sed -E 's/^\s*PublicKey\s*=\s*//')
ENDPOINT=$(grep -m1 -E '^\s*Endpoint\s*=' wgcf-profile.conf | sed -E 's/^\s*Endpoint\s*=\s*//')

CONF="/etc/wireguard/${WARP_IFACE}.conf"
cat > "${CONF}" <<EOF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${ADDRESS_V4}
Table = off

PostUp = iptables -t mangle -I PREROUTING -i ${AWG_BRIDGE} -s ${AWG_SUBNET} -p udp --sport ${AWG_PORT} -j RETURN
PostUp = iptables -t mangle -A PREROUTING -i ${AWG_BRIDGE} -s ${AWG_SUBNET} -j MARK --set-mark ${FWMARK}
PostUp = ip rule add fwmark ${FWMARK} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIO}
PostUp = ip route replace default dev ${WARP_IFACE} table ${WARP_TABLE}
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE

PostDown = ip rule del fwmark ${FWMARK} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIO} 2>/dev/null || true
PostDown = ip route flush table ${WARP_TABLE} 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i ${AWG_BRIDGE} -s ${AWG_SUBNET} -p udp --sport ${AWG_PORT} -j RETURN 2>/dev/null || true
PostDown = iptables -t mangle -D PREROUTING -i ${AWG_BRIDGE} -s ${AWG_SUBNET} -j MARK --set-mark ${FWMARK} 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE 2>/dev/null || true

[Peer]
PublicKey = ${PEER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0
Endpoint = ${ENDPOINT}
EOF
chmod 600 "${CONF}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "^net.ipv4.ip_forward = 1" /etc/sysctl.conf || echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf

systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
systemctl restart "wg-quick@${WARP_IFACE}"

echo "Готово. Порт ${AWG_PORT} исключен, подсеть ${AWG_SUBNET} завернута в WARP."
