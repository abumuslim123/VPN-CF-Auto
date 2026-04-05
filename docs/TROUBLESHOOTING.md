# Решение проблем

## Десктоп: wstunnel не подключается

**Симптом**: `wstunnel client` зависает или закрывается сразу.

**Проверки**:
1. Домен доступен: `curl -I https://vpn1.example.com`
   - Если таймаут — домен может быть заблокирован → ротация
   - Если 403/502 — проблема на стороне Cloudflare/сервера
2. cloudflared на exit-ноде:
   ```bash
   ssh_exec 1 sudo systemctl status cloudflared
   ssh_exec 1 sudo journalctl -u cloudflared -n 50
   ```
3. wstunnel на exit-ноде:
   ```bash
   ssh_exec 1 sudo systemctl status wstunnel
   ssh_exec 1 sudo journalctl -u wstunnel -n 50
   ```

## Десктоп: wstunnel работает, AWG не подключается

**Симптом**: `wg-quick up` работает, но нет интернета.

**Проверки**:
1. AWG на exit-ноде видит пир:
   ```bash
   ssh_exec 1 sudo awg show
   ```
   Проверить, что latest handshake обновляется.
2. Forwarding включен:
   ```bash
   ssh_exec 1 sysctl net.ipv4.ip_forward
   # Должно быть = 1
   ```
3. NAT работает:
   ```bash
   ssh_exec 1 sudo nft list table inet nat
   # Должна быть masquerade для 10.8.0.0/24
   ```
4. Обфускация совпадает — параметры Jc/Jmin/Jmax/S1/S2/H1-H4
   в клиентском конфиге ДОЛЖНЫ совпадать с серверным.

## Мобильный: VLESS не подключается

**Симптом**: Приложение показывает ошибку подключения.

**Проверки**:
1. Домен доступен: `curl -I https://vpn1-m.example.com`
2. Xray на exit-ноде:
   ```bash
   ssh_exec 1 sudo systemctl status xray
   ssh_exec 1 sudo journalctl -u xray -n 50
   ```
3. UUID клиента есть в конфиге:
   ```bash
   ssh_exec 1 sudo jq '.inbounds[0].settings.clients' /etc/xray/config.json
   ```
4. Конфиг Xray валиден:
   ```bash
   ssh_exec 1 sudo xray run -test -config /etc/xray/config.json
   ```
5. Время на устройстве — системные часы должны быть точными (±2 мин).

## SSH через CF Tunnel не работает

**Симптом**: `cloudflared access ssh --hostname ssh1.example.com` зависает.

**Проверки**:
1. DNS резолвится: `nslookup ssh1.example.com`
2. cloudflared авторизован: `cloudflared login`
3. Туннель активен в Cloudflare Dashboard → Zero Trust → Tunnels
4. Если потерян доступ — использовать VPS-консоль хостинга (аварийный доступ)

## Потеря доступа к exit-ноде

Если SSH через туннель не работает И прямой SSH заблокирован firewall:

1. **VPS-консоль** — зайти через панель хостинга (VNC/Serial)
2. Проверить cloudflared: `systemctl status cloudflared`
3. Если cloudflared не запускается — временно открыть SSH:
   ```bash
   nft add rule inet filter input tcp dport 22 accept
   ```
4. Исправить cloudflared, перезапустить
5. Убрать временное правило:
   ```bash
   nft flush chain inet filter input && systemctl restart nftables
   ```

## Healthcheck показывает "down"

1. Проверить, что healthcheck-контейнер запущен:
   ```bash
   docker-compose ps
   docker-compose logs healthcheck
   ```
2. Проверить DNS из контейнера:
   ```bash
   docker-compose exec healthcheck nslookup vpn1.example.com
   ```
3. Проверить, что Cloudflare не блокирует запросы (проверить WAF rules)

## Производительность

### Медленная скорость через AWG
- Проверить BBR включен: `sysctl net.ipv4.tcp_congestion_control`
- Проверить MTU (может потребоваться снижение из-за WS-обёртки)
- Проверить загрузку CPU на exit-ноде: `top`

### Медленная скорость через VLESS
- VLESS работает в userspace — ожидаемо медленнее AWG
- Проверить загрузку Xray: `journalctl -u xray`
- Проверить, что используется WS (не gRPC) — WS лучше через CF
