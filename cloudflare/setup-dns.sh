#!/bin/bash
# Создание DNS CNAME-записей для VPN-инфраструктуры
#
# Создаёт проксированные CNAME записи (оранжевое облако):
#   vpn1.example.com     → tunnel1.cfargotunnel.com (десктоп AWG)
#   vpn1-m.example.com   → tunnel1.cfargotunnel.com (мобильный VLESS)
#   ssh1.example.com     → tunnel1.cfargotunnel.com (SSH управление)
#   vpn2.example.com     → tunnel2.cfargotunnel.com (резерв)
#   vpn2-m.example.com   → tunnel2.cfargotunnel.com (резерв)
#   ssh2.example.com     → tunnel2.cfargotunnel.com (резерв)
#
# Использование: ./setup-dns.sh

source "$(dirname "$0")/common.sh"
check_required_vars CF_API_TOKEN CF_ZONE_ID CF_DOMAIN CF_TUNNEL_ID_NODE1

echo_header "Создание DNS-записей"

# Нода 1
TUNNEL1_TARGET="${CF_TUNNEL_ID_NODE1}.cfargotunnel.com"
echo "--- Нода 1 (${TUNNEL1_TARGET}) ---"
upsert_cname "vpn1"   "$TUNNEL1_TARGET"
upsert_cname "vpn1-m" "$TUNNEL1_TARGET"
upsert_cname "ssh1"   "$TUNNEL1_TARGET"

# Нода 2 (если настроена)
if [ -n "${CF_TUNNEL_ID_NODE2:-}" ] && [ "${CF_TUNNEL_ID_NODE2}" != "CHANGE_ME" ]; then
    TUNNEL2_TARGET="${CF_TUNNEL_ID_NODE2}.cfargotunnel.com"
    echo ""
    echo "--- Нода 2 (${TUNNEL2_TARGET}) ---"
    upsert_cname "vpn2"   "$TUNNEL2_TARGET"
    upsert_cname "vpn2-m" "$TUNNEL2_TARGET"
    upsert_cname "ssh2"   "$TUNNEL2_TARGET"
else
    echo ""
    echo "Нода 2 не настроена (CF_TUNNEL_ID_NODE2 не задан), пропускаю"
fi

echo ""
echo_header "Готово"
echo "Следующий шаг: ./cloudflare-settings.sh"
