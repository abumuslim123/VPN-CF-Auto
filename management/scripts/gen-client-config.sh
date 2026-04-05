#!/bin/bash
# Генератор клиентских конфигов
#
# Создаёт конфигурации для подключения к VPN:
#   --type desktop  → AWG ключи + wstunnel connect.sh
#   --type mobile   → VLESS UUID + vless:// URI + QR-код
#   --type both     → оба варианта
#
# Использование:
#   gen-client-config.sh --name "Иван" --type desktop --node 1
#   gen-client-config.sh --name "Телефон" --type mobile --node 1
#   gen-client-config.sh --name "Всё" --type both --node 1

source "$(dirname "$0")/common.sh"
init_db

# --- Разбор аргументов ---
CLIENT_NAME=""
CLIENT_TYPE=""
NODE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --name)  CLIENT_NAME="$2"; shift 2 ;;
        --type)  CLIENT_TYPE="$2"; shift 2 ;;
        --node)  NODE="$2"; shift 2 ;;
        --help|-h)
            echo "Использование: $0 --name <имя> --type <desktop|mobile|both> --node <1|2>"
            echo ""
            echo "  --name    Имя клиента (латиница, без пробелов)"
            echo "  --type    desktop = AWG+wstunnel, mobile = VLESS, both = оба"
            echo "  --node    Номер exit-ноды (1 или 2)"
            exit 0
            ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

# Валидация
if [ -z "$CLIENT_NAME" ] || [ -z "$CLIENT_TYPE" ] || [ -z "$NODE" ]; then
    echo "ОШИБКА: Укажите --name, --type и --node" >&2
    echo "Справка: $0 --help" >&2
    exit 1
fi

