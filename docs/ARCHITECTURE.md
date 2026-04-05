# Архитектура VPN-инфраструктуры

## Обзор

Вся инфраструктура построена на принципе: **клиенты никогда не подключаются
к VPN-серверу напрямую**. Весь трафик проксируется через Cloudflare CDN.

Для DPI-блокировщика трафик выглядит как обычные HTTPS-запросы к Cloudflare.

## Схема компонентов

```
┌─────────────────────────────────────────────────────────┐
│                    КЛИЕНТЫ                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐              │
│  │ Desktop  │  │ Android  │  │   iOS    │              │
│  │ wstunnel │  │ NekoBox  │  │Streisand │              │
│  │ + AWG    │  │  VLESS   │  │  VLESS   │              │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘              │
│       │WSS          │VLESS+WS      │VLESS+WS           │
└───────┼─────────────┼──────────────┼────────────────────┘
        │             │              │
   ┌────▼─────────────▼──────────────▼────┐
   │         CLOUDFLARE CDN               │
   │  vpn1.example.com  (десктоп)         │
   │  vpn1-m.example.com (мобильный)      │
   │  ssh1.example.com   (управление)     │
   │                                      │
   │  TLS-терминация на edge              │
   │  CNAME → tunnel-id.cfargotunnel.com  │
   └──────────────┬───────────────────────┘
                  │ Cloudflare Tunnel
                  │ (исходящее соединение от сервера)
   ┌──────────────▼───────────────────────┐
   │          EXIT NODE (Европа)           │
   │                                      │
   │  cloudflared (:7844 outbound)        │
   │    ├→ http://127.0.0.1:8080 (AWG)   │
   │    ├→ http://127.0.0.1:8443 (VLESS) │
   │    └→ ssh://127.0.0.1:22   (SSH)    │
   │                                      │
   │  wstunnel server (:8080)             │
   │    └→ UDP 127.0.0.1:51820           │
   │                                      │
   │  Amnezia WireGuard (awg0, :51820)   │
   │    └→ NAT masquerade → Интернет     │
   │                                      │
   │  Xray (:8443)                        │
   │    └→ VLESS decode → Интернет       │
   │                                      │
   │  nftables: DROP ALL INBOUND          │
   └──────────────────────────────────────┘

   ┌──────────────────────────────────────┐
   │       MANAGEMENT (Россия)             │
   │                                      │
   │  Docker Compose:                     │
   │    ├ management (gen-client-config)  │
   │    └ healthcheck (мониторинг)        │
   │                                      │
   │  SSH через CF Tunnel                 │
   │  Telegram-бот для алертов            │
   │  SQLite: IP-пул + healthchecks       │
   └──────────────────────────────────────┘
```

## Протоколы

### Десктоп: wstunnel + Amnezia WireGuard

```
Клиент → wstunnel client (WSS) → Cloudflare → cloudflared
→ wstunnel server (TCP→UDP) → AWG (UDP, обфускация) → Интернет
```

- **Скорость**: высокая (WireGuard ядро)
- **Обфускация**: Amnezia параметры (Jc, Jmin, Jmax, S1, S2, H1-H4)
- **Транспорт**: WebSocket поверх TLS (через Cloudflare)
- **Клиент**: wstunnel + awg-quick

### Мобильный: VLESS + WebSocket

```
Клиент → VLESS+WS+TLS → Cloudflare → cloudflared
→ Xray (VLESS decode) → freedom outbound → Интернет
```

- **Скорость**: средняя (userspace proxy)
- **Обфускация**: TLS + WebSocket (выглядит как HTTPS)
- **Транспорт**: WebSocket поверх TLS (через Cloudflare)
- **Клиент**: NekoBox, Hiddify, V2rayNG, Streisand

## Безопасность

### Сетевая изоляция
- Все сервисы слушают на `127.0.0.1` (не доступны извне)
- nftables: `policy drop` на все входящие
- SSH доступен ТОЛЬКО через Cloudflare Tunnel
- cloudflared использует ТОЛЬКО исходящие соединения

### Защита от атак
- Xray: блокировка запросов к приватным IP (geoip:private)
- wstunnel: `--restrict-to 127.0.0.1:51820` (только AWG порт)
- Cloudflare: DDoS-защита на edge
- fail2ban на SSH (через туннель)

### Секреты
- Ansible Vault для шифрования host_vars
- `.env` в `.gitignore`
- Tunnel credentials с правами 600
- AWG ключи генерируются на сервере, не передаются в открытом виде

## Systemd зависимости

```
awg-quick@awg0 ← wstunnel (Requires=)
                  xray (standalone)
                  ↑
                  cloudflared (Wants= wstunnel, xray; After=)
```

- `wstunnel` зависит от `awg-quick@awg0` (жёсткая зависимость)
- `cloudflared` хочет `wstunnel` и `xray` (мягкая — чтобы SSH работал даже если VPN упал)
