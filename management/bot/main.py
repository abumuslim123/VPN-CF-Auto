"""Точка входа Telegram-бота VPN Management.

Запуск: python -m bot.main
"""

import asyncio
import logging

from aiogram import Bot, Dispatcher

from bot.config import TG_BOT_TOKEN
from bot.database import init_db
from bot.handlers import start, servers, clients, monitoring, rotation
from bot.services.healthcheck import healthcheck_loop

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
)
log = logging.getLogger(__name__)


async def main():
    log.info("Инициализация бота...")

    # Инициализация БД
    await init_db()

    # Бот и диспетчер
    bot = Bot(token=TG_BOT_TOKEN)
    dp = Dispatcher()

    # Регистрация хэндлеров
    dp.include_router(start.router)
    dp.include_router(servers.router)
    dp.include_router(clients.router)
    dp.include_router(monitoring.router)
    dp.include_router(rotation.router)

    # Запуск healthcheck в фоне
    asyncio.create_task(healthcheck_loop())

    log.info("Бот запущен. Polling...")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
