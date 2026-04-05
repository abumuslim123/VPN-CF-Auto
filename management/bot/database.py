"""SQLite база данных — серверы, клиенты, IP-пул, healthcheck."""

import aiosqlite
from bot.config import DB_PATH

SCHEMA = """
-- Глобальная конфигурация
CREATE TABLE IF NOT EXISTS config (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Exit-серверы (неограниченное количество)
CREATE TABLE IF NOT EXISTS servers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL UNIQUE,
    host            TEXT NOT NULL,
    ssh_user        TEXT NOT NULL DEFAULT 'root',
    ssh_port        INTEGER NOT NULL DEFAULT 22,
    country         TEXT DEFAULT '',
    cf_tunnel_id    TEXT,
    cf_tunnel_secret TEXT,
    cf_account_tag  TEXT,
    hostname_desktop TEXT,
    hostname_mobile  TEXT,
    hostname_ssh     TEXT,
    awg_private_key TEXT,
    awg_public_key  TEXT,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK(status IN ('pending','deploying','active','disabled','error')),
    max_clients     INTEGER DEFAULT 253,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    deployed_at     TEXT,
    error_msg       TEXT
);

-- VPN-клиенты
CREATE TABLE IF NOT EXISTS clients (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL UNIQUE,
    type        TEXT NOT NULL CHECK(type IN ('desktop','mobile','both')),
    server_id   INTEGER NOT NULL REFERENCES servers(id),
    awg_ip      TEXT,
    awg_privkey TEXT,
    awg_pubkey  TEXT,
    awg_psk     TEXT,
    vless_uuid  TEXT,
    active      INTEGER NOT NULL DEFAULT 1,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    revoked_at  TEXT
);

-- IP-пул привязан к серверу (10.8.0.2 — 10.8.0.254 на каждый)
CREATE TABLE IF NOT EXISTS ip_pool (
    server_id  INTEGER NOT NULL REFERENCES servers(id),
    ip         TEXT NOT NULL,
    client_id  INTEGER REFERENCES clients(id),
    allocated  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (server_id, ip)
);

-- Результаты проверок
CREATE TABLE IF NOT EXISTS health_checks (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    server_id  INTEGER NOT NULL REFERENCES servers(id),
    protocol   TEXT NOT NULL CHECK(protocol IN ('desktop_ws','mobile_vless','ssh')),
    status     TEXT NOT NULL CHECK(status IN ('up','down','degraded')),
    http_code  INTEGER,
    latency_ms INTEGER,
    error      TEXT,
    checked_at TEXT NOT NULL DEFAULT (datetime('now'))
);

CREATE INDEX IF NOT EXISTS idx_health_server_time
    ON health_checks(server_id, checked_at DESC);
"""


async def get_db() -> aiosqlite.Connection:
    """Получить подключение к БД."""
    db = await aiosqlite.connect(DB_PATH)
    db.row_factory = aiosqlite.Row
    await db.execute("PRAGMA journal_mode=WAL")
    await db.execute("PRAGMA foreign_keys=ON")
    return db


async def init_db():
    """Инициализация схемы БД."""
    db = await get_db()
    try:
        await db.executescript(SCHEMA)
        await db.commit()
    finally:
        await db.close()


async def seed_ip_pool(server_id: int):
    """Заполнить пул IP для нового сервера (10.8.0.2 — 10.8.0.254)."""
    db = await get_db()
    try:
        for i in range(2, 255):
            await db.execute(
                "INSERT OR IGNORE INTO ip_pool (server_id, ip, allocated) VALUES (?, ?, 0)",
                (server_id, f"10.8.0.{i}"),
            )
        await db.commit()
    finally:
        await db.close()


# ─── Серверы ─────────────────────────────────────────────

async def add_server(
    name: str, host: str, ssh_user: str = "root", ssh_port: int = 22,
    country: str = "",
) -> int:
    """Добавить сервер, вернуть его ID."""
    db = await get_db()
    try:
        cur = await db.execute(
            "INSERT INTO servers (name, host, ssh_user, ssh_port, country) "
            "VALUES (?, ?, ?, ?, ?)",
            (name, host, ssh_user, ssh_port, country),
        )
        await db.commit()
        server_id = cur.lastrowid
        await seed_ip_pool(server_id)
        return server_id
    finally:
        await db.close()


async def update_server(server_id: int, **kwargs):
    """Обновить поля сервера."""
    db = await get_db()
    try:
        sets = ", ".join(f"{k} = ?" for k in kwargs)
        vals = list(kwargs.values()) + [server_id]
        await db.execute(f"UPDATE servers SET {sets} WHERE id = ?", vals)
        await db.commit()
    finally:
        await db.close()


async def get_server(server_id: int) -> dict | None:
    db = await get_db()
    try:
        cur = await db.execute("SELECT * FROM servers WHERE id = ?", (server_id,))
        row = await cur.fetchone()
        return dict(row) if row else None
    finally:
        await db.close()


async def get_servers(status: str | None = None) -> list[dict]:
    db = await get_db()
    try:
        if status:
            cur = await db.execute(
                "SELECT * FROM servers WHERE status = ? ORDER BY id", (status,)
            )
        else:
            cur = await db.execute("SELECT * FROM servers ORDER BY id")
        return [dict(r) for r in await cur.fetchall()]
    finally:
        await db.close()


async def get_active_servers() -> list[dict]:
    return await get_servers(status="active")


