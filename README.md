# Гибридная VPN-инфраструктура через Cloudflare

VPN для обхода DPI-блокировок. Весь трафик идёт через Cloudflare CDN —
блокировщики видят обращение к Cloudflare, а не к VPN-серверу.

## Два протокола

| Протокол | Клиенты | Стек |
|----------|---------|------|
| **AWG** (десктоп) | Linux, macOS, Windows | wstunnel + Amnezia WireGuard |
| **VLESS** (мобильные) | Android, iOS | Xray + WebSocket + TLS |

## Особенности

- **Неограниченное число серверов** — добавляйте exit-ноды в любой стране
- **Round-robin балансировка** — клиенты распределяются на наименее загруженный сервер
- **Всё управление через Telegram-бот** — серверы, клиенты, мониторинг, ротация
- **Автоматический setup** — один скрипт настраивает всё
- **Автоматическая ротация доменов** при блокировке

## Быстрый старт

### 1. Подготовка

Что нужно:
- Домен на Cloudflare (Free план)
- 1+ VPS за рубежом (Ubuntu 22.04/24.04)
- Сервер в России для management (Docker)
- Telegram-бот (создать у @BotFather)

### 2. Запуск setup wizard

```bash
git clone <repo> && cd vpn-infra
bash setup.sh
```

Wizard спросит:
1. **Cloudflare** — API token, Account ID, Zone ID, домен
2. **Telegram** — токен бота, ваш Chat ID
3. **AWG обфускация** — сгенерирует случайные параметры
4. **Серверы** — IP, SSH данные для каждой exit-ноды

Затем автоматически:
- Настроит Cloudflare (SSL, WebSocket, DNS)
- Создаст CF Tunnel для каждого сервера
- Развернёт VPN-сервисы (AWG + Xray + wstunnel + cloudflared)
- Настроит firewall
- Запустит Telegram-бота

### 3. Управление через Telegram

Откройте бота и отправьте `/start`:

```
🖥 Серверы     — добавить/удалить/перезапустить
👥 Клиенты     — создать конфиг (AWG/VLESS), отправить QR
📊 Мониторинг  — статус серверов, healthcheck
🔄 Ротация     — сменить домен при блокировке
```

#### Добавить клиента
1. 👥 Клиенты → ➕ Добавить
2. Ввести имя
3. Выбрать тип: Десктоп / Мобильный / Оба
4. Выбрать сервер или "Авто" (round-robin)
5. Бот отправит файлы конфигурации + QR-код

#### Добавить новый сервер
1. 🖥 Серверы → ➕ Добавить
2. Ввести имя, IP, SSH данные, страну
3. Бот автоматически развернёт VPN-сервисы

## Архитектура

```
Клиент → Cloudflare CDN → CF Tunnel → Exit Node → Интернет
                                        ├─ wstunnel (десктоп)
                                        ├─ Xray VLESS (мобильный)
                                        └─ nftables (drop all inbound)

Management (Россия) → Telegram Bot
                    → Docker (Python aiogram)
                    → SQLite (серверы, клиенты, healthcheck)
                    → SSH через CF Tunnel → Exit Nodes
```

## Структура проекта

```
├── setup.sh                  # Интерактивный wizard первоначальной настройки
├── .env.example              # Шаблон конфигурации
├── scripts/
│   └── deploy-exit-node.sh   # Скрипт деплоя exit-ноды (выполняется удалённо)
├── management/
│   ├── docker-compose.yml    # Docker stack
│   ├── Dockerfile            # Python + утилиты
│   └── bot/                  # Telegram-бот (aiogram)
│       ├── main.py           # Точка входа
│       ├── database.py       # SQLite (серверы, клиенты, IP-пул)
│       ├── keyboards.py      # Inline-клавиатуры
│       ├── handlers/         # Обработчики команд
│       │   ├── start.py      # /start, главное меню
│       │   ├── servers.py    # Управление серверами
│       │   ├── clients.py    # Управление клиентами
│       │   ├── monitoring.py # Мониторинг
│       │   └── rotation.py   # Ротация доменов
│       └── services/         # Бизнес-логика
│           ├── ssh.py        # SSH операции
│           ├── cloudflare.py # CF API
│           ├── server_manager.py
│           ├── client_manager.py
│           └── healthcheck.py
├── ansible/                  # Ansible роли (альтернативный деплой)
├── cloudflare/               # Standalone CF скрипты
├── client/                   # Клиентские скрипты и инструкции
│   ├── desktop/              # connect.sh, connect.ps1
│   └── mobile/               # QR генератор, README
└── docs/                     # Документация
```

## Документация

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — архитектура
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — ручное развёртывание
- [docs/ROTATION.md](docs/ROTATION.md) — ротация доменов
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — решение проблем
- [client/mobile/README-mobile.md](client/mobile/README-mobile.md) — инструкция для мобильных
