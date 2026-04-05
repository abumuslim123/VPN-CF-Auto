"""Управление exit-серверами: деплой, конфигурация, перезапуск."""

import logging
import os
import tempfile

from bot import database as db
from bot.config import (
    CF_DOMAIN, CF_ACCOUNT_ID, AWG_JC, AWG_JMIN, AWG_JMAX,
    AWG_S1, AWG_S2, AWG_H1, AWG_H2, AWG_H3, AWG_H4,
)
from bot.services import ssh, cloudflare

log = logging.getLogger(__name__)

# Путь к скрипту деплоя (монтируется в контейнер)
DEPLOY_SCRIPT = "/app/scripts/deploy-exit-node.sh"


async def deploy_server(server_id: int, progress_cb=None) -> bool:
    """Полный деплой exit-ноды. progress_cb(text) для обновления статуса."""

    server = await db.get_server(server_id)
    if not server:
        raise ValueError(f"Сервер {server_id} не найден")

    async def status(msg: str):
        log.info("[%s] %s", server["name"], msg)
        if progress_cb:
            await progress_cb(msg)

    try:
        await db.update_server(server_id, status="deploying")

        # 1. Проверить SSH
        await status("🔌 Проверка SSH-подключения...")
        ok, info = await ssh.test_ssh(server["host"], server["ssh_user"], server["ssh_port"])
        if not ok:
            raise RuntimeError(f"SSH недоступен: {info}")
        await status(f"✅ SSH OK: {info}")

        # 2. Создать CF Tunnel
        await status("☁️ Создание Cloudflare Tunnel...")
        tunnel_name = f"vpn-{server['name']}"
        tunnel_id, tunnel_secret, credentials_json = await cloudflare.create_tunnel(tunnel_name)

        # Сгенерировать хостнеймы
        node_idx = server["id"]
        hostname_desktop = f"vpn{node_idx}.{CF_DOMAIN}"
        hostname_mobile = f"vpn{node_idx}-m.{CF_DOMAIN}"
        hostname_ssh = f"ssh{node_idx}.{CF_DOMAIN}"

        await db.update_server(server_id,
            cf_tunnel_id=tunnel_id,
            cf_tunnel_secret=tunnel_secret,
            cf_account_tag=CF_ACCOUNT_ID,
            hostname_desktop=hostname_desktop,
            hostname_mobile=hostname_mobile,
            hostname_ssh=hostname_ssh,
        )

        # 3. Создать DNS
        await status("🌐 Создание DNS-записей...")
        tunnel_target = f"{tunnel_id}.cfargotunnel.com"
        await cloudflare.upsert_cname(f"vpn{node_idx}", tunnel_target)
        await cloudflare.upsert_cname(f"vpn{node_idx}-m", tunnel_target)
        await cloudflare.upsert_cname(f"ssh{node_idx}", tunnel_target)

        # 4. Генерация AWG-ключей
        await status("🔑 Генерация ключей AWG...")
        rc, privkey, err = await ssh.run_ssh(
            server["host"], "awg genkey 2>/dev/null || wg genkey",
            server["ssh_user"], server["ssh_port"],
        )
        if rc != 0:
            # AWG ещё не установлен — сгенерируем после деплоя
            privkey = ""

        if privkey:
            rc2, pubkey, _ = await ssh.run_ssh(
                server["host"], f"echo '{privkey}' | awg pubkey 2>/dev/null || echo '{privkey}' | wg pubkey",
                server["ssh_user"], server["ssh_port"],
            )
            await db.update_server(server_id, awg_private_key=privkey, awg_public_key=pubkey)

        # 5. Скопировать и запустить скрипт деплоя
        await status("🚀 Деплой сервисов на сервер...")

        # Сформировать переменные окружения для скрипта
        env_vars = (
            f"export CF_TUNNEL_ID='{tunnel_id}'\n"
            f"export CF_CREDENTIALS_JSON='{credentials_json}'\n"
            f"export CF_HOSTNAME_DESKTOP='{hostname_desktop}'\n"
            f"export CF_HOSTNAME_MOBILE='{hostname_mobile}'\n"
            f"export CF_HOSTNAME_SSH='{hostname_ssh}'\n"
            f"export AWG_PRIVATE_KEY='{privkey}'\n"
            f"export AWG_JC='{AWG_JC}'\n"
            f"export AWG_JMIN='{AWG_JMIN}'\n"
            f"export AWG_JMAX='{AWG_JMAX}'\n"
            f"export AWG_S1='{AWG_S1}'\n"
            f"export AWG_S2='{AWG_S2}'\n"
            f"export AWG_H1='{AWG_H1}'\n"
            f"export AWG_H2='{AWG_H2}'\n"
            f"export AWG_H3='{AWG_H3}'\n"
            f"export AWG_H4='{AWG_H4}'\n"
        )

        # Прочитать скрипт деплоя
        if os.path.exists(DEPLOY_SCRIPT):
            with open(DEPLOY_SCRIPT) as f:
                deploy_content = f.read()
        else:
            raise RuntimeError(f"Скрипт деплоя не найден: {DEPLOY_SCRIPT}")

        # Объединить env + скрипт и выполнить удалённо
        full_script = env_vars + "\n" + deploy_content
        # Экранируем для передачи через SSH
        rc, out, err = await ssh.run_ssh(
            server["host"],
            f"bash -c 'cat > /tmp/deploy-vpn.sh << '\"'\"'DEPLOY_EOF'\"'\"'\n{full_script}\nDEPLOY_EOF\nchmod +x /tmp/deploy-vpn.sh && bash /tmp/deploy-vpn.sh'",
            server["ssh_user"], server["ssh_port"],
            timeout=300,
        )

        if rc != 0:
            raise RuntimeError(f"Деплой завершился с ошибкой:\n{err}\n{out}")

        # 6. Если ключи не были сгенерированы до деплоя — получить сейчас
        if not privkey:
            await status("🔑 Получение сгенерированных ключей...")
            rc, privkey, _ = await ssh.run_ssh(
                server["host"],
                "cat /etc/amnezia/amneziawg/server_private.key 2>/dev/null || awg genkey",
                server["ssh_user"], server["ssh_port"],
            )
            if rc == 0 and privkey:
                rc2, pubkey, _ = await ssh.run_ssh(
                    server["host"],
                    f"echo '{privkey}' | awg pubkey",
                    server["ssh_user"], server["ssh_port"],
                )
                await db.update_server(server_id, awg_private_key=privkey, awg_public_key=pubkey)

        await db.update_server(server_id, status="active", deployed_at="datetime('now')")
        await status("✅ Деплой завершён!")
        return True

    except Exception as e:
        log.exception("Ошибка деплоя сервера %s", server["name"])
        await db.update_server(server_id, status="error", error_msg=str(e))
        if progress_cb:
            await progress_cb(f"❌ Ошибка: {e}")
        return False


