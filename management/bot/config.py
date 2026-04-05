"""Конфигурация бота из переменных окружения."""

import os

# Telegram
TG_BOT_TOKEN = os.environ["TG_BOT_TOKEN"]
TG_ADMIN_ID = int(os.environ["TG_ADMIN_ID"])

# Cloudflare
CF_API_TOKEN = os.environ.get("CF_API_TOKEN", "")
CF_ACCOUNT_ID = os.environ.get("CF_ACCOUNT_ID", "")
CF_ZONE_ID = os.environ.get("CF_ZONE_ID", "")
CF_DOMAIN = os.environ.get("CF_DOMAIN", "")

# AWG обфускация (общая для всех серверов и клиентов)
AWG_JC = int(os.environ.get("AWG_JC", "4"))
AWG_JMIN = int(os.environ.get("AWG_JMIN", "40"))
AWG_JMAX = int(os.environ.get("AWG_JMAX", "70"))
AWG_S1 = int(os.environ.get("AWG_S1", "0"))
AWG_S2 = int(os.environ.get("AWG_S2", "0"))
AWG_H1 = int(os.environ.get("AWG_H1", "1"))
AWG_H2 = int(os.environ.get("AWG_H2", "2"))
AWG_H3 = int(os.environ.get("AWG_H3", "3"))
AWG_H4 = int(os.environ.get("AWG_H4", "4"))

# Пути
DB_PATH = os.environ.get("DB_PATH", "/data/vpn.db")
DATA_DIR = os.environ.get("DATA_DIR", "/data")
CLIENTS_DIR = os.path.join(DATA_DIR, "clients")

# Мониторинг
HEALTHCHECK_INTERVAL = int(os.environ.get("HEALTHCHECK_INTERVAL", "300"))
HEALTHCHECK_TIMEOUT = int(os.environ.get("HEALTHCHECK_TIMEOUT", "10"))
