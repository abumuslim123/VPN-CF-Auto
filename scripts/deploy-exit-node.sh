#!/bin/bash
# Скрипт деплоя exit-ноды VPN
# Запускается УДАЛЁННО на exit-сервере (через SSH)
#
# ИДЕМПОТЕНТНЫЙ — можно запускать повторно.
# Каждый шаг проверяет, нужна ли установка. При ошибке — продолжает дальше.
#
# Ожидает переменные окружения:
#   CF_TUNNEL_ID, CF_CREDENTIALS_JSON
#   CF_HOSTNAME_DESKTOP, CF_HOSTNAME_MOBILE, CF_HOSTNAME_SSH
#   AWG_PRIVATE_KEY (опционально — сгенерирует если пусто)
#   AWG_JC, AWG_JMIN, AWG_JMAX, AWG_S1, AWG_S2, AWG_H1-H4

# НЕ используем set -e — ошибки обрабатываем вручную
set -uo pipefail

ERRORS=0

ok()   { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; ERRORS=$((ERRORS + 1)); }
skip() { echo "  ⏭️  $1 (уже установлено)"; }

echo "========================================="
echo "  VPN Exit Node — Автоматический деплой"
echo "========================================="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "ОШИБКА: Запустите от root" >&2
    exit 1
fi

# ─── 1/8: Сетевой интерфейс ──────────────────────────────
echo "[1/8] Определение сетевого интерфейса..."
MAIN_IFACE=$(ip -o -4 route show default | awk '{print $5}' | head -1)
if [ -z "$MAIN_IFACE" ]; then
    fail "Не удалось определить сетевой интерфейс"
else
    ok "Интерфейс: ${MAIN_IFACE}"
fi

# ─── 2/8: Пакеты ─────────────────────────────────────────
echo "[2/8] Установка пакетов..."
export DEBIAN_FRONTEND=noninteractive

# Убить сторонние сервисы, которые могут занимать наши порты
echo "  Проверка конфликтующих сервисов..."
for relay_svc in $(systemctl list-unit-files --type=service | grep -oP 'relay-\S+\.service' || true); do
    echo "  Удаляю сторонний сервис: ${relay_svc}"
    systemctl stop "$relay_svc" 2>/dev/null || true
    systemctl disable "$relay_svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${relay_svc}" 2>/dev/null || true
done
# Убить любой socat, занимающий наши порты (8080, 8443, 51820)
for port in 8080 8443 51820; do
    PID=$(ss -tlnp | grep ":${port}" | grep -oP 'pid=\K[0-9]+' || true)
    if [ -n "$PID" ]; then
        PROC=$(ps -p "$PID" -o comm= 2>/dev/null || true)
        if [ "$PROC" != "xray" ] && [ "$PROC" != "wstunnel" ]; then
            echo "  Убиваю ${PROC} (pid ${PID}) на порту ${port}"
            kill "$PID" 2>/dev/null || true
        fi
    fi
done
systemctl daemon-reload 2>/dev/null || true

# Почистить возможные битые пакеты
dpkg --configure -a 2>/dev/null || true
apt-get install -f -y -qq 2>/dev/null || true

apt-get update -qq 2>/dev/null

# Заголовки ядра
apt-get install -y -qq "linux-headers-$(uname -r)" 2>/dev/null || true

# Базовые пакеты
apt-get install -y -qq curl gnupg software-properties-common jq \
    build-essential dkms unzip wget nftables sqlite3 unattended-upgrades 2>/dev/null \
    && ok "Пакеты установлены" \
    || fail "Некоторые пакеты не установились"

# ─── 3/8: sysctl ─────────────────────────────────────────
echo "[3/8] Настройка ядра..."
cat > /etc/sysctl.d/99-vpn.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
SYSCTL
sysctl --system > /dev/null 2>&1 \
    && ok "sysctl применён" \
    || fail "Ошибка sysctl"

# ─── 4/8: Amnezia WireGuard ──────────────────────────────
echo "[4/8] Установка Amnezia WireGuard..."

if command -v awg &>/dev/null; then
    skip "AmneziaWG"
elif command -v wg &>/dev/null; then
    skip "WireGuard (стандартный)"
