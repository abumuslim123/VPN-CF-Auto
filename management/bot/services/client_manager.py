"""Управление VPN-клиентами: генерация конфигов AWG и VLESS."""

import logging
import os
import subprocess
import uuid

from bot import database as db
from bot.config import (
    CF_DOMAIN, AWG_JC, AWG_JMIN, AWG_JMAX, AWG_S1, AWG_S2,
    AWG_H1, AWG_H2, AWG_H3, AWG_H4, CLIENTS_DIR,
)
from bot.services import ssh

log = logging.getLogger(__name__)


async def create_client(
    name: str,
    client_type: str,
    server_id: int | None = None,
) -> dict:
    """Создать нового клиента. Возвращает dict с данными и путями к файлам.

    Если server_id=None, выбирается наименее загруженный (round-robin).
    """

    # Выбор сервера
    if server_id is None:
        server = await db.get_least_loaded_server()
        if not server:
            raise RuntimeError("Нет активных серверов")
        server_id = server["id"]
    else:
        server = await db.get_server(server_id)
        if not server:
            raise RuntimeError(f"Сервер {server_id} не найден")
        if server["status"] != "active":
            raise RuntimeError(f"Сервер {server['name']} не активен ({server['status']})")

    # Проверить уникальность имени
    existing = await db.get_client_by_name(name)
    if existing:
        raise RuntimeError(f"Клиент '{name}' уже существует")

    # Каталог клиента
    client_dir = os.path.join(CLIENTS_DIR, name)
    os.makedirs(client_dir, exist_ok=True)

    result = {
        "name": name,
        "type": client_type,
        "server": server,
        "dir": client_dir,
        "files": [],
    }

    # Создать запись в БД
    client_id = await db.add_client(name, client_type, server_id)

    try:
        if client_type in ("desktop", "both"):
            await _create_desktop(client_id, name, server, client_dir, result)

        if client_type in ("mobile", "both"):
            await _create_mobile(client_id, name, server, client_dir, result)

    except Exception:
        # Откат при ошибке
        await db.revoke_client(client_id)
        raise

    return result


async def _create_desktop(
    client_id: int, name: str, server: dict, client_dir: str, result: dict
):
    """Генерация AWG-конфига для десктопа."""

    # Генерация ключей (wireguard-tools доступны в контейнере)
    privkey = subprocess.check_output(["wg", "genkey"]).decode().strip()
    pubkey = subprocess.check_output(
        ["wg", "pubkey"], input=privkey.encode()
    ).decode().strip()
    psk = subprocess.check_output(["wg", "genpsk"]).decode().strip()

    # Выделить IP
    client_ip = await db.allocate_ip(server["id"], client_id)

    # Обновить БД
    db_conn = await db.get_db()
    try:
        await db_conn.execute(
            "UPDATE clients SET awg_ip=?, awg_privkey=?, awg_pubkey=?, awg_psk=? WHERE id=?",
            (client_ip, privkey, pubkey, psk, client_id),
        )
        await db_conn.commit()
    finally:
        await db_conn.close()

    # Добавить пир на exit-ноде
    host = server["hostname_ssh"] or server["host"]
    via_tunnel = bool(server["hostname_ssh"])

    add_peer_cmd = (
        f"sudo awg set awg0 peer {pubkey} preshared-key <(echo '{psk}') allowed-ips {client_ip}/32 && "
        f"echo -e '\\n[Peer]\\n# {name}\\nPublicKey = {pubkey}\\nPresharedKey = {psk}\\n"
        f"AllowedIPs = {client_ip}/32' | sudo tee -a /etc/amnezia/amneziawg/awg0.conf > /dev/null"
    )
    rc, out, err = await ssh.run_ssh(
        host, add_peer_cmd, server["ssh_user"], server.get("ssh_port", 22),
        via_tunnel=via_tunnel,
    )
    if rc != 0:
        raise RuntimeError(f"Не удалось добавить AWG peer: {err}")

    # AWG клиентский конфиг
    ws_host = server["hostname_desktop"]
    awg_conf = (
        f"[Interface]\n"
        f"PrivateKey = {privkey}\n"
        f"Address = {client_ip}/32\n"
        f"DNS = 1.1.1.1, 8.8.8.8\n"
        f"Jc = {AWG_JC}\n"
        f"Jmin = {AWG_JMIN}\n"
        f"Jmax = {AWG_JMAX}\n"
        f"S1 = {AWG_S1}\n"
        f"S2 = {AWG_S2}\n"
        f"H1 = {AWG_H1}\n"
        f"H2 = {AWG_H2}\n"
        f"H3 = {AWG_H3}\n"
        f"H4 = {AWG_H4}\n"
        f"\n"
        f"[Peer]\n"
        f"PublicKey = {server['awg_public_key']}\n"
        f"PresharedKey = {psk}\n"
        f"Endpoint = 127.0.0.1:51820\n"
        f"AllowedIPs = 0.0.0.0/0, ::/0\n"
        f"PersistentKeepalive = 25\n"
    )

    awg_path = os.path.join(client_dir, "awg-client.conf")
    with open(awg_path, "w") as f:
        f.write(awg_conf)
    result["files"].append(awg_path)

    # Connect скрипт
    connect_sh = (
        '#!/bin/bash\n'
        'set -euo pipefail\n'
        f'WS_HOST="{ws_host}"\n'
        'LOCAL_WG_PORT=51820\n'
        'AWG_CONF="$(dirname "$0")/awg-client.conf"\n'
        'WSTUNNEL_PID=""\n'
        'cleanup() {\n'
        '    echo ""; echo "[*] Отключение..."\n'
        '    sudo awg-quick down "$AWG_CONF" 2>/dev/null || true\n'
        '    [ -n "$WSTUNNEL_PID" ] && kill "$WSTUNNEL_PID" 2>/dev/null || true\n'
        '    echo "[*] Отключено."; exit 0\n'
        '}\n'
        'trap cleanup INT TERM EXIT\n'
        'echo "[*] Подключение к ${WS_HOST}..."\n'
        'wstunnel client \\\n'
        '    -L "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0" \\\n'
        '    "wss://${WS_HOST}:443" &\n'
        'WSTUNNEL_PID=$!\n'
        'sleep 2\n'
        'if ! kill -0 "$WSTUNNEL_PID" 2>/dev/null; then\n'
        '    echo "ОШИБКА: wstunnel не запустился" >&2; exit 1\n'
        'fi\n'
        'echo "[*] Запуск Amnezia WireGuard..."\n'
        'sudo awg-quick up "$AWG_CONF"\n'
        'echo "[+] VPN подключён! Ctrl+C для отключения."\n'
        'wait "$WSTUNNEL_PID" 2>/dev/null || true\n'
    )
    connect_path = os.path.join(client_dir, "connect.sh")
    with open(connect_path, "w") as f:
        f.write(connect_sh)
    os.chmod(connect_path, 0o755)
    result["files"].append(connect_path)

    result["awg_ip"] = client_ip
    result["ws_host"] = ws_host


