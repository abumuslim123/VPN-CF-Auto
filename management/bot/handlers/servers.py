"""Хэндлеры: управление серверами."""

from aiogram import Router, F
from aiogram.types import Message, CallbackQuery
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup

from bot.config import TG_ADMIN_ID
from bot import database as db, keyboards as kb
from bot.services import server_manager

router = Router()


class AddServer(StatesGroup):
    name = State()
    host = State()
    ssh_user = State()
    ssh_port = State()
    country = State()


# ─── Меню серверов ────────────────────────────────────────

@router.callback_query(F.data == "servers")
async def servers_menu(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    await callback.message.edit_text(
        "🖥 *Серверы*", reply_markup=kb.servers_menu(), parse_mode="Markdown"
    )


@router.callback_query(F.data == "srv_list")
async def server_list(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    servers = await db.get_servers()
    if not servers:
        await callback.message.edit_text(
            "Серверов пока нет. Добавьте первый!",
            reply_markup=kb.servers_menu(),
        )
        return
    await callback.message.edit_text(
        "📋 *Список серверов:*",
        reply_markup=kb.server_list(servers),
        parse_mode="Markdown",
    )


# ─── Просмотр сервера ─────────────────────────────────────

@router.callback_query(F.data.startswith("srv_view:"))
async def server_view(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    server = await db.get_server(server_id)
    if not server:
        await callback.answer("Сервер не найден", show_alert=True)
        return

    client_count = await db.count_clients_on_server(server_id)
    status_icon = {
        "active": "🟢", "pending": "🟡", "deploying": "🔵",
        "disabled": "⚪", "error": "🔴",
    }.get(server["status"], "❓")

    text = (
        f"🖥 *{server['name']}*\n\n"
        f"Статус: {status_icon} {server['status']}\n"
        f"Хост: `{server['host']}`\n"
        f"Страна: {server['country'] or '—'}\n"
        f"Клиентов: {client_count}/{server['max_clients']}\n\n"
        f"🖥 Desktop: `{server['hostname_desktop'] or '—'}`\n"
        f"📱 Mobile: `{server['hostname_mobile'] or '—'}`\n"
        f"🔧 SSH: `{server['hostname_ssh'] or '—'}`\n"
    )
    if server["error_msg"]:
        text += f"\n⚠️ Ошибка: {server['error_msg']}\n"

    await callback.message.edit_text(
        text,
        reply_markup=kb.server_actions(server_id),
        parse_mode="Markdown",
    )


# ─── Добавление сервера (FSM) ────────────────────────────

@router.callback_query(F.data == "srv_add")
async def srv_add_start(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    await state.set_state(AddServer.name)
    await callback.message.edit_text(
        "➕ *Добавление сервера*\n\n"
        "Введите имя (латиница, без пробелов):\n"
        "Пример: `europe-1`, `germany`, `finland-2`",
        parse_mode="Markdown",
    )


@router.message(AddServer.name)
async def srv_add_name(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    name = message.text.strip()
    if not name.replace("-", "").replace("_", "").isalnum():
        await message.answer("❌ Имя может содержать только латиницу, цифры, `-` и `_`")
        return
    await state.update_data(name=name)
    await state.set_state(AddServer.host)
    await message.answer("Введите IP-адрес сервера:")


@router.message(AddServer.host)
async def srv_add_host(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    host = message.text.strip()
    await state.update_data(host=host)
    await state.set_state(AddServer.ssh_user)
    await message.answer("SSH пользователь (по умолчанию `root`):", parse_mode="Markdown")


@router.message(AddServer.ssh_user)
async def srv_add_ssh_user(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    user = message.text.strip() or "root"
    await state.update_data(ssh_user=user)
    await state.set_state(AddServer.ssh_port)
    await message.answer("SSH порт (по умолчанию `22`):", parse_mode="Markdown")


@router.message(AddServer.ssh_port)
async def srv_add_ssh_port(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    text = message.text.strip()
    port = int(text) if text.isdigit() else 22
    await state.update_data(ssh_port=port)
    await state.set_state(AddServer.country)
    await message.answer("Страна (например: DE, FI, NL):")


@router.message(AddServer.country)
async def srv_add_country(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    country = message.text.strip().upper()
    data = await state.get_data()
    data["country"] = country
    await state.clear()

    status_msg = await message.answer("⏳ Создаю сервер и запускаю деплой...")

    # Создать в БД
    server_id = await db.add_server(
        name=data["name"],
        host=data["host"],
        ssh_user=data["ssh_user"],
        ssh_port=data["ssh_port"],
        country=data["country"],
    )

    # Деплой с прогрессом
    async def progress(msg: str):
        try:
            await status_msg.edit_text(f"⏳ {data['name']}: {msg}")
        except Exception:
            pass

    ok = await server_manager.deploy_server(server_id, progress_cb=progress)

    if ok:
        server = await db.get_server(server_id)
        await status_msg.edit_text(
            f"✅ Сервер *{data['name']}* развёрнут!\n\n"
            f"🖥 Desktop: `{server['hostname_desktop']}`\n"
            f"📱 Mobile: `{server['hostname_mobile']}`\n"
            f"🔧 SSH: `{server['hostname_ssh']}`",
            reply_markup=kb.server_actions(server_id),
            parse_mode="Markdown",
        )
    else:
        server = await db.get_server(server_id)
        await status_msg.edit_text(
            f"❌ Ошибка деплоя *{data['name']}*\n\n"
            f"{server.get('error_msg', 'Неизвестная ошибка')}",
            reply_markup=kb.servers_menu(),
            parse_mode="Markdown",
        )


# ─── Действия с сервером ──────────────────────────────────

@router.callback_query(F.data.startswith("srv_restart:"))
async def srv_restart(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    await callback.message.edit_text("⏳ Перезапуск сервисов...")
    ok, msg = await server_manager.restart_services(server_id)
    emoji = "✅" if ok else "❌"
    await callback.message.edit_text(
        f"{emoji} {msg}",
        reply_markup=kb.server_actions(server_id),
    )


@router.callback_query(F.data.startswith("srv_disable:"))
async def srv_disable(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    server = await db.get_server(server_id)
    if not server:
        return

    new_status = "disabled" if server["status"] == "active" else "active"
    await db.update_server(server_id, status=new_status)
    emoji = "⏸" if new_status == "disabled" else "▶️"
    await callback.answer(f"{emoji} Сервер {'отключён' if new_status == 'disabled' else 'включён'}")

    # Обновить view
    await server_view(callback)


@router.callback_query(F.data.startswith("srv_delete:"))
async def srv_delete_confirm(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    server = await db.get_server(server_id)
    if not server:
        return
    await callback.message.edit_text(
        f"🗑 Удалить сервер *{server['name']}* и всех его клиентов?\n\n"
        f"⚠️ Это действие необратимо!",
        reply_markup=kb.confirm("srv_del", server_id),
        parse_mode="Markdown",
    )


@router.callback_query(F.data.startswith("confirm:srv_del:"))
async def srv_delete_exec(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[2])
    server = await db.get_server(server_id)
    if server and server["cf_tunnel_id"]:
        try:
            from bot.services.cloudflare import delete_tunnel
            await delete_tunnel(server["cf_tunnel_id"])
        except Exception:
            pass
    await db.delete_server(server_id)
    await callback.message.edit_text(
        "🗑 Сервер удалён.",
        reply_markup=kb.servers_menu(),
    )


@router.callback_query(F.data.startswith("srv_status:"))
async def srv_status(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    checks = await db.get_recent_health(server_id, limit=6)
    if not checks:
        await callback.answer("Нет данных мониторинга", show_alert=True)
        return

    lines = []
    for c in checks:
        icon = {"up": "🟢", "down": "🔴", "degraded": "🟡"}.get(c["status"], "❓")
        lines.append(f"{icon} {c['protocol']} — HTTP {c['http_code']} ({c['latency_ms']}ms)")

    await callback.message.edit_text(
        f"📊 *Последние проверки:*\n\n" + "\n".join(lines),
        reply_markup=kb.server_actions(server_id),
        parse_mode="Markdown",
    )