async def delete_server(server_id: int):
    db = await get_db()
    try:
        await db.execute("DELETE FROM ip_pool WHERE server_id = ?", (server_id,))
        await db.execute("DELETE FROM clients WHERE server_id = ?", (server_id,))
        await db.execute("DELETE FROM health_checks WHERE server_id = ?", (server_id,))
        await db.execute("DELETE FROM servers WHERE id = ?", (server_id,))
        await db.commit()
    finally:
        await db.close()


async def count_clients_on_server(server_id: int) -> int:
    db = await get_db()
    try:
        cur = await db.execute(
            "SELECT COUNT(*) FROM clients WHERE server_id = ? AND active = 1",
            (server_id,),
        )
        row = await cur.fetchone()
        return row[0]
    finally:
        await db.close()


async def get_least_loaded_server() -> dict | None:
    """Round-robin: вернуть активный сервер с наименьшим числом клиентов."""
    db = await get_db()
    try:
        cur = await db.execute("""
            SELECT s.*, COUNT(c.id) AS client_count
            FROM servers s
            LEFT JOIN clients c ON c.server_id = s.id AND c.active = 1
            WHERE s.status = 'active'
            GROUP BY s.id
            ORDER BY client_count ASC, s.id ASC
            LIMIT 1
        """)
        row = await cur.fetchone()
        return dict(row) if row else None
    finally:
        await db.close()


# ─── Клиенты ─────────────────────────────────────────────

async def add_client(
    name: str, client_type: str, server_id: int,
    awg_ip: str = None, awg_privkey: str = None, awg_pubkey: str = None,
    awg_psk: str = None, vless_uuid: str = None,
) -> int:
    db = await get_db()
    try:
        cur = await db.execute(
            "INSERT INTO clients (name, type, server_id, awg_ip, awg_privkey, "
            "awg_pubkey, awg_psk, vless_uuid) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            (name, client_type, server_id, awg_ip, awg_privkey, awg_pubkey,
             awg_psk, vless_uuid),
        )
        await db.commit()
        return cur.lastrowid
    finally:
        await db.close()


async def get_client(client_id: int) -> dict | None:
    db = await get_db()
    try:
        cur = await db.execute("SELECT * FROM clients WHERE id = ?", (client_id,))
        row = await cur.fetchone()
        return dict(row) if row else None
    finally:
        await db.close()


async def get_client_by_name(name: str) -> dict | None:
    db = await get_db()
    try:
        cur = await db.execute("SELECT * FROM clients WHERE name = ?", (name,))
        row = await cur.fetchone()
        return dict(row) if row else None
    finally:
        await db.close()


async def get_clients(server_id: int = None, active_only: bool = True) -> list[dict]:
    db = await get_db()
    try:
        q = "SELECT c.*, s.name AS server_name FROM clients c JOIN servers s ON c.server_id = s.id"
        params = []
        conditions = []
        if active_only:
            conditions.append("c.active = 1")
        if server_id:
            conditions.append("c.server_id = ?")
            params.append(server_id)
        if conditions:
            q += " WHERE " + " AND ".join(conditions)
        q += " ORDER BY c.id"
        cur = await db.execute(q, params)
        return [dict(r) for r in await cur.fetchall()]
    finally:
        await db.close()


async def revoke_client(client_id: int):
    db = await get_db()
    try:
        await db.execute(
            "UPDATE clients SET active = 0, revoked_at = datetime('now') WHERE id = ?",
            (client_id,),
        )
        # Освободить IP
        await db.execute(
            "UPDATE ip_pool SET allocated = 0, client_id = NULL WHERE client_id = ?",
            (client_id,),
        )
        await db.commit()
    finally:
        await db.close()


# ─── IP Pool ─────────────────────────────────────────────

async def allocate_ip(server_id: int, client_id: int) -> str:
    db = await get_db()
    try:
        cur = await db.execute(
            "SELECT ip FROM ip_pool WHERE server_id = ? AND allocated = 0 "
            "ORDER BY ip LIMIT 1",
            (server_id,),
        )
        row = await cur.fetchone()
        if not row:
            raise RuntimeError("Нет свободных IP на этом сервере")
        ip = row[0]
        await db.execute(
            "UPDATE ip_pool SET allocated = 1, client_id = ? "
            "WHERE server_id = ? AND ip = ?",
            (client_id, server_id, ip),
        )
        await db.commit()
        return ip
    finally:
        await db.close()


# ─── Health Checks ────────────────────────────────────────

async def record_health(
    server_id: int, protocol: str, status: str,
    http_code: int = 0, latency_ms: int = 0, error: str = "",
):
    db = await get_db()
    try:
        await db.execute(
            "INSERT INTO health_checks (server_id, protocol, status, http_code, "
            "latency_ms, error) VALUES (?, ?, ?, ?, ?, ?)",
            (server_id, protocol, status, http_code, latency_ms, error),
        )
        await db.commit()
    finally:
        await db.close()


async def get_recent_health(server_id: int, limit: int = 10) -> list[dict]:
    db = await get_db()
    try:
        cur = await db.execute(
            "SELECT * FROM health_checks WHERE server_id = ? "
            "ORDER BY checked_at DESC LIMIT ?",
            (server_id, limit),
        )
        return [dict(r) for r in await cur.fetchall()]
    finally:
        await db.close()


async def count_consecutive_failures(server_id: int, protocol: str) -> int:
    db = await get_db()
    try:
        cur = await db.execute(
            "SELECT COUNT(*) FROM health_checks "
            "WHERE server_id = ? AND protocol = ? AND status = 'down' "
            "AND checked_at > datetime('now', '-15 minutes')",
            (server_id, protocol),
        )
        row = await cur.fetchone()
        return row[0]
    finally:
        await db.close()