async def _create_mobile(
    client_id: int, name: str, server: dict, client_dir: str, result: dict
):
    """Генерация VLESS-конфига для мобильного."""

    vless_uuid = str(uuid.uuid4())

    # Обновить БД
    db_conn = await db.get_db()
    try:
        await db_conn.execute(
            "UPDATE clients SET vless_uuid=? WHERE id=?",
            (vless_uuid, client_id),
        )
        await db_conn.commit()
    finally:
        await db_conn.close()

    # Добавить клиента в Xray на exit-ноде
    host = server["hostname_ssh"] or server["host"]
    via_tunnel = bool(server["hostname_ssh"])

    add_xray_cmd = (
        f"sudo cp /etc/xray/config.json /etc/xray/config.json.bak && "
        f"sudo jq --arg id '{vless_uuid}' --arg email '{name}@vpn' "
        f"'.inbounds[0].settings.clients += [{{\"id\": $id, \"email\": $email}}]' "
        f"/etc/xray/config.json > /tmp/xray-new.json && "
        f"jq . /tmp/xray-new.json > /dev/null 2>&1 && "
        f"sudo mv /tmp/xray-new.json /etc/xray/config.json && "
        f"sudo chown xray:xray /etc/xray/config.json && "
        f"sudo systemctl restart xray"
    )
    rc, out, err = await ssh.run_ssh(
        host, add_xray_cmd, server["ssh_user"], server.get("ssh_port", 22),
        via_tunnel=via_tunnel,
    )
    if rc != 0:
        raise RuntimeError(f"Не удалось добавить VLESS клиента: {err}")

    # VLESS URI
    vless_host = server["hostname_mobile"]
    ws_path = "%2Fvless-ws"
    vless_uri = (
        f"vless://{vless_uuid}@{vless_host}:443"
        f"?encryption=none&security=tls&type=ws"
        f"&host={vless_host}&path={ws_path}&sni={vless_host}"
        f"&fp=chrome&alpn=h2%2Chttp%2F1.1"
        f"#{server['name']}-{name}"
    )

    # Сохранить URI
    uri_path = os.path.join(client_dir, "vless-uri.txt")
    with open(uri_path, "w") as f:
        f.write(vless_uri)
    result["files"].append(uri_path)

    # QR-код
    qr_path = os.path.join(client_dir, "vless-qr.png")
    try:
        subprocess.run(
            ["qrencode", "-t", "PNG", "-s", "6", "-o", qr_path, vless_uri],
            check=True,
        )
        result["files"].append(qr_path)
    except (subprocess.CalledProcessError, FileNotFoundError):
        log.warning("qrencode не найден, QR не создан")

    result["vless_uuid"] = vless_uuid
    result["vless_uri"] = vless_uri
    result["vless_host"] = vless_host


async def revoke_client_on_server(client_id: int):
    """Удалить клиента с exit-ноды и из БД."""
    client = await db.get_client(client_id)
    if not client:
        return

    server = await db.get_server(client["server_id"])
    if not server:
        await db.revoke_client(client_id)
        return

    host = server["hostname_ssh"] or server["host"]
    via_tunnel = bool(server["hostname_ssh"])

    # Удалить AWG peer
    if client["awg_pubkey"]:
        cmd = f"sudo awg set awg0 peer {client['awg_pubkey']} remove"
        await ssh.run_ssh(host, cmd, server["ssh_user"], server.get("ssh_port", 22),
                         via_tunnel=via_tunnel)

    # Удалить VLESS клиента
    if client["vless_uuid"]:
        cmd = (
            f"sudo jq 'del(.inbounds[0].settings.clients[] | "
            f"select(.id == \"{client['vless_uuid']}\"))' "
            f"/etc/xray/config.json > /tmp/xray-new.json && "
            f"sudo mv /tmp/xray-new.json /etc/xray/config.json && "
            f"sudo systemctl restart xray"
        )
        await ssh.run_ssh(host, cmd, server["ssh_user"], server.get("ssh_port", 22),
                         via_tunnel=via_tunnel)

    await db.revoke_client(client_id)
