"""Хэндлеры: управление клиентами."""

import os

from aiogram import Router, F
from aiogram.types import Message, CallbackQuery, FSInputFile
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup

from bot.config import TG_ADMIN_ID
from bot import database as db, keyboards as kb
from bot.services import client_manager

router = Router()


class AddClient(StatesGroup):
    name = State()
    client_type = State()
    server_id = State()


# ─── Меню клиентов ────────────────────────────────────────

@router.callback_query(F.data == "clients")
async def clients_menu(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    await state.clear()
    await callback.message.edit_text(
        "👥 *Клиенты*", reply_markup=kb.clients_menu(), parse_mode="Markdown"
    )


@router.callback_query(F.data == "cli_list")
async def client_list(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    clients = await db.get_clients()
    if not clients:
        await callback.message.edit_text(
            "Клиентов пока нет.",
            reply_markup=kb.clients_menu(),
        )
        return
    await callback.message.edit_text(
        "📋 *Список клиентов:*",
        reply_markup=kb.client_list(clients),
        parse_mode="Markdown",
    )


# ─── Просмотр клиента ────────────────────────────────────

@router.callback_query(F.data.startswith("cli_view:"))
async def client_view(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    client_id = int(callback.data.split(":")[1])
    client = await db.get_client(client_id)
    if not client:
        await callback.answer("Клиент не найден", show_alert=True)
        return

    server = await db.get_server(client["server_id"])
    type_map = {"desktop": "🖥 Десктоп", "mobile": "📱 Мобильный", "both": "🔗 Оба"}

    text = (
        f"👤 *{client['name']}*\n\n"
        f"Тип: {type_map.get(client['type'], '?')}\n"
        f"Сервер: {server['name'] if server else '?'}\n"
    )
    if client["awg_ip"]:
        text += f"AWG IP: `{client['awg_ip']}`\n"
    if client["vless_uuid"]:
        text += f"VLESS UUID: `{client['vless_uuid']}`\n"
    text += f"Создан: {client['created_at']}\n"

    await callback.message.edit_text(
        text,
        reply_markup=kb.client_actions(client_id),
        parse_mode="Markdown",
    )


# ─── Добавление клиента (FSM) ────────────────────────────

@router.callback_query(F.data == "cli_add")
async def cli_add_start(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    # Проверить наличие серверов
    servers = await db.get_active_servers()
    if not servers:
        await callback.answer("Сначала добавьте хотя бы один сервер!", show_alert=True)
        return

    await state.set_state(AddClient.name)
    await callback.message.edit_text(
        "➕ *Добавление клиента*\n\n"
        "Введите имя (латиница, без пробелов):",
        parse_mode="Markdown",
    )


@router.message(AddClient.name)
async def cli_add_name(message: Message, state: FSMContext):
    if message.from_user.id != TG_ADMIN_ID:
        return
    name = message.text.strip()
    if not name.replace("-", "").replace("_", "").isalnum():
        await message.answer("❌ Имя: только латиница, цифры, `-`, `_`")
        return
    # Проверить уникальность
    existing = await db.get_client_by_name(name)
    if existing:
        await message.answer(f"❌ Клиент `{name}` уже существует", parse_mode="Markdown")
        return
    await state.update_data(name=name)
    await state.set_state(AddClient.client_type)
    await message.answer(
        "Выберите тип подключения:",
        reply_markup=kb.client_type_choice(),
    )


@router.callback_query(AddClient.client_type, F.data.startswith("cli_type:"))
async def cli_add_type(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    client_type = callback.data.split(":")[1]
    await state.update_data(client_type=client_type)
    await state.set_state(AddClient.server_id)

    # Список серверов с числом клиентов
    servers = await db.get_active_servers()
    server_data = []
    for s in servers:
        count = await db.count_clients_on_server(s["id"])
        s_copy = dict(s)
        s_copy["client_count"] = count
        server_data.append(s_copy)

    await callback.message.edit_text(
        "Выберите сервер:",
        reply_markup=kb.server_choice(server_data),
    )


@router.callback_query(AddClient.server_id, F.data.startswith("cli_server:"))
async def cli_add_server(callback: CallbackQuery, state: FSMContext):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    choice = callback.data.split(":")[1]
    server_id = None if choice == "auto" else int(choice)
    data = await state.get_data()
    await state.clear()

    status_msg = await callback.message.edit_text("⏳ Генерация конфигурации...")

    try:
        result = await client_manager.create_client(
            name=data["name"],
            client_type=data["client_type"],
            server_id=server_id,
        )

        text = f"✅ Клиент *{data['name']}* создан!\n\n"
        text += f"Сервер: {result['server']['name']}\n"

        if "awg_ip" in result:
            text += f"AWG IP: `{result['awg_ip']}`\n"
            text += f"WS Host: `{result['ws_host']}`\n"
        if "vless_uri" in result:
            text += f"\nVLESS URI:\n`{result['vless_uri']}`\n"

        await status_msg.edit_text(text, parse_mode="Markdown")

        # Отправить файлы
        for fpath in result.get("files", []):
            if os.path.exists(fpath):
                doc = FSInputFile(fpath, filename=os.path.basename(fpath))
                if fpath.endswith(".png"):
                    await callback.message.answer_photo(
                        doc, caption=f"QR-код для {data['name']}"
                    )
                else:
                    await callback.message.answer_document(
                        doc, caption=os.path.basename(fpath)
                    )

    except Exception as e:
        await status_msg.edit_text(
            f"❌ Ошибка: {e}",
            reply_markup=kb.clients_menu(),
        )


# ─── Отправка конфига ─────────────────────────────────────

@router.callback_query(F.data.startswith("cli_send:"))
async def cli_send_config(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    client_id = int(callback.data.split(":")[1])
    client = await db.get_client(client_id)
    if not client:
        await callback.answer("Клиент не найден", show_alert=True)
        return

    from bot.config import CLIENTS_DIR
    client_dir = os.path.join(CLIENTS_DIR, client["name"])

    if not os.path.exists(client_dir):
        await callback.answer("Файлы конфигурации не найдены", show_alert=True)
        return

    sent = 0
    for fname in os.listdir(client_dir):
        fpath = os.path.join(client_dir, fname)
        doc = FSInputFile(fpath, filename=fname)
        if fname.endswith(".png"):
            await callback.message.answer_photo(doc, caption=f"{client['name']}: {fname}")
        else:
            await callback.message.answer_document(doc, caption=fname)
        sent += 1

    if sent == 0:
        await callback.answer("Нет файлов для отправки", show_alert=True)
    else:
        await callback.answer(f"Отправлено {sent} файлов")


# ─── Удаление клиента ─────────────────────────────────────

@router.callback_query(F.data.startswith("cli_revoke:"))
async def cli_revoke_confirm(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    client_id = int(callback.data.split(":")[1])
    client = await db.get_client(client_id)
    if not client:
        return
    await callback.message.edit_text(
        f"🗑 Удалить клиента *{client['name']}*?",
        reply_markup=kb.confirm("cli_del", client_id),
        parse_mode="Markdown",
    )


@router.callback_query(F.data.startswith("confirm:cli_del:"))
async def cli_revoke_exec(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    client_id = int(callback.data.split(":")[2])
    await callback.message.edit_text("⏳ Удаление...")
    try:
        await client_manager.revoke_client_on_server(client_id)
        await callback.message.edit_text(
            "🗑 Клиент удалён.", reply_markup=kb.clients_menu()
        )
    except Exception as e:
        await callback.message.edit_text(f"❌ Ошибка: {e}", reply_markup=kb.clients_menu())


# ─── Клиенты конкретного сервера ──────────────────────────

@router.callback_query(F.data.startswith("srv_clients:"))
async def srv_clients(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    clients = await db.get_clients(server_id=server_id)
    if not clients:
        await callback.answer("Нет клиентов на этом сервере", show_alert=True)
        return
    await callback.message.edit_text(
        "📋 *Клиенты на сервере:*",
        reply_markup=kb.client_list(clients),
        parse_mode="Markdown",
    )
