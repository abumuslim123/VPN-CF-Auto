"""Cloudflare API: туннели, DNS, настройки зоны."""

import logging
import secrets
import base64
import json

import aiohttp

from bot.config import CF_API_TOKEN, CF_ZONE_ID, CF_DOMAIN, CF_ACCOUNT_ID

log = logging.getLogger(__name__)
API = "https://api.cloudflare.com/client/v4"


async def _request(method: str, path: str, data: dict = None) -> dict:
    """Вызов Cloudflare API."""
    headers = {
        "Authorization": f"Bearer {CF_API_TOKEN}",
        "Content-Type": "application/json",
    }
    url = f"{API}{path}"
    async with aiohttp.ClientSession() as session:
        async with session.request(method, url, headers=headers, json=data) as resp:
            body = await resp.json()
            if not body.get("success"):
                errors = body.get("errors", [])
                log.error("CF API error: %s %s → %s", method, path, errors)
                raise RuntimeError(f"Cloudflare API: {errors}")
            return body


# ─── Туннели ──────────────────────────────────────────────

async def create_tunnel(name: str) -> tuple[str, str, str]:
    """Создать CF Tunnel. Вернуть (tunnel_id, tunnel_secret, credentials_json)."""
    tunnel_secret = base64.b64encode(secrets.token_bytes(32)).decode()

    body = await _request("POST", f"/accounts/{CF_ACCOUNT_ID}/cfd_tunnel", {
        "name": name,
        "tunnel_secret": tunnel_secret,
    })

    tunnel_id = body["result"]["id"]
    credentials = json.dumps({
        "AccountTag": CF_ACCOUNT_ID,
        "TunnelSecret": tunnel_secret,
        "TunnelID": tunnel_id,
    })

    log.info("Создан туннель %s: %s", name, tunnel_id)
    return tunnel_id, tunnel_secret, credentials


async def delete_tunnel(tunnel_id: str):
    """Удалить CF Tunnel."""
    await _request("DELETE", f"/accounts/{CF_ACCOUNT_ID}/cfd_tunnel/{tunnel_id}")


# ─── DNS ──────────────────────────────────────────────────

async def upsert_cname(subdomain: str, target: str):
    """Создать или обновить проксированную CNAME-запись."""
    fqdn = f"{subdomain}.{CF_DOMAIN}"

    # Проверить существование
    resp = await _request(
        "GET",
        f"/zones/{CF_ZONE_ID}/dns_records?type=CNAME&name={fqdn}",
    )

    records = resp["result"]
    record_data = {
        "type": "CNAME",
        "name": subdomain,
        "content": target,
        "proxied": True,
        "ttl": 1,
    }

    if records:
        record_id = records[0]["id"]
        await _request(
            "PATCH",
            f"/zones/{CF_ZONE_ID}/dns_records/{record_id}",
            record_data,
        )
        log.info("DNS обновлён: %s → %s", fqdn, target)
    else:
        await _request(
            "POST",
            f"/zones/{CF_ZONE_ID}/dns_records",
            record_data,
        )
        log.info("DNS создан: %s → %s", fqdn, target)


async def delete_cname(subdomain: str):
    """Удалить CNAME-запись."""
    fqdn = f"{subdomain}.{CF_DOMAIN}"
    resp = await _request(
        "GET",
        f"/zones/{CF_ZONE_ID}/dns_records?type=CNAME&name={fqdn}",
    )
    for record in resp["result"]:
        await _request("DELETE", f"/zones/{CF_ZONE_ID}/dns_records/{record['id']}")
        log.info("DNS удалён: %s", fqdn)


async def setup_zone_settings():
    """Настроить зональные параметры для VPN."""
    settings = {
        "ssl": "strict",
        "websockets": "on",
        "min_tls_version": "1.2",
        "always_use_https": "on",
        "tls_1_3": "zrt",
    }
    for key, value in settings.items():
        await _request(
            "PATCH",
            f"/zones/{CF_ZONE_ID}/settings/{key}",
            {"value": value},
        )
    log.info("Настройки зоны применены")


def generate_random_subdomain(prefix: str) -> str:
    """Генерация случайного субдомена для ротации."""
    return f"{prefix}-{secrets.token_hex(4)}"
