#!/bin/bash
# Принудительное отключение VPN
#
# Использование: ./disconnect.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AWG_CONF="${SCRIPT_DIR}/awg-client.conf"

echo "[*] Отключение VPN..."

# Опустить AWG-интерфейс
if command -v awg-quick &>/dev/null; then
    sudo awg-quick down "$AWG_CONF" 2>/dev/null || true
elif command -v wg-quick &>/dev/null; then
    sudo wg-quick down "$AWG_CONF" 2>/dev/null || true
fi

# Убить все процессы wstunnel
pkill -f "wstunnel client" 2>/dev/null || true

echo "[+] VPN отключён."
