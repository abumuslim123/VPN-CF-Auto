#!/bin/bash
# Универсальный скрипт подключения к VPN (Linux/macOS)
# wstunnel + Amnezia WireGuard
#
# Перед использованием:
#   1. Установите wstunnel v10+: https://github.com/erebe/wstunnel/releases
#   2. Установите amneziawg-tools (Linux) или AmneziaWG (macOS)
#   3. Положите awg-client.conf рядом с этим скриптом
#
# Использование: ./connect.sh [--config путь/к/awg-client.conf]

set -euo pipefail

# --- Конфигурация (заменяется gen-client-config.sh) ---
WS_HOST="${VPN_WS_HOST:-vpn1.example.com}"
WS_HOST_BACKUP="${VPN_WS_HOST_BACKUP:-}"
LOCAL_WG_PORT="${VPN_LOCAL_PORT:-51820}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWG_CONF="${SCRIPT_DIR}/awg-client.conf"

# Разбор аргументов
while [[ $# -gt 0 ]]; do
    case $1 in
        --config) AWG_CONF="$2"; shift 2 ;;
        --host)   WS_HOST="$2"; shift 2 ;;
        --help|-h)
            echo "Использование: $0 [--config путь/к/awg.conf] [--host хост]"
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

# --- Переменные состояния ---
WSTUNNEL_PID=""

# --- Очистка ---
cleanup() {
    echo ""
    echo "[*] Отключение..."
    # Сначала опускаем WG (чтобы маршруты не зависли)
    sudo awg-quick down "$AWG_CONF" 2>/dev/null || true
    # Затем убиваем wstunnel
    if [ -n "$WSTUNNEL_PID" ]; then
        kill "$WSTUNNEL_PID" 2>/dev/null || true
        wait "$WSTUNNEL_PID" 2>/dev/null || true
    fi
    echo "[*] Отключено."
    exit 0
}
trap cleanup INT TERM EXIT

# --- Проверка зависимостей ---
check_deps() {
    local missing=()
    for cmd in wstunnel; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    # awg-quick или wg-quick
    if command -v awg-quick &>/dev/null; then
        WG_QUICK="awg-quick"
    elif command -v wg-quick &>/dev/null; then
        WG_QUICK="wg-quick"
    else
        missing+=("awg-quick")
    fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ОШИБКА: Не найдены: ${missing[*]}" >&2
        echo "Установите зависимости перед запуском." >&2
        exit 1
    fi
}
check_deps

if [ ! -f "$AWG_CONF" ]; then
    echo "ОШИБКА: Конфиг не найден: ${AWG_CONF}" >&2
    echo "Запустите gen-client-config.sh или укажите --config" >&2
    exit 1
fi

# --- Подключение ---
try_connect() {
    local host="$1"
    echo "[*] Подключение к ${host}..."

    wstunnel client \
        -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \
        "wss://${host}:443" &
    WSTUNNEL_PID=$!

    sleep 2

    if ! kill -0 "$WSTUNNEL_PID" 2>/dev/null; then
        WSTUNNEL_PID=""
        echo "[!] Не удалось подключиться к ${host}" >&2
        return 1
    fi

    echo "[+] WebSocket-туннель установлен через ${host}"
    return 0
}

# Попробовать основной хост
if ! try_connect "$WS_HOST"; then
    if [ -n "$WS_HOST_BACKUP" ]; then
        echo "[*] Пробую резервную ноду: ${WS_HOST_BACKUP}..."
        if ! try_connect "$WS_HOST_BACKUP"; then
            echo "ОШИБКА: Не удалось подключиться ни к одной ноде." >&2
            echo "Проверьте интернет-соединение и доступность хостов." >&2
            exit 1
        fi
    else
        echo "ОШИБКА: Не удалось подключиться." >&2
        exit 1
    fi
fi

# Запуск AWG
echo "[*] Запуск Amnezia WireGuard..."
sudo "$WG_QUICK" up "$AWG_CONF"

echo ""
echo "[+] VPN подключён!"
echo "    Нажмите Ctrl+C для отключения."
echo ""

# Ожидание
wait "$WSTUNNEL_PID" 2>/dev/null || true
