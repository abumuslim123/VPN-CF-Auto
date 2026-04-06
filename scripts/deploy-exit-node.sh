#!/bin/bash
# Скрипт деплоя exit-ноды VPN
# Запускается УДАЛЁННО на exit-сервере (через SSH)
#
# Ожидает переменные окружения:
#   CF_TUNNEL_ID, CF_CREDENTIALS_JSON
#   CF_HOSTNAME_DESKTOP, CF_HOSTNAME_MOBILE, CF_HOSTNAME_SSH
#   AWG_PRIVATE_KEY (опционально — сгенерирует если пусто)
#   AWG_JC, AWG_JMIN, AWG_JMAX, AWG_S1, AWG_S2, AWG_H1-H4
#
# Выход: 0 = успех, 1 = ошибка

set -euo pipefail

echo "========================================="
echo "  VPN Exit Node — Автоматический деплой"
echo "========================================="
echo ""

# --- Проверить, что мы root ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: Запустите от root" >&2
    exit 1
fi

# --- Определить сетевой интерфейс ---
MAIN_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -1)
if [ -z "$MAIN_IFACE" ]; then
    echo "ОШИБКА: Не удалось определить сетевой интерфейс" >&2
    exit 1
fi
echo "[1/8] Интерфейс: ${MAIN_IFACE}"

# --- Обновление системы и установка пакетов ---
echo "[2/8] Обновление системы и установка пакетов..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Обновить ядро и заголовки до актуальной версии
apt-get install -y -qq linux-image-generic linux-headers-generic 2>/dev/null || true
# Установить заголовки для текущего ядра
apt-get install -y -qq "linux-headers-$(uname -r)" 2>/dev/null || true

apt-get install -y -qq curl gnupg software-properties-common jq \
    build-essential dkms unzip wget \
    nftables sqlite3 unattended-upgrades 2>/dev/null

# --- sysctl ---
echo "[3/8] Настройка ядра..."
cat > /etc/sysctl.d/99-vpn.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSCTL
sysctl --system > /dev/null 2>&1

# --- Amnezia WireGuard ---
echo "[4/8] Установка Amnezia WireGuard..."
AWG_INSTALLED=false

# Попытка 1: PPA
add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1 || true
apt-get update -qq

# Почистить битые пакеты если остались от прошлой попытки
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y -qq 2>/dev/null || true

if apt-get install -y -qq amneziawg 2>/dev/null; then
    AWG_INSTALLED=true
    echo "  AmneziaWG установлен из PPA"
else
    echo "  AmneziaWG DKMS не собрался, чистим..."
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y -qq 2>/dev/null || true
    # Удалить сломанный пакет
    dpkg --remove --force-remove-reinstreq amneziawg amneziawg-dkms 2>/dev/null || true
fi

# Попытка 2: стандартный WireGuard (работает на всех ядрах 5.6+)
if [ "$AWG_INSTALLED" = false ]; then
    echo "  Устанавливаю стандартный WireGuard..."
    apt-get install -y -qq wireguard wireguard-tools 2>/dev/null
    echo "  ⚠️ Используется WireGuard без обфускации Amnezia"
    echo "  Для AWG обновите ядро: apt upgrade && reboot, затем переустановите"
fi

# Генерация ключей если не заданы
if [ -z "${AWG_PRIVATE_KEY:-}" ]; then
    AWG_PRIVATE_KEY=$(awg genkey 2>/dev/null || wg genkey)
fi
AWG_PUBLIC_KEY=$(echo "$AWG_PRIVATE_KEY" | awg pubkey 2>/dev/null || echo "$AWG_PRIVATE_KEY" | wg pubkey)

# Сохранить ключи
mkdir -p /etc/amnezia/amneziawg
echo "$AWG_PRIVATE_KEY" > /etc/amnezia/amneziawg/server_private.key
chmod 600 /etc/amnezia/amneziawg/server_private.key

# Конфиг AWG
cat > /etc/amnezia/amneziawg/awg0.conf <<AWGCONF
[Interface]
PrivateKey = ${AWG_PRIVATE_KEY}
Address = 10.8.0.1/24
ListenPort = 51820
Jc = ${AWG_JC:-4}
Jmin = ${AWG_JMIN:-40}
Jmax = ${AWG_JMAX:-70}
S1 = ${AWG_S1:-0}
S2 = ${AWG_S2:-0}
H1 = ${AWG_H1:-1}
H2 = ${AWG_H2:-2}
H3 = ${AWG_H3:-3}
H4 = ${AWG_H4:-4}
AWGCONF
chmod 600 /etc/amnezia/amneziawg/awg0.conf

# Запустить AWG
systemctl enable awg-quick@awg0 2>/dev/null || systemctl enable wg-quick@awg0 2>/dev/null
systemctl restart awg-quick@awg0 2>/dev/null || systemctl restart wg-quick@awg0 2>/dev/null
echo "  AWG Public Key: ${AWG_PUBLIC_KEY}"

# --- Xray ---
echo "[5/8] Установка Xray..."
if [ ! -f /usr/local/bin/xray ]; then
    curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh | bash -s install > /dev/null 2>&1
fi

# Создать пользователя
id xray &>/dev/null || useradd -r -s /usr/sbin/nologin xray
mkdir -p /etc/xray /var/log/xray
chown xray:xray /var/log/xray

