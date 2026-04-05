#!/bin/bash
# Общие функции для management-скриптов

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="${SCRIPT_DIR}/../templates"
DATA_DIR="${DATA_DIR:-/data}"
DB_PATH="${DB_PATH:-${DATA_DIR}/vpn.db}"

# Загрузить .env если есть (в Docker передаётся через env_file)
if [ -f "/app/.env" ]; then
    set -a; source "/app/.env"; set +a
fi

# Инициализировать SQLite БД
init_db() {
    if [ -f "$DB_PATH" ]; then
        return 0
    fi

    echo "Инициализация базы данных: ${DB_PATH}"
    mkdir -p "$(dirname "$DB_PATH")"

    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS clients (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    type        TEXT NOT NULL CHECK(type IN ('desktop','mobile','both')),
    node        INTEGER NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    awg_ip      TEXT,
    awg_privkey TEXT,
    awg_pubkey  TEXT,
    awg_psk     TEXT,
    vless_uuid  TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    revoked_at  TEXT
);

CREATE TABLE IF NOT EXISTS ip_pool (
    ip          TEXT PRIMARY KEY,
    client_id   INTEGER REFERENCES clients(id),
    allocated   INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS health_checks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    node        INTEGER NOT NULL,
    protocol    TEXT NOT NULL CHECK(protocol IN ('desktop_ws','mobile_vless','ssh')),
    status      TEXT NOT NULL CHECK(status IN ('up','down','degraded')),
    http_code   INTEGER,
    latency_ms  INTEGER,
    error       TEXT,
    checked_at  TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_health_node_time ON health_checks(node, checked_at DESC);
SQL

    # Заполнить пул IP-адресов (10.8.0.2 — 10.8.0.254)
    for i in $(seq 2 254); do
        sqlite3 "$DB_PATH" "INSERT OR IGNORE INTO ip_pool (ip, allocated) VALUES ('10.8.0.${i}', 0);"
    done

    echo "БД инициализирована, IP-пул заполнен (253 адреса)"
}

# Выделить IP из пула
allocate_ip() {
    local client_id="$1"
    local ip
    ip=$(sqlite3 "$DB_PATH" "SELECT ip FROM ip_pool WHERE allocated = 0 ORDER BY ip LIMIT 1;")
    if [ -z "$ip" ]; then
        echo "ОШИБКА: Нет свободных IP-адресов в пуле" >&2
        return 1
    fi
    sqlite3 "$DB_PATH" "UPDATE ip_pool SET allocated = 1, client_id = ${client_id} WHERE ip = '${ip}';"
    echo "$ip"
}

# SSH на exit-ноду через CF Tunnel
ssh_node() {
    local node="$1"; shift
    local hostname="ssh${node}.${CF_DOMAIN}"
    cloudflared access ssh --hostname "${hostname}" -- "$@"
}

# Отправить уведомление в Telegram
tg_notify() {
    local message="$1"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TG_CHAT_ID}" \
            -d "parse_mode=Markdown" \
            -d "text=${message}" > /dev/null 2>&1 || true
    fi
}

# Отправить файл в Telegram
tg_send_file() {
    local file="$1"
    local caption="${2:-}"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendDocument" \
            -F "chat_id=${TG_CHAT_ID}" \
            -F "document=@${file}" \
            -F "caption=${caption}" > /dev/null 2>&1 || true
    fi
}

# Отправить фото в Telegram
tg_send_photo() {
    local file="$1"
    local caption="${2:-}"
    if [ -n "${TG_BOT_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendPhoto" \
            -F "chat_id=${TG_CHAT_ID}" \
            -F "photo=@${file}" \
            -F "caption=${caption}" > /dev/null 2>&1 || true
    fi
}