else
    # Почистить мусор
    dpkg --remove --force-remove-reinstreq amneziawg amneziawg-dkms 2>/dev/null || true
    dpkg --configure -a 2>/dev/null || true
    apt-get install -f -y -qq 2>/dev/null || true

    # Попытка 1: AmneziaWG PPA
    add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1 || true
    apt-get update -qq 2>/dev/null
    if apt-get install -y amneziawg 2>/dev/null; then
        ok "AmneziaWG установлен из PPA"
    else
        # Почистить после неудачи
        dpkg --remove --force-remove-reinstreq amneziawg amneziawg-dkms 2>/dev/null || true
        dpkg --configure -a 2>/dev/null || true
        apt-get install -f -y -qq 2>/dev/null || true

        # Попытка 2: стандартный WireGuard
        echo "  AmneziaWG не удалось, ставлю стандартный WireGuard..."
        if apt-get install -y -qq wireguard wireguard-tools 2>/dev/null; then
            ok "WireGuard установлен (без обфускации Amnezia)"
        else
            fail "Не удалось установить ни AWG, ни WG"
        fi
    fi
fi

# Генерация ключей
if [ -f /etc/amnezia/amneziawg/server_private.key ]; then
    AWG_PRIVATE_KEY=$(cat /etc/amnezia/amneziawg/server_private.key)
    skip "Ключ AWG уже есть"
else
    if [ -z "${AWG_PRIVATE_KEY:-}" ]; then
        AWG_PRIVATE_KEY=$(awg genkey 2>/dev/null || wg genkey)
    fi
    mkdir -p /etc/amnezia/amneziawg
    echo "$AWG_PRIVATE_KEY" > /etc/amnezia/amneziawg/server_private.key
    chmod 600 /etc/amnezia/amneziawg/server_private.key
fi
AWG_PUBLIC_KEY=$(echo "$AWG_PRIVATE_KEY" | awg pubkey 2>/dev/null || echo "$AWG_PRIVATE_KEY" | wg pubkey)
echo "  AWG Public Key: ${AWG_PUBLIC_KEY}"

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

# Запуск AWG
systemctl enable awg-quick@awg0 2>/dev/null || systemctl enable wg-quick@awg0 2>/dev/null || true
systemctl restart awg-quick@awg0 2>/dev/null || systemctl restart wg-quick@awg0 2>/dev/null || true

# ─── 5/8: Xray ───────────────────────────────────────────
echo "[5/8] Установка Xray..."

if [ -f /usr/local/bin/xray ]; then
    skip "Xray"
else
    if curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh | bash -s install > /dev/null 2>&1; then
        ok "Xray установлен"
    else
        fail "Не удалось установить Xray"
    fi
fi

id xray &>/dev/null || useradd -r -s /usr/sbin/nologin xray
mkdir -p /etc/xray /var/log/xray
chown xray:xray /var/log/xray

# Xray использует /usr/local/etc/xray/ (стандартный путь установщика)
XRAY_CONF_DIR="/usr/local/etc/xray"
mkdir -p "$XRAY_CONF_DIR"

# Конфиг (не перезаписываем если уже есть клиенты)
if [ ! -f "${XRAY_CONF_DIR}/config.json" ] || ! jq -e '.inbounds[0].settings.clients | length > 0' "${XRAY_CONF_DIR}/config.json" &>/dev/null; then
    cat > "${XRAY_CONF_DIR}/config.json" <<'XRAYCONF'
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
fi
chmod 644 "${XRAY_CONF_DIR}/config.json"
# Симлинк для совместимости (бот ищет в /etc/xray/)
mkdir -p /etc/xray
ln -sf "${XRAY_CONF_DIR}/config.json" /etc/xray/config.json 2>/dev/null || \
    cp "${XRAY_CONF_DIR}/config.json" /etc/xray/config.json

# Удалить override от установщика Xray (он ломает наш unit)
rm -rf /etc/systemd/system/xray.service.d 2>/dev/null || true

# Systemd unit — запуск от root, конфиг из стандартного пути
cat > /etc/systemd/system/xray.service <<'XRAYSVC'
[Unit]
Description=Xray VLESS+WebSocket
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
XRAYSVC

