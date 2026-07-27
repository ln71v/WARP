#!/usr/bin/env bash
#
# setup-warp-for-amneziawg.sh
#
# Поднимает Cloudflare WARP (через wgcf) на VPS с AmneziaWG и заворачивает
# в него ТОЛЬКО трафик клиентов AmneziaWG. Собственный (системный) трафик
# VPS через WARP не идёт.
#
# Тестировалось под Ubuntu 22.04 / 24.04.
# Запускать от root: sudo bash setup-warp-for-amneziawg.sh
#
set -euo pipefail

# ==================== НАСТРОЙКИ — ПРОВЕРЬТЕ ПЕРЕД ЗАПУСКОМ ====================
# Узнать интерфейс AmneziaWG:  ip a   (обычно awg0)
AWG_IFACE="awg0"

# Узнать подсеть клиентов AmneziaWG: посмотрите Address/AllowedIPs
# в конфиге сервера, обычно /etc/amnezia/awg/awg0.conf -> [Interface] Address
AWG_SUBNET="10.8.1.0/24"

WARP_IFACE="warp"          # имя WireGuard-интерфейса для WARP
WARP_TABLE="51888"         # номер отдельной таблицы маршрутизации (произвольный, не занятый)
WARP_RULE_PRIORITY="100"   # приоритет ip rule
# ================================================================================

if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от root (sudo bash $0)" >&2
    exit 1
fi

if [[ ! -d "/sys/class/net/${AWG_IFACE}" ]]; then
    echo "ВНИМАНИЕ: интерфейс ${AWG_IFACE} не найден." >&2
    echo "Проверьте 'ip a' и поправьте переменную AWG_IFACE в начале скрипта." >&2
    read -rp "Продолжить всё равно? [y/N] " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || exit 1
fi

echo ">>> Обновление пакетов и установка зависимостей"
apt-get update -y
apt-get install -y wireguard wireguard-tools curl iptables resolvconf jq

echo ">>> Определение последней версии wgcf"
WGCF_TAG=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest | jq -r .tag_name)
WGCF_VERSION="${WGCF_TAG#v}"
echo "    Последняя версия: ${WGCF_VERSION}"

ARCH=$(dpkg --print-architecture)
case "${ARCH}" in
    amd64) WGCF_ARCH="linux_amd64" ;;
    arm64) WGCF_ARCH="linux_arm64" ;;
    armhf) WGCF_ARCH="linux_armv7" ;;
    *) echo "Неизвестная архитектура: ${ARCH}" >&2; exit 1 ;;
esac

echo ">>> Установка wgcf ${WGCF_VERSION} (${WGCF_ARCH})"
curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/${WGCF_TAG}/wgcf_${WGCF_VERSION}_${WGCF_ARCH}" -o /usr/local/bin/wgcf
chmod +x /usr/local/bin/wgcf

mkdir -p /etc/wgcf
cd /etc/wgcf

if [[ ! -f wgcf-account.toml ]]; then
    echo ">>> Регистрация нового аккаунта WARP"
    wgcf register --accept-tos
else
    echo ">>> Аккаунт wgcf уже существует, регистрация пропущена"
fi

echo ">>> Генерация WireGuard-профиля для WARP"
wgcf generate

echo ">>> Настройка интерфейса ${WARP_IFACE}"
cp -f wgcf-profile.conf "/etc/wireguard/${WARP_IFACE}.conf"
chmod 600 "/etc/wireguard/${WARP_IFACE}.conf"

CONF="/etc/wireguard/${WARP_IFACE}.conf"

# Убираем автоматическую таблицу маршрутизации по умолчанию —
# иначе WARP заберёт себе весь трафик VPS
if grep -q "^Table" "${CONF}"; then
    sed -i 's/^Table.*/Table = off/' "${CONF}"
else
    sed -i "/\[Interface\]/a Table = off" "${CONF}"
fi

# Убираем DNS-строку из профиля wgcf, чтобы не трогать системный резолвинг
sed -i '/^DNS/d' "${CONF}"

# Чистим возможные старые PostUp/PostDown с прошлых запусков скрипта
sed -i '/^PostUp/d;/^PostDown/d' "${CONF}"

cat >> "${CONF}" <<EOF

PostUp = ip route replace default dev ${WARP_IFACE} table ${WARP_TABLE}
PostUp = ip rule add from ${AWG_SUBNET} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIORITY}
PostUp = iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE

PostDown = ip rule del from ${AWG_SUBNET} lookup ${WARP_TABLE} priority ${WARP_RULE_PRIORITY} 2>/dev/null || true
PostDown = ip route flush table ${WARP_TABLE} 2>/dev/null || true
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${WARP_IFACE} -j MASQUERADE 2>/dev/null || true
EOF

echo ">>> Включение IP forwarding"
if ! grep -q "^net.ipv4.ip_forward" /etc/sysctl.conf; then
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
else
    sed -i 's/^net.ipv4.ip_forward.*/net.ipv4.ip_forward = 1/' /etc/sysctl.conf
fi
sysctl -p >/dev/null

echo ">>> Запуск интерфейса ${WARP_IFACE}"
systemctl enable "wg-quick@${WARP_IFACE}" >/dev/null 2>&1
systemctl restart "wg-quick@${WARP_IFACE}"

sleep 2

echo ""
echo "=================================================================="
echo "Готово."
echo ""
echo "Проверка статуса:"
echo "  wg show                        — интерфейсы awg0 и warp должны быть UP"
echo "  ip rule list                   — должно быть правило: from ${AWG_SUBNET} lookup ${WARP_TABLE}"
echo "  ip route show table ${WARP_TABLE}   — должен быть default dev ${WARP_IFACE}"
echo ""
echo "Проверка что WARP реально работает (запускать НА СЕРВЕРЕ):"
echo "  curl --interface ${WARP_IFACE} https://www.cloudflare.com/cdn-cgi/trace"
echo "  (в ответе должно быть warp=on)"
echo ""
echo "Трафик клиентов из подсети ${AWG_SUBNET} (AmneziaWG) теперь идёт"
echo "через Cloudflare WARP. Собственный трафик VPS — без изменений."
echo "=================================================================="
