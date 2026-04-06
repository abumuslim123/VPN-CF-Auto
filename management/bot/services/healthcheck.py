"""Фоновый мониторинг exit-нод."""

import asyncio
import logging
import time

import aiohttp

from bot import database as db
from bot.config import HEALTHCHECK_INTERVAL, HEALTHCHECK_TIMEOUT, TG_BOT_TOKEN, TG_ADMIN_ID

log = logging.getLogger(__name__)


async def check_ws_endpoint(host: str) -> tuple[str, int, int]:
    """Проверить WebSocket endpoint. Вернуть (status, http_code, latency_ms)."""
    import ssl
    start = time.monotonic()
    try:
        timeout = aiohttp.ClientTimeout(total=HEALTHCHECK_TIMEOUT)
        headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/131.0.0.0 Safari/537.36",
        }
        async with aiohttp.ClientSession(timeout=timeout, headers=headers) as session:
            ws_headers = {
                "Upgrade": "websocket",
                "Connection": "Upgrade",
                "Sec-WebSocket-Key": "dGVzdA==",
                "Sec-WebSocket-Version": "13",
            }
            async with session.get(
                f"https://{host}", headers=ws_headers, ssl=False
            ) as resp:
                latency = int((time.monotonic() - start) * 1000)
                code = resp.status
                if code in (101, 400, 200):
                    # 101=WS upgrade, 400=server reachable (normal for non-WS), 200=OK
                    return "up", code, latency
                elif code >= 500 or code == 403:
                    return "down", code, latency
                else:
                    return "up", code, latency
    except Exception as e:
        latency = int((time.monotonic() - start) * 1000)
        log.debug("Healthcheck %s failed: %s", host, e)
        return "down", 0, latency


async def check_server(server: dict) -> list[dict]:
    """Проверить все протоколы одного сервера."""
    results = []

    # Desktop WS
    if server["hostname_desktop"]:
        status, code, lat = await check_ws_endpoint(server["hostname_desktop"])
        await db.record_health(server["id"], "desktop_ws", status, code, lat)
        results.append({"protocol": "desktop_ws", "status": status, "code": code, "latency": lat})

    # Mobile VLESS WS
    if server["hostname_mobile"]:
        status, code, lat = await check_ws_endpoint(server["hostname_mobile"])
        await db.record_health(server["id"], "mobile_vless", status, code, lat)
        results.append({"protocol": "mobile_vless", "status": status, "code": code, "latency": lat})

    return results


async def alert_if_needed(server: dict, results: list[dict]):
    """Отправить алерт в Telegram если 3+ подряд failure."""
    for r in results:
        if r["status"] != "down":
            continue
        count = await db.count_consecutive_failures(server["id"], r["protocol"])
        if count >= 3:
            msg = (
                f"⚠️ *{server['name']}* — {r['protocol']} DOWN\n"
                f"HTTP: {r['code']}, Latency: {r['latency']}ms\n"
                f"Failures за 15 мин: {count}"
            )
            await _send_tg_alert(msg)


async def _send_tg_alert(text: str):
    """Отправить сообщение админу."""
    try:
        url = f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage"
        async with aiohttp.ClientSession() as session:
            await session.post(url, json={
                "chat_id": TG_ADMIN_ID,
                "text": text,
                "parse_mode": "Markdown",
            })
    except Exception as e:
        log.error("Ошибка отправки TG алерта: %s", e)


async def healthcheck_loop():
    """Бесконечный цикл мониторинга. Запускать как asyncio task."""
    log.info("Запуск мониторинга (интервал: %ds)", HEALTHCHECK_INTERVAL)

    # Подождать инициализации бота
    await asyncio.sleep(10)

    while True:
        try:
            servers = await db.get_active_servers()
            for server in servers:
                results = await check_server(server)
                await alert_if_needed(server, results)

                statuses = " | ".join(
                    f"{r['protocol']}: {r['status']}" for r in results
                )
                log.debug("[%s] %s", server["name"], statuses)

        except Exception as e:
            log.error("Ошибка в healthcheck loop: %s", e)

        await asyncio.sleep(HEALTHCHECK_INTERVAL)