systemctl daemon-reload
systemctl enable xray 2>/dev/null || true
systemctl restart xray 2>/dev/null || true

# ─── 6/8: wstunnel ───────────────────────────────────────
echo "[6/8] Установка wstunnel..."

if [ -f /usr/local/bin/wstunnel ]; then
    skip "wstunnel"
else
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then WS_ARCH="amd64"; else WS_ARCH="arm64"; fi

    # Получить последнюю версию автоматически
    WSTUNNEL_VER=$(curl -fsSL https://api.github.com/repos/erebe/wstunnel/releases/latest 2>/dev/null | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4 | tr -d 'v')
    if [ -z "$WSTUNNEL_VER" ]; then
        WSTUNNEL_VER="10.5.2"  # fallback
    fi
    echo "  Версия: ${WSTUNNEL_VER}, архитектура: ${WS_ARCH}"

    DL_URL="https://github.com/erebe/wstunnel/releases/download/v${WSTUNNEL_VER}/wstunnel_${WSTUNNEL_VER}_linux_${WS_ARCH}.tar.gz"
    echo "  URL: ${DL_URL}"

    if curl -fsSL "$DL_URL" -o /tmp/wstunnel.tar.gz; then
        tar -xzf /tmp/wstunnel.tar.gz -C /usr/local/bin/ 2>/dev/null
        chmod +x /usr/local/bin/wstunnel
        ok "wstunnel ${WSTUNNEL_VER} установлен"
    else
        fail "Не удалось скачать wstunnel"
    fi
fi

# Systemd unit
AWG_SVC=$(systemctl list-unit-files 2>/dev/null | grep -oP '(awg|wg)-quick@awg0\.service' | head -1 || echo "awg-quick@awg0.service")
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
systemctl enable wstunnel 2>/dev/null || true
systemctl restart wstunnel 2>/dev/null || true

# ─── 7/8: cloudflared ────────────────────────────────────
echo "[7/8] Установка cloudflared и настройка туннеля..."

if [ -f /usr/local/bin/cloudflared ]; then
    skip "cloudflared (бинарник)"
else
    CF_DL_ARCH=$(dpkg --print-architecture 2>/dev/null || echo "amd64")
    if curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_DL_ARCH}" \
        -o /usr/local/bin/cloudflared; then
        chmod +x /usr/local/bin/cloudflared
        ok "cloudflared установлен"
    else
        fail "Не удалось скачать cloudflared"
    fi
fi

# Credentials и конфиг (всегда перезаписываем — могут обновиться)
mkdir -p /etc/cloudflared
echo "${CF_CREDENTIALS_JSON}" > "/etc/cloudflared/${CF_TUNNEL_ID}.json"
chmod 600 "/etc/cloudflared/${CF_TUNNEL_ID}.json"

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

cat > /etc/systemd/system/cloudflared.service <<'CFSVC'
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
systemctl enable cloudflared 2>/dev/null || true
systemctl restart cloudflared 2>/dev/null || true

# ─── 8/8: Firewall ───────────────────────────────────────
echo "[8/8] Настройка firewall..."

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

if nft -c -f /etc/nftables.conf 2>/dev/null; then
    systemctl enable nftables 2>/dev/null || true
    systemctl restart nftables 2>/dev/null || true
    ok "Firewall настроен"
else
    fail "Ошибка валидации nftables"
fi

# ─── Итого ────────────────────────────────────────────────
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

for svc in cloudflared wstunnel xray; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        echo "  ✅ ${svc} — работает"
    else
        echo "  ❌ ${svc} — НЕ работает"
    fi
done

if systemctl is-active --quiet awg-quick@awg0 2>/dev/null || systemctl is-active --quiet wg-quick@awg0 2>/dev/null; then
    echo "  ✅ awg0 — работает"
else
    echo "  ❌ awg0 — НЕ работает"
fi

echo ""
if [ "$ERRORS" -gt 0 ]; then
    echo "  ⚠️ Завершено с ${ERRORS} ошибками. Можно запустить повторно."
    exit 1
else
    echo "  ✅ Всё установлено без ошибок!"
    exit 0
fi
