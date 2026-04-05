# Ротация доменов при блокировке

## Когда нужна ротация

Если DPI-блокировщик заблокировал конкретный субдомен (например, `vpn1.example.com`),
нужно быстро создать новый субдомен и переключить клиентов.

## Автоматическая ротация

```bash
# Ротация десктопного субдомена для ноды 1
./cloudflare/rotate-domain.sh --node 1 --type desktop

# Ротация мобильного субдомена
./cloudflare/rotate-domain.sh --node 1 --type mobile

# Ротация обоих
./cloudflare/rotate-domain.sh --node 1 --type both
```

Скрипт:
1. Генерирует случайный субдомен (например, `v1-a3f7c21e.example.com`)
2. Создаёт CNAME-запись в Cloudflare (proxied)
3. Обновляет ingress-конфиг cloudflared на exit-ноде через SSH
4. Перезапускает cloudflared
5. Отправляет уведомление в Telegram

## Ротация домена верхнего уровня

Если заблокирован весь `example.com`:

1. Заранее добавить backup-домен в Cloudflare
2. Запустить ротацию с новым доменом:
   ```bash
   ./cloudflare/rotate-domain.sh --node 1 --type both --new-domain backup-domain.com
   ```

## После ротации

### Десктоп-клиенты
Обновить `WS_HOST` в `connect.sh`:
```bash
WS_HOST="v1-a3f7c21e.example.com"  # Новый хост
```

### Мобильные клиенты
Сгенерировать новые VLESS URI с новым хостом и отправить клиентам QR-код.

## Мониторинг блокировок

Healthcheck автоматически проверяет доступность хостов.
При трёх подряд неудачных проверках — алерт в Telegram.

```bash
# Ручная проверка
curl -v -H "Upgrade: websocket" -H "Connection: Upgrade" \
  -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
  -H "Sec-WebSocket-Version: 13" \
  https://vpn1.example.com
# Ожидаемый ответ: HTTP 101 Switching Protocols
```

## Подготовка к ротации

Рекомендуется заранее:
1. Иметь backup-домен в Cloudflare
2. Настроить мониторинг (healthcheck в Docker)
3. Проверить доступ к exit-нодам через SSH-туннель
4. Убедиться, что Telegram-бот работает
