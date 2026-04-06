# Образ для management-сервера VPN-инфраст��уктуры
# Python (aiogram) Telegram-бот + утилиты для VPN

FROM python:3.12-alpine

RUN apk add --no-cache \
    bash \
    curl \
    jq \
    openssl \
    wireguard-tools \
    libqrencode-tools \
    sqlite \
    openssh-client \
    coreutils

# Установить cloudflared
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then CF_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then CF_ARCH="arm64"; fi && \
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
      -o /usr/local/bin/cloudflared && \
    chmod +x /usr/local/bin/cloudflared

WORKDIR /app

# Python зависимости
COPY bot/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Скрипты и бот
COPY scripts/ /app/scripts/
COPY templates/ /app/templates/
COPY bot/ /app/bot/
RUN chmod +x /app/scripts/*.sh 2>/dev/null || true

CMD ["python", "-m", "bot.main"]
