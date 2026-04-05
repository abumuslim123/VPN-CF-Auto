"""Хэндлеры: мониторинг и статус серверов."""

from aiogram import Router, F
from aiogram.types import CallbackQuery

from bot.config import TG_ADMIN_ID
from bot import database as db, keyboards as kb

router = Router()


@router.callback_query(F.data == "monitoring")
async def monitoring_menu(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    servers = await db.get_servers()
    if not servers:
        await callback.message.edit_text(
            "Нет серверов для мониторинга.",
            reply_markup=kb.back_button(),
        )
        return

    # Сводка по всем серверам
    lines = []
    for s in servers:
        status_icon = {
            "active": "🟢", "pending": "🟡", "deploying": "🔵",
            "disabled": "⚪", "error": "🔴",
        }.get(s["status"], "❓")
        count = await db.count_clients_on_server(s["id"])
        lines.append(f"{status_icon} *{s['name']}* ({s['country'] or '?'}) — {count} кл.")

    text = "📊 *Мониторинг*\n\n" + "\n".join(lines)
    text += "\n\nВыберите сервер для деталей:"

    await callback.message.edit_text(
        text,
        reply_markup=kb.monitoring_menu(servers),
        parse_mode="Markdown",
    )


@router.callback_query(F.data.startswith("mon_server:"))
async def mon_server_detail(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    server = await db.get_server(server_id)
    if not server:
        await callback.answer("Сервер не найден", show_alert=True)
        return

    checks = await db.get_recent_health(server_id, limit=12)
    client_count = await db.count_clients_on_server(server_id)

    text = f"📊 *{server['name']}*\n\n"
    text += f"Статус: {server['status']}\n"
    text += f"Клиентов: {client_count}\n\n"

    if checks:
        text += "*Последние проверки:*\n"
        for c in checks:
            icon = {"up": "🟢", "down": "🔴", "degraded": "🟡"}.get(c["status"], "❓")
            proto = {"desktop_ws": "🖥", "mobile_vless": "📱", "ssh": "🔧"}.get(
                c["protocol"], "?"
            )
            text += f"{icon} {proto} HTTP {c['http_code']} ({c['latency_ms']}ms) {c['checked_at'][-8:]}\n"
    else:
        text += "_Нет данных мониторинга_\n"

    await callback.message.edit_text(
        text,
        reply_markup=kb.back_button("monitoring"),
        parse_mode="Markdown",
    )
