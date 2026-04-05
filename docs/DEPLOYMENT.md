# Пошаговое развёртывание

## Предварительные требования

- Домен на Cloudflare (Free план)
- VPS в Европе (Ubuntu 22.04/24.04, 1 vCPU, 1 GB RAM достаточно)
- Management сервер (Россия, Docker)
- На локальной машине: `ansible`, `cloudflared`, `jq`

## Шаг 1: Подготовка .env

```bash
cp .env.example .env
nano .env
```

Заполнить:
- `CF_API_TOKEN` — создать в Cloudflare Dashboard → Profile → API Tokens
  - Права: Zone:DNS:Edit, Zone:Zone Settings:Edit
- `CF_ACCOUNT_ID` — Dashboard → правая панель → Account ID
- `CF_ZONE_ID` — Dashboard → правая панель → Zone ID
- `CF_DOMAIN` — ваш домен
- `TG_BOT_TOKEN` — создать бота у @BotFather
- `TG_CHAT_ID` — отправить сообщение боту, получить ID через API

## Шаг 2: Авторизация cloudflared

```bash
cloudflared login
# Откроется браузер, выбрать домен
```

## Шаг 3: Создать Cloudflare Tunnels

```bash
cd cloudflare
./setup-tunnels.sh
```

Скрипт:
1. Создаст туннель `vpn-node1`
2. Сохранит credentials в `management/data/tunnels/node1.json`
3. Выведет `CF_TUNNEL_ID_NODE1` — добавить в `.env`

## Шаг 4: Создать DNS-записи

```bash
./setup-dns.sh
```

Создаст CNAME записи (proxied) для vpn1, vpn1-m, ssh1.

## Шаг 5: Настроить зону Cloudflare

```bash
./cloudflare-settings.sh
```

## Шаг 6: Подготовить Ansible

```bash
cd ansible
nano inventory/host_vars/exit01.yml
```

Заполнить:
- `exit01_real_ip` — IP VPS
- `cloudflared_tunnel_id` — из шага 3
- `cloudflared_account_tag` — CF Account ID
- `cloudflared_tunnel_secret` — из `management/data/tunnels/node1.json` (поле TunnelSecret)
- `awg_server_private_key` — сгенерировать: `awg genkey`

Зашифровать:
```bash
ansible-vault encrypt inventory/host_vars/exit01.yml
```

## Шаг 7: Развернуть exit-ноду

```bash
ansible-playbook playbooks/exit-node.yml --ask-vault-pass
```

Роли установятся в порядке: common → amneziawg → xray → wstunnel → cloudflared → firewall.

SSH остаётся открытым (firewall_allow_ssh_during_setup: true).

## Шаг 8: Проверить CF Tunnel

```bash
# Проверить доступность через туннель
cloudflared access ssh --hostname ssh1.example.com

# На exit-ноде:
sudo awg show                    # AWG работает
sudo systemctl status wstunnel   # wstunnel работает
sudo systemctl status xray       # Xray работает
sudo systemctl status cloudflared # Туннель работает
```

## Шаг 9: Закрыть SSH

```bash
# В inventory/group_vars/exit_nodes.yml:
# firewall_allow_ssh_during_setup: false

ansible-playbook playbooks/exit-node.yml --tags firewall --ask-vault-pass
```

**ВНИМАНИЕ**: После этого шага SSH на прямой IP **заблокирован навсегда**.
Доступ только через `cloudflared access ssh --hostname ssh1.example.com`.

## Шаг 10: Запустить management

```bash
cd management
docker-compose up -d
```

## Шаг 11: Сгенерировать клиентские конфиги

```bash
# Десктоп
docker-compose exec management /app/scripts/gen-client-config.sh \
  --name ivan --type desktop --node 1

# Мобильный
docker-compose exec management /app/scripts/gen-client-config.sh \
  --name ivan-phone --type mobile --node 1
```

Конфиги появятся в `management/data/clients/`.

## Шаг 12: Подключить клиентов

**Десктоп**: передать `connect.sh` + `awg-client.conf`
**Мобильный**: отсканировать QR из `vless-qr.png`

## Добавление второй ноды

1. Заполнить `CF_TUNNEL_ID_NODE2` в `.env`
2. Создать `ansible/inventory/host_vars/exit02.yml`
3. Раскомментировать exit02 в `ansible/inventory/hosts.yml`
4. Повторить шаги 6-9
