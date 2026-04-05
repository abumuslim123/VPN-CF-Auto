"""Хэндлеры: /start, главное меню, навигация."""

from aiogram import Router, F
from aiogram.types import Message, CallbackQuery
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext

from bot.config import TG_ADMIN_ID
from bot import keyboards as kb

router = Router()


def is_admin(user_id: int) -> bool:
    return user_id == TG_ADMIN_ID


@router.message(Command("start"))
async def cmd_start(message: Message, state: FSMContext):
    if not is_admin(message.from_user.id):
        await message.answer("⛔ Доступ запрещён. Только для администратора.")
        return
    await state.clear()
    await message.answer(
        "🔐 *VPN Management*\n\nВыберите раздел:",
        reply_markup=kb.main_menu(),
        parse_mode="Markdown",
    )


@router.callback_query(F.data == "back_main")
async def back_to_main(callback: CallbackQuery, state: FSMContext):
    if not is_admin(callback.from_user.id):
        return
    await state.clear()
    await callback.message.edit_text(
        "🔐 *VPN Management*\n\nВыберите раздел:",
        reply_markup=kb.main_menu(),
        parse_mode="Markdown",
    )
