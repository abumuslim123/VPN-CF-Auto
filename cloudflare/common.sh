#!/bin/bash
# Общие функции для Cloudflare-скриптов
# Подключается через: source "$(dirname "$0")/common.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Загрузить .env
if [ -f "$PROJECT_ROOT/.env" ]; then
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
else
    echo "ОШИБКА: Файл .env не найден в $PROJECT_ROOT" >&2
    echo "Скопируйте .env.example в .env и заполните значения" >&2
    exit 1
fi

# Проверить обязательные переменные
check_required_vars() {
    local missing=()
    for var in "$@"; do
        if [ -z "${!var:-}" ] || [ "${!var}" = "CHANGE_ME" ]; then
            missing+=("$var")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ОШИБКА: Не заданы обязательные переменные:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        exit 1
    fi
}

# Вызов Cloudflare API
# Использование: cf_api GET "/zones" | jq ...
#                cf_api POST "/zones/${CF_ZONE_ID}/dns_records" '{"type":"CNAME",...}'
cf_api() {
    local method="$1"
    local endpoint="$2"
    local data="${3:-}"

    local url="https://api.cloudflare.com/client/v4${endpoint}"
    local args=(
        -s -X "$method"
        -H "Authorization: Bearer ${CF_API_TOKEN}"
        -H "Content-Type: application/json"
    )

    if [ -n "$data" ]; then
        args+=(-d "$data")
    fi

    local response
    response=$(curl "${args[@]}" "$url")

    # Проверить успешность
    local success
    success=$(echo "$response" | jq -r '.success')
    if [ "$success" != "true" ]; then
        echo "ОШИБКА Cloudflare API: $method $endpoint" >&2
        echo "$response" | jq '.errors' >&2
        return 1
    fi

    echo "$response"
}

# Создать или обновить CNAME-запись
# Использование: upsert_cname "vpn1" "tunnel-id.cfargotunnel.com"
upsert_cname() {
    local name="$1"
    local target="$2"
    local fqdn="${name}.${CF_DOMAIN}"

    echo "  DNS: ${fqdn} → ${target}"

    # Проверить существующую запись
    local existing
    existing=$(cf_api GET "/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${fqdn}")
    local count
    count=$(echo "$existing" | jq '.result | length')

    if [ "$count" -gt 0 ]; then
        # Обновить существующую
        local record_id
        record_id=$(echo "$existing" | jq -r '.result[0].id')
        cf_api PATCH "/zones/${CF_ZONE_ID}/dns_records/${record_id}" \
            "{\"type\":\"CNAME\",\"name\":\"${name}\",\"content\":\"${target}\",\"proxied\":true,\"ttl\":1}" \
            > /dev/null
        echo "    Обновлено (запись уже существовала)"
    else
        # Создать новую
        cf_api POST "/zones/${CF_ZONE_ID}/dns_records" \
            "{\"type\":\"CNAME\",\"name\":\"${name}\",\"content\":\"${target}\",\"proxied\":true,\"ttl\":1}" \
            > /dev/null
        echo "    Создано"
    fi
}

# SSH на exit-ноду через CF Tunnel
# Использование: ssh_exec 1 "sudo awg show"
ssh_exec() {
    local node="$1"; shift
    local hostname_var="NODE${node}_SSH_HOST"
    local hostname="${!hostname_var:-ssh${node}.${CF_DOMAIN}}"

    cloudflared access ssh --hostname "${hostname}" -- "$@"
}

echo_header() {
    echo ""
    echo "============================================"
    echo "  $1"
    echo "============================================"
    echo ""
}