async def restart_services(server_id: int, service: str = "all") -> tuple[bool, str]:
    """Перезапустить сервисы на exit-ноде."""
    server = await db.get_server(server_id)
    if not server:
        return False, "Сервер не найден"

    # Используем SSH через CF Tunnel если есть hostname, иначе напрямую
    host = server["hostname_ssh"] or server["host"]
    via_tunnel = bool(server["hostname_ssh"])

    if service == "all":
        cmd = "sudo systemctl restart cloudflared wstunnel xray awg-quick@awg0"
    else:
        cmd = f"sudo systemctl restart {service}"

    rc, out, err = await ssh.run_ssh(host, cmd, server["ssh_user"], server["ssh_port"],
                                     via_tunnel=via_tunnel, timeout=30)
    if rc == 0:
        return True, "Сервисы перезапущены"
    return False, err or out


async def rotate_domain(server_id: int, rotate_type: str) -> dict:
    """Ротация домена для сервера. Возвращает новые хостнеймы."""
    server = await db.get_server(server_id)
    if not server:
        raise ValueError("Сервер не найден")

    tunnel_target = f"{server['cf_tunnel_id']}.cfargotunnel.com"
    result = {}

    if rotate_type in ("desktop", "both"):
        new_sub = cloudflare.generate_random_subdomain(f"v{server['id']}")
        new_host = f"{new_sub}.{CF_DOMAIN}"
        await cloudflare.upsert_cname(new_sub, tunnel_target)
        result["desktop"] = new_host
        await db.update_server(server_id, hostname_desktop=new_host)

    if rotate_type in ("mobile", "both"):
        new_sub = cloudflare.generate_random_subdomain(f"m{server['id']}")
        new_host = f"{new_sub}.{CF_DOMAIN}"
        await cloudflare.upsert_cname(new_sub, tunnel_target)
        result["mobile"] = new_host
        await db.update_server(server_id, hostname_mobile=new_host)

    # Обновить cloudflared ingress на сервере
    host = server["hostname_ssh"] or server["host"]
    via_tunnel = bool(server["hostname_ssh"])

    # Собрать новый ingress
    srv = await db.get_server(server_id)  # перечитать с обновлёнными хостами
    ingress_cmd = _build_cloudflared_update_cmd(srv)
    await ssh.run_ssh(host, ingress_cmd, server["ssh_user"], server["ssh_port"],
                      via_tunnel=via_tunnel, timeout=30)

    return result


def _build_cloudflared_update_cmd(server: dict) -> str:
    """Сгенерировать команду обновления cloudflared config на сервере."""
    config = (
        f"tunnel: {server['cf_tunnel_id']}\n"
        f"credentials-file: /etc/cloudflared/{server['cf_tunnel_id']}.json\n"
        f"ingress:\n"
        f"  - hostname: {server['hostname_desktop']}\n"
        f"    service: http://127.0.0.1:8080\n"
        f"  - hostname: {server['hostname_mobile']}\n"
        f"    service: http://127.0.0.1:8443\n"
        f"  - hostname: {server['hostname_ssh']}\n"
        f"    service: ssh://127.0.0.1:22\n"
        f"  - service: http_status:404\n"
    )
    # Записать через heredoc и перезапустить cloudflared
    escaped = config.replace("'", "'\\''")
    return f"echo '{escaped}' | sudo tee /etc/cloudflared/config.yml > /dev/null && sudo systemctl restart cloudflared"