# Проверить имя (только латиница, цифры, дефис, подчёркивание)
if [[ ! "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ОШИБКА: Имя клиента должно содержать только латиницу, цифры, - и _" >&2
    exit 1
fi

# Проверить тип
if [[ ! "$CLIENT_TYPE" =~ ^(desktop|mobile|both)$ ]]; then
    echo "ОШИБКА: Тип должен быть desktop, mobile или both" >&2
    exit 1
fi

# Проверить уникальность имени
existing=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM clients WHERE name = '${CLIENT_NAME}';")
if [ "$existing" -gt 0 ]; then
    echo "ОШИБКА: Клиент '${CLIENT_NAME}' уже существует" >&2
    exit 1
fi

# Создать каталог для клиента
CLIENT_DIR="${DATA_DIR}/clients/${CLIENT_NAME}"
mkdir -p "$CLIENT_DIR"

echo "============================================"
echo "  Генерация конфига: ${CLIENT_NAME}"
echo "  Тип: ${CLIENT_TYPE}, Нода: ${NODE}"
echo "============================================"
echo ""

# --- Вставить клиента в БД ---
sqlite3 "$DB_PATH" "INSERT INTO clients (name, type, node) VALUES ('${CLIENT_NAME}', '${CLIENT_TYPE}', ${NODE});"
CLIENT_ID=$(sqlite3 "$DB_PATH" "SELECT id FROM clients WHERE name = '${CLIENT_NAME}';")

# ============================================================
# DESKTOP (AWG + wstunnel)
# ============================================================
generate_desktop() {
    echo "--- Desktop (AWG + wstunnel) ---"

    # Генерация ключей
    local privkey pubkey psk
    privkey=$(wg genkey)
    pubkey=$(echo "$privkey" | wg pubkey)
    psk=$(wg genpsk)

    # Выделить IP
    local client_ip
    client_ip=$(allocate_ip "$CLIENT_ID")
    echo "  IP: ${client_ip}"

    # Сохранить в БД
    sqlite3 "$DB_PATH" "UPDATE clients SET awg_ip='${client_ip}', awg_privkey='${privkey}', awg_pubkey='${pubkey}', awg_psk='${psk}' WHERE id=${CLIENT_ID};"

    # Добавить пир на exit-ноде
    echo "  Добавляю пир на ноду ${NODE}..."
    ssh_node "$NODE" bash -c "'
        # Добавить пир в live-конфигурацию
        sudo awg set awg0 peer ${pubkey} preshared-key <(echo ${psk}) allowed-ips ${client_ip}/32

        # Добавить в conf-файл для персистентности
        echo \"\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
        echo \"[Peer]\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
        echo \"# ${CLIENT_NAME}\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
        echo \"PublicKey = ${pubkey}\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
        echo \"PresharedKey = ${psk}\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
        echo \"AllowedIPs = ${client_ip}/32\" | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null
    '"

    # Хостнейм десктопного VPN
    local ws_host="vpn${NODE}.${CF_DOMAIN}"

    # Генерация клиентского конфига AWG
    cat > "${CLIENT_DIR}/awg-client.conf" <<EOF
[Interface]
PrivateKey = ${privkey}
Address = ${client_ip}/32
DNS = ${AWG_DNS:-1.1.1.1,8.8.8.8}
Jc = ${AWG_JC:-4}
Jmin = ${AWG_JMIN:-40}
Jmax = ${AWG_JMAX:-70}
S1 = ${AWG_S1:-0}
S2 = ${AWG_S2:-0}
H1 = ${AWG_H1:-1}
H2 = ${AWG_H2:-2}
H3 = ${AWG_H3:-3}
H4 = ${AWG_H4:-4}

[Peer]
PublicKey = ${AWG_SERVER_PUBLIC_KEY}
PresharedKey = ${psk}
Endpoint = 127.0.0.1:${AWG_LISTEN_PORT:-51820}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # Генерация connect.sh
    sed -e "s|{{WS_HOST}}|${ws_host}|g" \
        -e "s|{{LOCAL_WG_PORT}}|${AWG_LISTEN_PORT:-51820}|g" \
        -e "s|{{CLIENT_NAME}}|${CLIENT_NAME}|g" \
        "${TEMPLATES_DIR}/connect.sh.tpl" > "${CLIENT_DIR}/connect.sh"
    chmod +x "${CLIENT_DIR}/connect.sh"

    # Генерация connect.ps1
    sed -e "s|{{WS_HOST}}|${ws_host}|g" \
        -e "s|{{LOCAL_WG_PORT}}|${AWG_LISTEN_PORT:-51820}|g" \
        -e "s|{{CLIENT_NAME}}|${CLIENT_NAME}|g" \
        "${TEMPLATES_DIR}/connect.ps1.tpl" > "${CLIENT_DIR}/connect.ps1"

    echo "  Файлы:"
    echo "    ${CLIENT_DIR}/awg-client.conf"
    echo "    ${CLIENT_DIR}/connect.sh"
    echo "    ${CLIENT_DIR}/connect.ps1"
    echo ""
}

# ============================================================
# MOBILE (VLESS)
# ============================================================
generate_mobile() {
    echo "--- Mobile (VLESS + WebSocket) ---"

    # Генерация UUID
    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || openssl rand -hex 16 | sed 's/\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)/\1-\2-\3-\4-/')

    # Сохранить в БД
    sqlite3 "$DB_PATH" "UPDATE clients SET vless_uuid='${uuid}' WHERE id=${CLIENT_ID};"

    # Добавить клиента в Xray на exit-ноде
    echo "  Добавляю VLESS-клиента на ноду ${NODE}..."
    ssh_node "$NODE" bash -c "'
        # Добавить клиента через jq
        sudo cp /etc/xray/config.json /etc/xray/config.json.bak
        sudo jq --arg id \"${uuid}\" --arg email \"${CLIENT_NAME}@vpn\" \
            \".inbounds[0].settings.clients += [{\\\"id\\\": \\\$id, \\\"email\\\": \\\$email}]\" \
            /etc/xray/config.json > /tmp/xray-config-new.json

        # Валидация JSON
        if jq . /tmp/xray-config-new.json > /dev/null 2>&1; then
            sudo mv /tmp/xray-config-new.json /etc/xray/config.json
            sudo chown xray:xray /etc/xray/config.json
            sudo chmod 600 /etc/xray/config.json
            sudo systemctl restart xray
            echo \"Xray перезапущен\"
        else
            echo \"ОШИБКА: Невалидный JSON, откат\" >&2
            sudo mv /etc/xray/config.json.bak /etc/xray/config.json
            exit 1
        fi
    '"

    # Хостнейм мобильного VPN
    local vless_host="vpn${NODE}-m.${CF_DOMAIN}"
    local ws_path="${XRAY_WS_PATH:-/vless-ws}"
    local encoded_path
    encoded_path=$(echo -n "$ws_path" | jq -sRr @uri)

    # Сформировать VLESS URI
    local vless_uri="vless://${uuid}@${vless_host}:443?encryption=none&security=tls&type=ws&host=${vless_host}&path=${encoded_path}&sni=${vless_host}&fp=chrome&alpn=h2%2Chttp%2F1.1#ExitNode${NODE}-${CLIENT_NAME}"

    # Сохранить URI
    echo "$vless_uri" > "${CLIENT_DIR}/vless-uri.txt"

    # Генерация QR-кода
    qrencode -t PNG -s 6 -o "${CLIENT_DIR}/vless-qr.png" "$vless_uri"
    qrencode -t UTF8 "$vless_uri" > "${CLIENT_DIR}/vless-qr.txt"

    echo "  UUID: ${uuid}"
    echo "  VLESS URI: ${vless_uri}"
    echo ""
    echo "  QR-код (для сканирования):"
    cat "${CLIENT_DIR}/vless-qr.txt"
    echo ""
    echo "  Файлы:"
    echo "    ${CLIENT_DIR}/vless-uri.txt"
    echo "    ${CLIENT_DIR}/vless-qr.png"
    echo ""
}

# --- Генерация ---
case $CLIENT_TYPE in
    desktop) generate_desktop ;;
    mobile)  generate_mobile ;;
    both)    generate_desktop; generate_mobile ;;
esac

echo "============================================"
echo "  Готово! Конфиги в: ${CLIENT_DIR}"
echo "============================================"
