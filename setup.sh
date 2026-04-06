#!/bin/bash
# ============================================================
#  VPN Infrastructure — Интерактивный Setup Wizard
# ============================================================
#
# ИДЕМПОТЕНТНЫЙ — при повторном запуске загружает сохранённый .env
# и пропускает уже выполненные шаги (CF, серверы).
#
# Запуск:
#   bash setup.sh          — полный wizard
#   bash setup.sh --step5  — только деплой (пропустить шаги 1-4)
#
# При ошибке: просто запустите заново. Прогресс сохраняется.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
DEPLOY_SCRIPT="$SCRIPT_DIR/scripts/deploy-exit-node.sh"

# ─── Цвета ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

print_header() {
    echo ""
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo -e "${CYAN}${BOLD}  $1${NC}"
    echo -e "${CYAN}${BOLD}============================================${NC}"
    echo ""
}

print_step() {
    echo -e "${BLUE}[${1}]${NC} ${2}"
}

print_ok() {
    echo -e "  ${GREEN}✓${NC} ${1}"
}

print_err() {
    echo -e "  ${RED}✗${NC} ${1}"
}

print_warn() {
    echo -e "  ${YELLOW}!${NC} ${1}"
}

ask() {
    local prompt="$1"
    local default="${2:-}"
    local var_name="$3"

    if [ -n "$default" ]; then
        echo -ne "  ${prompt} [${default}]: "
    else
        echo -ne "  ${prompt}: "
    fi
    read -r input
    eval "${var_name}='${input:-$default}'"
}

ask_secret() {
    local prompt="$1"
    local var_name="$2"
    echo -ne "  ${prompt}: "
    read -rs input
    echo ""
    eval "${var_name}='${input}'"
}

# ─── Проверка зависимостей ─────────────────────────────────

print_header "VPN Infrastructure — Setup Wizard"

echo "Проверка зависимостей..."
MISSING=()
for cmd in ssh curl jq docker openssl; do
    if command -v "$cmd" &>/dev/null; then
        print_ok "$cmd найден"
    else
        print_err "$cmd НЕ найден"
        MISSING+=("$cmd")
    fi
done

# docker compose (plugin или docker-compose)
if docker compose version &>/dev/null 2>&1; then
    DOCKER_COMPOSE="docker compose"
    print_ok "docker compose найден"
elif command -v docker-compose &>/dev/null; then
    DOCKER_COMPOSE="docker-compose"
    print_ok "docker-compose найден"
else
    print_err "docker compose НЕ найден"
    MISSING+=("docker-compose")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    echo -e "${RED}Установите: ${MISSING[*]}${NC}"
    exit 1
fi

# ─── Загрузить сохранённый прогресс ───────────────────────
SKIP_TO_STEP5=false
if [ "${1:-}" = "--step5" ]; then
    SKIP_TO_STEP5=true
fi

if [ -f "$ENV_FILE" ]; then
    echo ""
    echo -e "${YELLOW}Найден .env от предыдущего запуска.${NC}"
    set -a; source "$ENV_FILE"; set +a

    if [ "$SKIP_TO_STEP5" = true ]; then
        echo -e "${GREEN}Пропускаю шаги 1-4, переходу к деплою...${NC}"
    else
        ask "Использовать сохранённые настройки? (y/n)" "y" USE_SAVED
        if [ "$USE_SAVED" = "y" ] || [ "$USE_SAVED" = "Y" ]; then
            SKIP_TO_STEP5=true
            echo -e "${GREEN}Загружено из .env, переходу к деплою...${NC}"
        fi
    fi
fi

if [ "$SKIP_TO_STEP5" = false ]; then
# ─── Шаг 1: Cloudflare ────────────────────────────────────

print_header "Шаг 1/5: Cloudflare"
echo "  Создайте API Token: Dashboard → Profile → API Tokens"
echo "  Права: Zone:DNS:Edit, Zone:Zone Settings:Edit, Account:Cloudflare Tunnel:Edit"
echo ""

ask "CF API Token" "" CF_API_TOKEN
ask "CF Account ID" "" CF_ACCOUNT_ID
ask "CF Zone ID" "" CF_ZONE_ID
ask "Домен" "" CF_DOMAIN

