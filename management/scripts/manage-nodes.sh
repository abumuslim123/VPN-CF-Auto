#!/bin/bash
# Управление exit-нодами через CF Tunnel SSH
#
# Использование:
#   manage-nodes.sh 1                    # Интерактивный SSH на ноду 1
#   manage-nodes.sh 1 uptime             # Выполнить команду на ноде 1
#   manage-nodes.sh 1 sudo awg show      # Показать AWG-пиры
#   manage-nodes.sh 2 sudo systemctl status xray

source "$(dirname "$0")/common.sh"

if [ $# -lt 1 ]; then
    echo "Использование: $0 <номер_ноды> [команда...]"
    echo ""
    echo "Примеры:"
    echo "  $0 1                          # Интерактивный SSH"
    echo "  $0 1 uptime                   # Выполнить команду"
    echo "  $0 1 sudo awg show            # Показать AWG"
    echo "  $0 1 sudo journalctl -u xray -n 50  # Логи Xray"
    exit 1
fi

NODE="$1"; shift

if [ $# -eq 0 ]; then
    exec ssh_node "$NODE"
else
    exec ssh_node "$NODE" "$@"
fi
