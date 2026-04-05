# Скрипт подключения к VPN: wstunnel + Amnezia WireGuard (Windows)
# Клиент: {{CLIENT_NAME}}
#
# Зависимости:
#   - wstunnel.exe (https://github.com/erebe/wstunnel/releases)
#   - AmneziaWG или WireGuard (wireguard.exe)
#
# Запуск: .\connect.ps1 (от имени администратора)

$ErrorActionPreference = "Stop"

# --- Конфигурация ---
$WS_HOST = "{{WS_HOST}}"
$LOCAL_WG_PORT = {{LOCAL_WG_PORT}}
$AWG_CONF = Join-Path $PSScriptRoot "awg-client.conf"

$wstunnelProc = $null

# --- Проверка прав администратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ОШИБКА: Запустите от имени администратора" -ForegroundColor Red
    exit 1
}

# --- Проверка зависимостей ---
foreach ($cmd in @("wstunnel", "wireguard")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Host "ОШИБКА: $cmd не найден. Установите перед запуском." -ForegroundColor Red
        exit 1
    }
}

if (-not (Test-Path $AWG_CONF)) {
    Write-Host "ОШИБКА: Конфиг AWG не найден: $AWG_CONF" -ForegroundColor Red
    exit 1
}

# --- Очистка ---
function Cleanup {
    Write-Host "`n[*] Отключение..."
    try {
        & wireguard.exe /uninstalltunnelservice awg-client 2>$null
    } catch {}
    if ($wstunnelProc -and -not $wstunnelProc.HasExited) {
        $wstunnelProc.Kill()
    }
    Write-Host "[*] Отключено."
}

try {
    # Запуск wstunnel
    Write-Host "[*] Подключение к ${WS_HOST}..."
    $wstunnelProc = Start-Process -FilePath "wstunnel.exe" -ArgumentList @(
        "client",
        "-L", "udp://127.0.0.1:${LOCAL_WG_PORT}:127.0.0.1:${LOCAL_WG_PORT}?timeout_sec=0",
        "wss://${WS_HOST}:443"
    ) -PassThru -NoNewWindow

    Start-Sleep -Seconds 2

    if ($wstunnelProc.HasExited) {
        throw "wstunnel не запустился"
    }

    Write-Host "[+] WebSocket-туннель установлен"

    # Запуск WireGuard
    Write-Host "[*] Запуск Amnezia WireGuard..."
    & wireguard.exe /installtunnelservice $AWG_CONF

    Write-Host ""
    Write-Host "[+] VPN подключён! Нажмите Ctrl+C для отключения." -ForegroundColor Green
    Write-Host ""

    # Ожидание
    $wstunnelProc.WaitForExit()
}
finally {
    Cleanup
}