# Валидация
echo ""
echo "  Проверка Cloudflare API..."
CF_RESP=$(curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
    "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}" 2>/dev/null || echo '{}')
CF_SUCCESS=$(echo "$CF_RESP" | jq -r '.success // false')

if [ "$CF_SUCCESS" = "true" ]; then
    CF_DOMAIN_CHECK=$(echo "$CF_RESP" | jq -r '.result.name')
    print_ok "Cloudflare API работает (домен: ${CF_DOMAIN_CHECK})"
else
    print_err "Cloudflare API недоступен. Проверьте токен и Zone ID."
    exit 1
fi

# ─── Шаг 2: Telegram ──────────────────────────────────────

print_header "Шаг 2/5: Telegram Bot"
echo "  Создайте бота: @BotFather → /newbot"
echo "  Получите Chat ID: отправьте боту сообщение, затем:"
echo "  curl https://api.telegram.org/bot<TOKEN>/getUpdates"
echo ""

ask "Bot Token" "" TG_BOT_TOKEN
ask "Admin Chat ID" "" TG_ADMIN_ID

# Валидация
echo ""
echo "  Проверка бота..."
BOT_RESP=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" 2>/dev/null || echo '{}')
BOT_OK=$(echo "$BOT_RESP" | jq -r '.ok // false')

if [ "$BOT_OK" = "true" ]; then
    BOT_NAME=$(echo "$BOT_RESP" | jq -r '.result.username')
    print_ok "Бот найден: @${BOT_NAME}"
else
    print_err "Бот недоступен. Проверьте токен."
    exit 1
fi

# ─── Шаг 3: AWG параметры обфускации ──────────────────────

print_header "Шаг 3/5: Параметры обфускации AWG"
echo "  Эти параметры ДОЛЖНЫ совпадать на всех серверах и клиентах."
echo "  Рекомендуется сгенерировать случайные (по умолчанию)."
echo ""

ask "Генерировать случайные H1-H4? (y/n)" "y" GEN_RANDOM

if [ "$GEN_RANDOM" = "y" ] || [ "$GEN_RANDOM" = "Y" ]; then
    AWG_H1=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 2147483646) + 1 ))
    AWG_H2=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 2147483646) + 1 ))
    AWG_H3=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 2147483646) + 1 ))
    AWG_H4=$(( ($(od -An -tu4 -N4 /dev/urandom | tr -d ' ') % 2147483646) + 1 ))
    print_ok "H1=${AWG_H1}, H2=${AWG_H2}, H3=${AWG_H3}, H4=${AWG_H4}"
else
    ask "H1" "1" AWG_H1
    ask "H2" "2" AWG_H2
    ask "H3" "3" AWG_H3
    ask "H4" "4" AWG_H4
fi

AWG_JC=4
AWG_JMIN=40
AWG_JMAX=70
AWG_S1=0
AWG_S2=0

echo ""
ask "Jc (junk packets)" "4" AWG_JC
ask "Jmin" "40" AWG_JMIN
ask "Jmax" "70" AWG_JMAX

# ─── Шаг 4: Exit-серверы ──────────────────────────────────

print_header "Шаг 4/5: Зарубежные VPN-серверы (exit-ноды)"
echo "  ⚠️  Эта машина ($(hostname)) станет management-сервером."
echo "     Бот и мониторинг запустятся здесь автоматически."
echo ""
echo "  Сейчас нужно указать ЗАРУБЕЖНЫЕ серверы — через них"
echo "  будет выходить VPN-трафик. Минимум один."
echo "  Для каждого нужен SSH-доступ (root + ключ)."
echo ""

SERVERS=()
SERVER_NUM=0

