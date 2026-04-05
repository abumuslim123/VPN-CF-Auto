#!/bin/bash
# Ротация домена при блокировке DPI
#
# При блокировке субдомена:
#   1. Генерирует случайный субдомен
#   2. Создаёт новую CNAME-запись
#   3. Обновляет ingress cloudflared на exit-ноде
#   4. Перезапускает cloudflared
#   5. Уведомляет через Telegram
#
# Использование:
#   ./rotate-domain.sh --node 1 --type desktop
#   ./rotate-domain.sh --node 1 --type mobile
#   ./rotate-domain.sh --node 1 --type both
#   ./rotate-domain.sh --node 1 --type both --new-domain backup-domain.com

source "$(dirname "$0")/common.sh"
check_required_vars CF_API_TOKEN CF_ZONE_ID CF_DOMAIN CF_TUNNEL_ID_NODE1

# --- Разбор аргументов ---
NODE=""
TYPE=""
NEW_DOMAIN=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --node) NODE="$2"; shift 2 ;;
        --type) TYPE="$2"; shift 2 ;;
        --new-domain) NEW_DOMAIN="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$NODE" ] || [ -z "$TYPE" ]; then
    echo "Использование: $0 --node <1|2> --type <desktop|mobile|both> [--new-domain domain.com]" >&2
    exit 1
fi

# Определить домен (текущий или новый)
DOMAIN="${NEW_DOMAIN:-$CF_DOMAIN}"

# Определить tunnel ID
TUNNEL_VAR="CF_TUNNEL_ID_NODE${NODE}"
TUNNEL_ID="${!TUNNEL_VAR}"
TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"

echo_header "Ротация домена для ноды ${NODE}"
echo "  Тип: ${TYPE}"
echo "  Домен: ${DOMAIN}"
echo ""

# Генерировать случайные субдомены
generate_subdomain() {
    local prefix="$1"
    local random
    random=$(openssl rand -hex 4)
    echo "${prefix}-${random}"
}

NEW_WS_HOST=""
NEW_VLESS_HOST=""

if [ "$TYPE" = "desktop" ] || [ "$TYPE" = "both" ]; then
    NEW_WS_SUB=$(generate_subdomain "v${NODE}")
    NEW_WS_HOST="${NEW_WS_SUB}.${DOMAIN}"
    echo "  Новый десктоп-хост: ${NEW_WS_HOST}"
    upsert_cname "$NEW_WS_SUB" "$TUNNEL_TARGET"
fi

if [ "$TYPE" = "mobile" ] || [ "$TYPE" = "both" ]; then
    NEW_VLESS_SUB=$(generate_subdomain "m${NODE}")
    NEW_VLESS_HOST="${NEW_VLESS_SUB}.${DOMAIN}"
    echo "  Новый мобильный хост: ${NEW_VLESS_HOST}"
    upsert_cname "$NEW_VLESS_SUB" "$TUNNEL_TARGET"
fi

echo ""
echo "--- Обновление ingress на ноде ${NODE} ---"

# Сформировать команды для обновления конфига на exit-ноде
# Используем sed для замены hostname в config.yml
REMOTE_CMDS=""

if [ -n "$NEW_WS_HOST" ]; then
    # Заменить десктоп hostname в ingress
    REMOTE_CMDS+="sudo sed -i 's|hostname: vpn${NODE}[^.]*\\.${CF_DOMAIN}|hostname: ${NEW_WS_HOST}|' /etc/cloudflared/config.yml && "
fi

if [ -n "$NEW_VLESS_HOST" ]; then
    # Заменить мобильный hostname в ingress
    REMOTE_CMDS+="sudo sed -i 's|hostname: vpn${NODE}-m[^.]*\\.${CF_DOMAIN}|hostname: ${NEW_VLESS_HOST}|' /etc/cloudflared/config.yml && "
    # Для нового домена — обновить и общий паттерн
    if [ -n "$NEW_DOMAIN" ]; then
        REMOTE_CMDS+="sudo sed -i 's|hostname: m${NODE}[^.]*\\.${CF_DOMAIN}|hostname: ${NEW_VLESS_HOST}|' /etc/cloudflared/config.yml && "
    fi
fi

REMOTE_CMDS+="sudo systemctl restart cloudflared && echo 'cloudflared перезапущен'"

echo "  Выполняю на ноде ${NODE}..."
ssh_exec "$NODE" bash -c "'${REMOTE_CMDS}'"

# Уведомление в Telegram
NOTIFY_SCRIPT="$PROJECT_ROOT/management/scripts/notify-telegram.sh"
if [ -x "$NOTIFY_SCRIPT" ]; then
    MSG="🔄 Ротация домена (нода ${NODE}, тип: ${TYPE})"
    [ -n "$NEW_WS_HOST" ] && MSG+="\n📱 Десктоп: ${NEW_WS_HOST}"
    [ -n "$NEW_VLESS_HOST" ] && MSG+="\n📱 Мобильный: ${NEW_VLESS_HOST}"
    "$NOTIFY_SCRIPT" --type info --message "$MSG"
fi

echo ""
echo_header "Готово"
echo "Новые хосты:"
[ -n "$NEW_WS_HOST" ] && echo "  Десктоп: wss://${NEW_WS_HOST}"
[ -n "$NEW_VLESS_HOST" ] && echo "  Мобильный: ${NEW_VLESS_HOST}"
echo ""
echo "Обновите клиентские конфиги с новыми хостами!"
