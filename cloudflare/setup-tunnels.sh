#!/bin/bash
# Создание Cloudflare Tunnels для exit-нод
#
# Создаёт два туннеля (vpn-node1, vpn-node2),
# сохраняет credentials.json для каждого.
#
# Требования:
#   - cloudflared установлен и авторизован (cloudflared login)
#   - .env заполнен (CF_API_TOKEN, CF_ACCOUNT_ID)
#
# Использование: ./setup-tunnels.sh

source "$(dirname "$0")/common.sh"
check_required_vars CF_API_TOKEN CF_ACCOUNT_ID

DATA_DIR="$PROJECT_ROOT/management/data/tunnels"
mkdir -p "$DATA_DIR"

echo_header "Создание Cloudflare Tunnels"

# Создать туннель для ноды
create_tunnel() {
    local node_num="$1"
    local tunnel_name="vpn-node${node_num}"

    echo "--- Нода ${node_num}: ${tunnel_name} ---"

    # Проверить, существует ли туннель
    local existing
    existing=$(cloudflared tunnel list --name "${tunnel_name}" -o json 2>/dev/null || echo "[]")
    local count
    count=$(echo "$existing" | jq 'length')

    if [ "$count" -gt 0 ]; then
        local tunnel_id
        tunnel_id=$(echo "$existing" | jq -r '.[0].id')
        echo "  Туннель уже существует: ${tunnel_id}"
    else
        echo "  Создаю туннель..."
        cloudflared tunnel create "${tunnel_name}"

        # Получить ID созданного туннеля
        existing=$(cloudflared tunnel list --name "${tunnel_name}" -o json)
        tunnel_id=$(echo "$existing" | jq -r '.[0].id')
        echo "  Создан: ${tunnel_id}"
    fi

    # Скопировать credentials
    local creds_src="$HOME/.cloudflared/${tunnel_id}.json"
    local creds_dst="$DATA_DIR/node${node_num}.json"

    if [ -f "$creds_src" ]; then
        cp "$creds_src" "$creds_dst"
        chmod 600 "$creds_dst"
        echo "  Credentials сохранены: ${creds_dst}"
    else
        echo "  ВНИМАНИЕ: Credentials не найдены в ${creds_src}" >&2
        echo "  Убедитесь, что cloudflared login был выполнен" >&2
    fi

    # Вывести переменные для .env
    echo ""
    echo "  Добавьте в .env:"
    echo "    CF_TUNNEL_ID_NODE${node_num}=${tunnel_id}"

    # Вернуть ID
    eval "TUNNEL_ID_NODE${node_num}=${tunnel_id}"
}

create_tunnel 1
echo ""
create_tunnel 2

echo ""
echo_header "Готово"
echo "Следующий шаг: ./setup-dns.sh"