while true; do
    SERVER_NUM=$((SERVER_NUM + 1))
    echo -e "${BOLD}--- Зарубежный сервер ${SERVER_NUM} ---${NC}"
    ask "  Имя (латиница, напр. europe-1)" "" SRV_NAME
    ask "  IP-адрес сервера за рубежом" "" SRV_HOST
    ask "  SSH пользователь" "root" SRV_USER
    ask "  SSH порт" "22" SRV_PORT
    ask "  Страна (DE/FI/NL/...)" "" SRV_COUNTRY

    # Проверка SSH
    echo ""
    echo "  Проверка SSH-подключения..."
    SSH_RESULT=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$SRV_PORT" "${SRV_USER}@${SRV_HOST}" "echo SSH_OK" 2>&1 || true)

    if echo "$SSH_RESULT" | grep -q "SSH_OK"; then
        print_ok "SSH работает"
    else
        print_err "SSH недоступен! Проверьте IP и учётные данные."
        echo "  Убедитесь, что SSH-ключ добавлен (ssh-copy-id ${SRV_USER}@${SRV_HOST})"
        ask "  Повторить? (y/n)" "y" RETRY
        if [ "$RETRY" = "y" ]; then
            SERVER_NUM=$((SERVER_NUM - 1))
            continue
        fi
    fi

    SERVERS+=("${SRV_NAME}|${SRV_HOST}|${SRV_USER}|${SRV_PORT}|${SRV_COUNTRY}")

    echo ""
    ask "Добавить ещё сервер? (y/n)" "n" ADD_MORE
    if [ "$ADD_MORE" != "y" ] && [ "$ADD_MORE" != "Y" ]; then
        break
    fi
    echo ""
done

fi  # конец if SKIP_TO_STEP5 = false

# ─── Шаг 5: Деплой ────────────────────────────────────────

print_header "Шаг 5/5: Деплой"

