"""Inline-клавиатуры для Telegram-бота."""

from aiogram.types import InlineKeyboardMarkup, InlineKeyboardButton


def main_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="🖥 Серверы", callback_data="servers"),
            InlineKeyboardButton(text="👥 Клиенты", callback_data="clients"),
        ],
        [
            InlineKeyboardButton(text="📊 Мониторинг", callback_data="monitoring"),
            InlineKeyboardButton(text="🔄 Ротация", callback_data="rotation"),
        ],
    ])


# ─── Серверы ─────────────────────────────────────────────

def servers_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Список серверов", callback_data="srv_list")],
        [InlineKeyboardButton(text="➕ Добавить сервер", callback_data="srv_add")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])


def server_actions(server_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="📊 Статус", callback_data=f"srv_status:{server_id}"),
            InlineKeyboardButton(text="👥 Клиенты", callback_data=f"srv_clients:{server_id}"),
        ],
        [
            InlineKeyboardButton(text="🔄 Ротация домена", callback_data=f"srv_rotate:{server_id}"),
            InlineKeyboardButton(text="🔁 Перезапуск", callback_data=f"srv_restart:{server_id}"),
        ],
        [
            InlineKeyboardButton(
                text="⏸ Отключить" , callback_data=f"srv_disable:{server_id}"
            ),
            InlineKeyboardButton(text="🗑 Удалить", callback_data=f"srv_delete:{server_id}"),
        ],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="srv_list")],
    ])


def server_list(servers: list[dict]) -> InlineKeyboardMarkup:
    """Список серверов как кнопки."""
    buttons = []
    for s in servers:
        status_icon = {
            "active": "🟢", "pending": "🟡", "deploying": "🔵",
            "disabled": "⚪", "error": "🔴",
        }.get(s["status"], "❓")
        label = f"{status_icon} {s['name']} ({s['country'] or '?'})"
        buttons.append(
            [InlineKeyboardButton(text=label, callback_data=f"srv_view:{s['id']}")]
        )
    buttons.append([InlineKeyboardButton(text="◀️ Назад", callback_data="servers")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


# ─── Клиенты ─────────────────────────────────────────────

def clients_menu() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="📋 Список клиентов", callback_data="cli_list")],
        [InlineKeyboardButton(text="➕ Добавить клиента", callback_data="cli_add")],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")],
    ])


def client_type_choice() -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🖥 Десктоп (AWG)", callback_data="cli_type:desktop")],
        [InlineKeyboardButton(text="📱 Мобильный (VLESS)", callback_data="cli_type:mobile")],
        [InlineKeyboardButton(text="🔗 Оба", callback_data="cli_type:both")],
        [InlineKeyboardButton(text="◀️ Отмена", callback_data="clients")],
    ])


def server_choice(servers: list[dict], prefix: str = "cli_server") -> InlineKeyboardMarkup:
    """Выбор сервера для нового клиента."""
    buttons = [
        [InlineKeyboardButton(text="🎯 Авто (наименее загруженный)", callback_data=f"{prefix}:auto")]
    ]
    for s in servers:
        count = s.get("client_count", "?")
        label = f"{s['name']} ({s['country'] or '?'}) — {count} кл."
        buttons.append(
            [InlineKeyboardButton(text=label, callback_data=f"{prefix}:{s['id']}")]
        )
    buttons.append([InlineKeyboardButton(text="◀️ Отмена", callback_data="clients")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


def client_actions(client_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="📤 Отправить конфиг", callback_data=f"cli_send:{client_id}"),
            InlineKeyboardButton(text="🗑 Удалить", callback_data=f"cli_revoke:{client_id}"),
        ],
        [InlineKeyboardButton(text="◀️ Назад", callback_data="cli_list")],
    ])


def client_list(clients: list[dict]) -> InlineKeyboardMarkup:
    buttons = []
    for c in clients:
        type_icon = {"desktop": "🖥", "mobile": "📱", "both": "🔗"}.get(c["type"], "?")
        label = f"{type_icon} {c['name']} → {c.get('server_name', '?')}"
        buttons.append(
            [InlineKeyboardButton(text=label, callback_data=f"cli_view:{c['id']}")]
        )
    buttons.append([InlineKeyboardButton(text="◀️ Назад", callback_data="clients")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


# ─── Мониторинг ──────────────────────────────────────────

def monitoring_menu(servers: list[dict]) -> InlineKeyboardMarkup:
    buttons = []
    for s in servers:
        buttons.append(
            [InlineKeyboardButton(
                text=f"📊 {s['name']}", callback_data=f"mon_server:{s['id']}"
            )]
        )
    buttons.append([InlineKeyboardButton(text="◀️ Назад", callback_data="back_main")])
    return InlineKeyboardMarkup(inline_keyboard=buttons)


# ─── Ротация ─────────────────────────────────────────────

def rotation_type(server_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="🖥 Десктоп", callback_data=f"rot_exec:{server_id}:desktop")],
        [InlineKeyboardButton(text="📱 Мобильный", callback_data=f"rot_exec:{server_id}:mobile")],
        [InlineKeyboardButton(text="🔗 Оба", callback_data=f"rot_exec:{server_id}:both")],
        [InlineKeyboardButton(text="◀️ Отмена", callback_data="rotation")],
    ])


# ─── Подтверждение ────────────────────────────────────────

def confirm(action: str, entity_id: int) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [
            InlineKeyboardButton(text="✅ Да", callback_data=f"confirm:{action}:{entity_id}"),
            InlineKeyboardButton(text="❌ Нет", callback_data="back_main"),
        ],
    ])


def back_button(target: str = "back_main") -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup(inline_keyboard=[
        [InlineKeyboardButton(text="◀️ Назад", callback_data=target)],
    ])
