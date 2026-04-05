#!/bin/bash
# Настройка зональных параметров Cloudflare для VPN
#
# Устанавливает:
#   - SSL: Full (Strict)
#   - WebSocket: включено
#   - Minimum TLS: 1.2
#   - Always Use HTTPS: включено
#   - TLS 1.3: включено с 0-RTT
#
# Использование: ./cloudflare-settings.sh

source "$(dirname "$0")/common.sh"
check_required_vars CF_API_TOKEN CF_ZONE_ID

echo_header "Настройка Cloudflare зоны"

patch_setting() {
    local setting="$1"
    local value="$2"
    local display_name="$3"

    echo "  ${display_name}: ${value}"
    cf_api PATCH "/zones/${CF_ZONE_ID}/settings/${setting}" \
        "{\"value\":\"${value}\"}" > /dev/null
}

patch_setting "ssl"              "strict"  "SSL Mode"
patch_setting "websockets"       "on"      "WebSocket"
patch_setting "min_tls_version"  "1.2"     "Minimum TLS"
patch_setting "always_use_https" "on"      "Always HTTPS"
patch_setting "tls_1_3"          "zrt"     "TLS 1.3 + 0-RTT"

echo ""
echo_header "Готово"
echo "Все настройки применены к зоне ${CF_DOMAIN}"