# Если пропустили шаги 1-4, загрузить серверы из БД
if [ "$SKIP_TO_STEP5" = true ] && [ ${#SERVERS[@]} -eq 0 ]; then
    DB_FILE="$SCRIPT_DIR/management/data/vpn.db"
    if [ -f "$DB_FILE" ]; then
        echo "  Загружаю серверы из базы данных..."
        while IFS='|' read -r name host user port country; do
            SERVERS+=("${name}|${host}|${user}|${port}|${country}")
        done < <(sqlite3 "$DB_FILE" "SELECT name, host, ssh_user, ssh_port, country FROM servers;" 2>/dev/null | tr '|' '|' || true)
    fi
    if [ ${#SERVERS[@]} -eq 0 ]; then
        echo -e "${RED}Нет серверов для деплоя! Запустите без --step5${NC}"
        exit 1
    fi
fi

echo "  Серверов для деплоя: ${#SERVERS[@]}"
echo ""

# 5.1. Настроить Cloudflare zone
echo "  Настройка Cloudflare зоны..."
for setting in "ssl|strict" "websockets|on" "min_tls_version|1.2" "always_use_https|on" "tls_1_3|zrt"; do
    KEY="${setting%%|*}"
    VAL="${setting##*|}"
    curl -s -X PATCH \
        "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/settings/${KEY}" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"value\":\"${VAL}\"}" > /dev/null 2>&1
done
print_ok "Cloudflare зона настроена"

# 5.2. Деплой каждого сервера
NODE_IDX=0
TUNNEL_IDS=()

for srv_data in "${SERVERS[@]}"; do
    NODE_IDX=$((NODE_IDX + 1))
    IFS='|' read -r SRV_NAME SRV_HOST SRV_USER SRV_PORT SRV_COUNTRY <<< "$srv_data"

    echo ""
    echo -e "${BOLD}--- Деплой: ${SRV_NAME} (${SRV_HOST}) ---${NC}"

    # Создать CF Tunnel (или найти существующий)
    print_step "1/4" "Cloudflare Tunnel..."

    # Проверить, есть ли туннель уже (по имени)
    EXISTING_TUNNEL=$(curl -s \
        "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel?name=vpn-${SRV_NAME}&is_deleted=false" \
        -H "Authorization: Bearer ${CF_API_TOKEN}" 2>/dev/null \
        | jq -r '.result[0].id // empty' 2>/dev/null || true)

    if [ -n "$EXISTING_TUNNEL" ]; then
        TUNNEL_ID="$EXISTING_TUNNEL"
        # Нужен secret для credentials — если туннель уже есть, берём из БД
        DB_FILE="$SCRIPT_DIR/management/data/vpn.db"
        TUNNEL_SECRET=$(sqlite3 "$DB_FILE" "SELECT cf_tunnel_secret FROM servers WHERE name='${SRV_NAME}';" 2>/dev/null || true)
        if [ -z "$TUNNEL_SECRET" ]; then
            TUNNEL_SECRET=$(openssl rand -base64 32)
        fi
        print_ok "Tunnel уже существует: ${TUNNEL_ID}"
    else
        TUNNEL_SECRET=$(openssl rand -base64 32)
        TUNNEL_RESP=$(curl -s -X POST \
            "https://api.cloudflare.com/client/v4/accounts/${CF_ACCOUNT_ID}/cfd_tunnel" \
            -H "Authorization: Bearer ${CF_API_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"name\":\"vpn-${SRV_NAME}\",\"tunnel_secret\":\"${TUNNEL_SECRET}\"}")

        TUNNEL_ID=$(echo "$TUNNEL_RESP" | jq -r '.result.id // empty')
        if [ -z "$TUNNEL_ID" ]; then
            print_err "Не удалось создать туннель"
            echo "$TUNNEL_RESP" | jq '.errors' 2>/dev/null
            continue
        fi
        print_ok "Tunnel создан: ${TUNNEL_ID}"
    fi
    TUNNEL_IDS+=("$TUNNEL_ID")

    CREDENTIALS_JSON="{\"AccountTag\":\"${CF_ACCOUNT_ID}\",\"TunnelSecret\":\"${TUNNEL_SECRET}\",\"TunnelID\":\"${TUNNEL_ID}\"}"
    HOSTNAME_DESKTOP="vpn${NODE_IDX}.${CF_DOMAIN}"
    HOSTNAME_MOBILE="vpn${NODE_IDX}-m.${CF_DOMAIN}"
    HOSTNAME_SSH="ssh${NODE_IDX}.${CF_DOMAIN}"

    # Создать DNS
    print_step "2/4" "Создание DNS-записей..."
    TUNNEL_TARGET="${TUNNEL_ID}.cfargotunnel.com"
    for sub in "vpn${NODE_IDX}" "vpn${NODE_IDX}-m" "ssh${NODE_IDX}"; do
        FQDN="${sub}.${CF_DOMAIN}"
        # Проверить существование
        EXISTING=$(curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
            "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${FQDN}" \
            | jq '.result | length')
        if [ "$EXISTING" -gt 0 ]; then
            REC_ID=$(curl -s -H "Authorization: Bearer ${CF_API_TOKEN}" \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records?type=CNAME&name=${FQDN}" \
                | jq -r '.result[0].id')
            curl -s -X PATCH \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${REC_ID}" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"CNAME\",\"name\":\"${sub}\",\"content\":\"${TUNNEL_TARGET}\",\"proxied\":true,\"ttl\":1}" > /dev/null
        else
            curl -s -X POST \
                "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" \
                -H "Authorization: Bearer ${CF_API_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"type\":\"CNAME\",\"name\":\"${sub}\",\"content\":\"${TUNNEL_TARGET}\",\"proxied\":true,\"ttl\":1}" > /dev/null
        fi
    done
    print_ok "DNS: ${HOSTNAME_DESKTOP}, ${HOSTNAME_MOBILE}, ${HOSTNAME_SSH}"

    # Деплой на серве��
    print_step "3/4" "Деплой VPN-сервисов (это займёт 2-5 минут)..."
    DEPLOY_ENV="
export CF_TUNNEL_ID='${TUNNEL_ID}'
export CF_CREDENTIALS_JSON='${CREDENTIALS_JSON}'
export CF_HOSTNAME_DESKTOP='${HOSTNAME_DESKTOP}'
export CF_HOSTNAME_MOBILE='${HOSTNAME_MOBILE}'
export CF_HOSTNAME_SSH='${HOSTNAME_SSH}'
export AWG_JC='${AWG_JC}'
export AWG_JMIN='${AWG_JMIN}'
export AWG_JMAX='${AWG_JMAX}'
export AWG_S1='${AWG_S1}'
export AWG_S2='${AWG_S2}'
export AWG_H1='${AWG_H1}'
export AWG_H2='${AWG_H2}'
export AWG_H3='${AWG_H3}'
export AWG_H4='${AWG_H4}'
"

    DEPLOY_CONTENT=$(cat "$DEPLOY_SCRIPT")
    FULL_SCRIPT="${DEPLOY_ENV}\n${DEPLOY_CONTENT}"

    # Передать и выполнить скрипт
    ssh -o StrictHostKeyChecking=no -p "$SRV_PORT" "${SRV_USER}@${SRV_HOST}" \
        "cat > /tmp/deploy-vpn.sh && chmod +x /tmp/deploy-vpn.sh && bash /tmp/deploy-vpn.sh" \
        <<< "$(echo -e "$FULL_SCRIPT")" 2>&1 | while IFS= read -r line; do
            echo "    ${line}"
        done

    if [ "${PIPESTATUS[0]}" -eq 0 ]; then
        print_ok "Деплой ${SRV_NAME} завершён"
    else
        print_err "Ошибка деплоя ${SRV_NAME}"
    fi

    # Получить AWG public key
    print_step "4/4" "Получение публичного ключа AWG..."
    AWG_PUB=$(ssh -o StrictHostKeyChecking=no -p "$SRV_PORT" "${SRV_USER}@${SRV_HOST}" \
        "cat /etc/amnezia/amneziawg/server_private.key | awg pubkey 2>/dev/null || cat /etc/amnezia/amneziawg/server_private.key | wg pubkey" 2>/dev/null)
    print_ok "AWG Public Key: ${AWG_PUB}"
done

# 5.3. Сохранить .env
print_header "Сохранение конфигурации"

cat > "$ENV_FILE" <<ENVFILE
# ============================================================
# VPN Infrastructure — Конфигурация
# Сгенерировано setup.sh $(date '+%Y-%m-%d %H:%M')
# ============================================================

# Cloudflare
CF_API_TOKEN=${CF_API_TOKEN}
CF_ACCOUNT_ID=${CF_ACCOUNT_ID}
CF_ZONE_ID=${CF_ZONE_ID}
CF_DOMAIN=${CF_DOMAIN}

# Telegram Bot
TG_BOT_TOKEN=${TG_BOT_TOKEN}
TG_ADMIN_ID=${TG_ADMIN_ID}

# AWG обфускация
AWG_JC=${AWG_JC}
AWG_JMIN=${AWG_JMIN}
AWG_JMAX=${AWG_JMAX}
AWG_S1=${AWG_S1}
AWG_S2=${AWG_S2}
AWG_H1=${AWG_H1}
AWG_H2=${AWG_H2}
AWG_H3=${AWG_H3}
AWG_H4=${AWG_H4}

# Мониторинг
HEALTHCHECK_INTERVAL=300
HEALTHCHECK_TIMEOUT=10

# Данные
DB_PATH=/data/vpn.db
DATA_DIR=/data
ENVFILE

chmod 600 "$ENV_FILE"
print_ok ".env сохранён"

# 5.4. Инициализировать БД с серверами
echo ""
echo "  Инициализация базы данных..."
mkdir -p "$SCRIPT_DIR/management/data"

DB_FILE="$SCRIPT_DIR/management/data/vpn.db"
sqlite3 "$DB_FILE" <<'DBSCHEMA'
CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS servers (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
    host TEXT NOT NULL, ssh_user TEXT NOT NULL DEFAULT 'root',
    ssh_port INTEGER NOT NULL DEFAULT 22, country TEXT DEFAULT '',
    cf_tunnel_id TEXT, cf_tunnel_secret TEXT, cf_account_tag TEXT,
    hostname_desktop TEXT, hostname_mobile TEXT, hostname_ssh TEXT,
    awg_private_key TEXT, awg_public_key TEXT,
    status TEXT NOT NULL DEFAULT 'pending', max_clients INTEGER DEFAULT 253,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    deployed_at TEXT, error_msg TEXT
);
CREATE TABLE IF NOT EXISTS clients (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE,
    type TEXT NOT NULL, server_id INTEGER NOT NULL REFERENCES servers(id),
    awg_ip TEXT, awg_privkey TEXT, awg_pubkey TEXT, awg_psk TEXT,
    vless_uuid TEXT, active INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL DEFAULT (datetime('now')), revoked_at TEXT
);
CREATE TABLE IF NOT EXISTS ip_pool (
    server_id INTEGER NOT NULL, ip TEXT NOT NULL, client_id INTEGER,
    allocated INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (server_id, ip)
);
CREATE TABLE IF NOT EXISTS health_checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT, server_id INTEGER NOT NULL,
    protocol TEXT NOT NULL, status TEXT NOT NULL,
    http_code INTEGER, latency_ms INTEGER, error TEXT,
    checked_at TEXT NOT NULL DEFAULT (datetime('now'))
);
DBSCHEMA

NODE_IDX=0
for srv_data in "${SERVERS[@]}"; do
    NODE_IDX=$((NODE_IDX + 1))
    IFS='|' read -r SRV_NAME SRV_HOST SRV_USER SRV_PORT SRV_COUNTRY <<< "$srv_data"
    TUNNEL_ID="${TUNNEL_IDS[$((NODE_IDX-1))]}"

    HOSTNAME_DESKTOP="vpn${NODE_IDX}.${CF_DOMAIN}"
    HOSTNAME_MOBILE="vpn${NODE_IDX}-m.${CF_DOMAIN}"
    HOSTNAME_SSH="ssh${NODE_IDX}.${CF_DOMAIN}"

    # Получить ключи с сервера
    AWG_PRIV=$(ssh -o StrictHostKeyChecking=no -p "$SRV_PORT" "${SRV_USER}@${SRV_HOST}" \
        "cat /etc/amnezia/amneziawg/server_private.key 2>/dev/null" || echo "")
    AWG_PUB=""
    if [ -n "$AWG_PRIV" ]; then
        AWG_PUB=$(ssh -o StrictHostKeyChecking=no -p "$SRV_PORT" "${SRV_USER}@${SRV_HOST}" \
            "echo '${AWG_PRIV}' | awg pubkey 2>/dev/null || echo '${AWG_PRIV}' | wg pubkey" || echo "")
    fi

    sqlite3 "$DB_FILE" "INSERT OR REPLACE INTO servers (name, host, ssh_user, ssh_port, country, cf_tunnel_id, cf_account_tag, hostname_desktop, hostname_mobile, hostname_ssh, awg_private_key, awg_public_key, status, deployed_at) VALUES ('${SRV_NAME}', '${SRV_HOST}', '${SRV_USER}', ${SRV_PORT}, '${SRV_COUNTRY}', '${TUNNEL_ID}', '${CF_ACCOUNT_ID}', '${HOSTNAME_DESKTOP}', '${HOSTNAME_MOBILE}', '${HOSTNAME_SSH}', '${AWG_PRIV}', '${AWG_PUB}', 'active', datetime('now'));"

    # Заполнить IP-пул
    SRV_ID=$(sqlite3 "$DB_FILE" "SELECT id FROM servers WHERE name='${SRV_NAME}';")
    for i in $(seq 2 254); do
        sqlite3 "$DB_FILE" "INSERT OR IGNORE INTO ip_pool (server_id, ip, allocated) VALUES (${SRV_ID}, '10.8.0.${i}', 0);"
    done
done

print_ok "БД инициализирована (${#SERVERS[@]} серверов)"

# 5.5. Запуск Docker
echo ""
echo "  Запуск management Docker stack..."
cd "$SCRIPT_DIR/management"
$DOCKER_COMPOSE build 2>&1 | tail -3
$DOCKER_COMPOSE up -d 2>&1

print_ok "Docker stack запущен"

# ─── Итого ─────────────────────────────────────────────────

print_header "Готово!"

echo -e "  ${GREEN}✓${NC} Cloudflare настроен (${CF_DOMAIN})"
echo -e "  ${GREEN}✓${NC} ${#SERVERS[@]} exit-сервер(ов) развёрнуто"
echo -e "  ${GREEN}✓${NC} Telegram-бот запущен (@${BOT_NAME})"
echo ""
echo "  Управление через Telegram:"
echo -e "  ${BOLD}Откройте @${BOT_NAME} и отправьте /start${NC}"
echo ""
echo "  Через бота вы можете:"
echo "    • Добавлять/удалять серверы"
echo "    • Создавать клиентские конфиги"
echo "    • Мониторить состояние серверов"
echo "    • Ротировать домены при блокировке"
echo ""
echo "  Файлы:"
echo "    .env          — конфигурация (секреты)"
echo "    management/   — Docker + бот"
echo "    scripts/      — скрипты деплоя"
echo ""
