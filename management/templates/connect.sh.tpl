#!/bin/bash
# Скрипт подключения к VPN: wstunnel + Amnezia WireGuard
# Клиент: {{CLIENT_NAME}}
#
# Зависимости:
#   - wstunnel v10+ (https://github.com/erebe/wstunnel/releases)
#   - awg-quick (amneziawg-tools)
#
# Использование: ./connect.sh

set -euo pipefail

# --- Конфигурация ---
WS_HOST="{{WS_HOST}}"
LOCAL_WG_PORT={{LOCAL_WG_PORT}}
AWG_CONF="$(dirname "$0")/awg-client.conf"
AWG_IFACE="awg-client"

# Резервная нода (failover)
WS_HOST_BACKUP=""  # Заполнить при наличии второй ноды

# --- Очистка при выходе ---
WSTUNNEL_PID=""
cleanup() {
    echo ""
    echo "[*] Отключение..."
    sudo awg-quick down "$AWG_CONF" 2>/dev/null || true
    [ -n "$WSTUNNEL_PID" ] && kill "$WSTUNNEL_PID" 2>/dev/null || true
    echo "[*] Отключено."
    exit 0
}
trap cleanup INT TERM EXIT

# --- Проверка зависимостей ---
for cmd in wstunnel awg-quick; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ОШИБКА: ${cmd} не найден. Установите перед запуском." >&2
        exit 1
    fi
done

if [ ! -f "$AWG_CONF" ]; then
    echo "ОШИБКА: Конфиг AWG не найден: ${AWG_CONF}" >&2
    exit 1
fi

# --- Выбор хоста (failover) ---
try_connect() {
    local host="$1"
    echo "[*] Подключение к ${host}..."

    # Запуск wstunnel
    wstunnel client \
        -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \
        "wss://${host}:443" &
    WSTUNNEL_PID=$!

    sleep 2

    # Проверка запуска
    if ! kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
        echo "[!] wstunnel не запустился для ${host}" >&2
        return 1
    fi

    echo "[+] WebSocket-туннель установлен"
    return 0
}

# Попробовать основной хост
if ! try_connect "$WS_HOST"; then
    if [ -n "$WS_HOST_BACKUP" ]; then
        echo "[*] Пробую резервную ноду..."
        if ! try_connect "$WS_HOST_BACKUP"; then
            echo "ОШИБКА: Не удалось подключиться ни к одной ноде" >&2
            exit 1
        fi
    else
        echo "ОШИБКА: Не удалось подключиться" >&2
        exit 1
    fi
fi

# --- Запуск AWG ---
echo "[*] Запуск Amnezia WireGuard..."
sudo awg-quick up "$AWG_CONF"

echo ""
echo "[+] VPN подключён! Нажмите Ctrl+C для отключения."
echo ""

# Ожидание сигнала
wait "$WSTUNNEL_PID" 2>/dev/null || true