# Конфиг Xray
cat > /etc/xray/config.json <<'XRAYCONF'
{
  "log": {"loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log"},
  "inbounds": [{
    "listen": "127.0.0.1", "port": 8443, "protocol": "vless",
    "settings": {"clients": [], "decryption": "none"},
    "streamSettings": {"network": "ws", "wsSettings": {"path": "/vless-ws"}}
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {"rules": [{"type": "field", "outboundTag": "block", "ip": ["geoip:private"]}]}
}
XRAYCONF
chown xray:xray /etc/xray/config.json
chmod 600 /etc/xray/config.json

# Systemd unit для Xray
cat > /etc/systemd/system/xray.service <<'XRAYSVC'
[Unit]
Description=Xray VLESS+WebSocket
After=network.target
[Service]
Type=simple
User=xray
Group=xray
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
XRAYSVC

systemctl daemon-reload
systemctl enable xray
systemctl restart xray

# --- wstunnel ---
echo "[6/8] Установка wstunnel..."
WSTUNNEL_VER="10.1.0"
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then WS_ARCH="x86_64"; elif [ "$ARCH" = "aarch64" ]; then WS_ARCH="aarch64"; fi

if [ ! -f /usr/local/bin/wstunnel ]; then
    curl -fsSL "https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER}_linux_${WS_ARCH}.tar.gz" \
        -o /tmp/wstunnel.tar.gz
    tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ wstunnel 2>/dev/null || \
    tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ 2>/dev/null
    chmod +x /usr/local/bin/wstunnel
fi

# Systemd unit для wstunnel
AWG_SVC=$(systemctl list-unit-files | grep -oP '(awg|wg)-quick@awg0\.service' | head -1)
cat > /etc/systemd/system/wstunnel.service <<WSSVC
[Unit]
Description=wstunnel WebSocket Tunnel Server
After=network.target ${AWG_SVC}
Requires=${AWG_SVC}
[Service]
Type=simple
ExecStart=/usr/local/bin/wstunnel server --restrict-to 127.0.0.1:51820 --websocket-ping-frequency-sec 30 ws://127.0.0.1:8080
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
WSSVC

systemctl daemon-reload
systemctl enable wstunnel
systemctl restart wstunnel

# --- cloudflared ---
echo "[7/8] Установка cloudflared и настройка туннеля..."

# Установка cloudflared
if [ ! -f /usr/local/bin/cloudflared ]; then
    curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$(dpkg --print-architecture)" \
        -o /usr/local/bin/cloudflared
    chmod +x /usr/local/bin/cloudflared
fi

# Credentials
mkdir -p /etc/cloudflared
echo "${CF_CREDENTIALS_JSON}" > "/etc/cloudflared/${CF_TUNNEL_ID}.json"
chmod 600 "/etc/cloudflared/${CF_TUNNEL_ID}.json"

# Конфиг
cat > /etc/cloudflared/config.yml <<CFCONF
tunnel: ${CF_TUNNEL_ID}
credentials-file: /etc/cloudflared/${CF_TUNNEL_ID}.json
ingress:
  - hostname: ${CF_HOSTNAME_DESKTOP}
    service: http://127.0.0.1:8080
  - hostname: ${CF_HOSTNAME_MOBILE}
    service: http://127.0.0.1:8443
  - hostname: ${CF_HOSTNAME_SSH}
    service: ssh://127.0.0.1:22
  - service: http_status:404
CFCONF

# Systemd для cloudflared
cat > /etc/systemd/system/cloudflared.service <<CFSVC
[Unit]
Description=Cloudflare Tunnel
After=network.target wstunnel.service xray.service
Wants=wstunnel.service xray.service
[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
CFSVC

systemctl daemon-reload
systemctl enable cloudflared
systemctl restart cloudflared

# --- Firewall (nftables) ---
echo "[8/8] Настройка firewall..."

# Отключить ufw
systemctl stop ufw 2>/dev/null || true
systemctl disable ufw 2>/dev/null || true

cat > /etc/nftables.conf <<NFTCONF
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif "lo" accept
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        # SSH временно открыт — закрыть после проверки туннеля
        tcp dport 22 accept
    }
    chain forward {
        type filter hook forward priority 0; policy drop;
        iifname "awg0" oifname "${MAIN_IFACE}" accept
        iifname "${MAIN_IFACE}" oifname "awg0" ct state established,related accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
table inet nat {
    chain postrouting {
        type nat hook postrouting priority 100;
        oifname "${MAIN_IFACE}" ip saddr 10.8.0.0/24 masquerade
    }
}
NFTCONF

nft -c -f /etc/nftables.conf && {
    systemctl enable nftables
    systemctl restart nftables
}

# --- Проверка ---
echo ""
echo "========================================="
echo "  Деплой завершён!"
echo "========================================="
echo "  AWG Public Key: ${AWG_PUBLIC_KEY}"
echo "  Tunnel ID: ${CF_TUNNEL_ID}"
echo "  Desktop: ${CF_HOSTNAME_DESKTOP}"
echo "  Mobile: ${CF_HOSTNAME_MOBILE}"
echo "  SSH: ${CF_HOSTNAME_SSH}"
echo ""

# Проверить сервисы
for svc in cloudflared wstunnel xray; do
    if systemctl is-active --quiet "$svc"; then
        echo "  ✅ ${svc} — работает"
    else
        echo "  ❌ ${svc} — НЕ работает"
    fi
done

# AWG может быть как awg-quick так и wg-quick
if systemctl is-active --quiet awg-quick@awg0 2>/dev/null || systemctl is-active --quiet wg-quick@awg0 2>/dev/null; then
    echo "  ✅ awg0 — работает"
else
    echo "  ❌ awg0 — НЕ работает"
fi

echo ""
echo "Готово!"
