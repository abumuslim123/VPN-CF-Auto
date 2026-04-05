"""Хэндлеры: ротация доменов при блокировке."""

from aiogram import Router, F
from aiogram.types import CallbackQuery

from bot.config import TG_ADMIN_ID
from bot import database as db, keyboards as kb
from bot.services import server_manager

router = Router()


@router.callback_query(F.data == "rotation")
async def rotation_menu(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    servers = await db.get_active_servers()
    if not servers:
        await callback.message.edit_text(
            "Нет активных серверов для ротации.",
            reply_markup=kb.back_button(),
        )
        return

    buttons = []
    from aiogram.types import InlineKeyboardButton, InlineKeyboardMarkup
    for s in servers:
        buttons.append([InlineKeyboardButton(
            text=f"🔄 {s['name']} ({s['country'] or '?'})",
            callback_data=f"rot_select:{s['id']}",
        )])
    buttons.append([InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")])

    await callback.message.edit_text(
        "🔄 *Ротация доменов*\n\n"
        "Выберите сервер для ротации:",
        reply_markup=InlineKeyboardMarkup(inline_keyboard=buttons),
        parse_mode="Markdown",
    )


@router.callback_query(F.data.startswith("rot_select:"))
async def rotation_select_type(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    server_id = int(callback.data.split(":")[1])
    server = await db.get_server(server_id)
    if not server:
        return

    await callback.message.edit_text(
        f"🔄 *Ротация для {server['name']}*\n\n"
        f"Текущие домены:\n"
        f"🖥 `{server['hostname_desktop']}`\n"
        f"📱 `{server['hostname_mobile']}`\n\n"
        f"Какой домен ротировать?",
        reply_markup=kb.rotation_type(server_id),
        parse_mode="Markdown",
    )


@router.callback_query(F.data.startswith("rot_exec:"))
async def rotation_exec(callback: CallbackQuery):
    if callback.from_user.id != TG_ADMIN_ID:
        return
    parts = callback.data.split(":")
    server_id = int(parts[1])
    rotate_type = parts[2]

    await callback.message.edit_text("⏳ Выполняю ротацию домена...")

    try:
        result = await server_manager.rotate_domain(server_id, rotate_type)

        lines = ["✅ *Ротация выполнена!*\n\nНовые домены:"]
        if "desktop" in result:
            lines.append(f"🖥 Desktop: `{result['desktop']}`")
        if "mobile" in result:
            lines.append(f"📱 Mobile: `{result['mobile']}`")
        lines.append("\n⚠️ Обновите конфиги клиентов!")

        await callback.message.edit_text(
            "\n".join(lines),
            reply_markup=kb.back_button("rotation"),
            parse_mode="Markdown",
        )
    except Exception as e:
        await callback.message.edit_text(
            f"❌ Ошибка ротации: {e}",
            reply_markup=kb.back_button("rotation"),
        )
