#!/bin/bash
# Проверка доступности exit-нод
#
# Проверяет три протокола на каждой ноде:
#   desktop_ws    — WebSocket handshake на vpn*.example.com
#   mobile_vless  — WebSocket upgrade на vpn*-m.example.com
#   ssh           — SSH через CF Tunnel
#
# При трёх подряд failure — уведомление в Telegram.
#
# Использование:
#   healthcheck.sh          # Проверить все ноды
#   healthcheck.sh --node 1 # Проверить только ноду 1

source "$(dirname "$0")/common.sh"
init_db

TIMEOUT="${HEALTHCHECK_TIMEOUT:-10}"
TARGET_NODE="${1:-}"

# Проверка WebSocket handshake
check_ws() {
    local host="$1"
    local start_ms end_ms latency http_code

    start_ms=$(date +%s%3N)
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$TIMEOUT" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
        -H "Sec-WebSocket-Version: 13" \
        "https://${host}" 2>/dev/null || echo "000")
    end_ms=$(date +%s%3N)
    latency=$((end_ms - start_ms))

    # 101 = upgrade OK, 200/400 = сервер отвечает (считаем degraded)
    if [ "$http_code" = "101" ]; then
        echo "up|${http_code}|${latency}"
    elif [ "$http_code" = "000" ]; then
        echo "down|${http_code}|${latency}"
    else
        echo "degraded|${http_code}|${latency}"
    fi
}

# Записать результат в БД
record_check() {
    local node="$1" protocol="$2" status="$3" http_code="$4" latency="$5" error="${6:-}"
    sqlite3 "$DB_PATH" "INSERT INTO health_checks (node, protocol, status, http_code, latency_ms, error) \
        VALUES (${node}, '${protocol}', '${status}', ${http_code}, ${latency}, '${error}');"
}

# Проверить, нужно ли алертить (3+ failure за 15 минут)
check_alert_needed() {
    local node="$1" protocol="$2"
    local count
    count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM health_checks \
        WHERE node = ${node} AND protocol = '${protocol}' AND status = 'down' \
        AND checked_at > datetime('now', '-15 minutes');")
    if [ "$count" -ge 3 ]; then
        return 0  # Нужен алерт
    fi
    return 1
}

# Проверить одну ноду
check_node() {
    local node="$1"
    local ws_host="vpn${node}.${CF_DOMAIN}"
    local vless_host="vpn${node}-m.${CF_DOMAIN}"

    echo "--- Нода ${node} ---"

    # Desktop WebSocket
    local result status http_code latency
    result=$(check_ws "$ws_host")
    IFS='|' read -r status http_code latency <<< "$result"
    echo "  Desktop (${ws_host}): ${status} [HTTP ${http_code}, ${latency}ms]"
    record_check "$node" "desktop_ws" "$status" "$http_code" "$latency"
    if [ "$status" = "down" ] && check_alert_needed "$node" "desktop_ws"; then
        tg_notify "⚠️ *Нода ${node} Desktop DOWN*\nХост: ${ws_host}\nHTTP: ${http_code}"
    fi

    # Mobile VLESS WebSocket
    result=$(check_ws "$vless_host")
    IFS='|' read -r status http_code latency <<< "$result"
    echo "  Mobile  (${vless_host}): ${status} [HTTP ${http_code}, ${latency}ms]"
    record_check "$node" "mobile_vless" "$status" "$http_code" "$latency"
    if [ "$status" = "down" ] && check_alert_needed "$node" "mobile_vless"; then
        tg_notify "⚠️ *Нода ${node} Mobile DOWN*\nХост: ${vless_host}\nHTTP: ${http_code}"
    fi

    echo ""
}

# --- Основной цикл ---
echo "=== Healthcheck $(date '+%Y-%m-%d %H:%M:%S') ==="
echo ""

if [ "$TARGET_NODE" = "--node" ] && [ -n "${2:-}" ]; then
    check_node "$2"
else
    check_node 1
    # Нода 2 — если настроена
    if [ -n "${CF_TUNNEL_ID_NODE2:-}" ] && [ "${CF_TUNNEL_ID_NODE2}" != "CHANGE_ME" ]; then
        check_node 2
    fi
fi

echo "=== Готово ==="
