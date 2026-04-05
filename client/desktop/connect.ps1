# Скрипт подключения к VPN (Windows PowerShell)
# wstunnel + Amnezia WireGuard / WireGuard
#
# Перед использованием:
#   1. Установите wstunnel: https://github.com/erebe/wstunnel/releases
#   2. Установите AmneziaWG или WireGuard
#   3. Положите awg-client.conf рядом с этим скриптом
#
# Запуск (от имени администратора):
#   .\connect.ps1
#   .\connect.ps1 -Host "vpn2.example.com"

param(
    [string]$WsHost = "vpn1.example.com",
    [string]$WsHostBackup = "",
    [int]$LocalPort = 51820,
    [string]$AwgConf = ""
)

$ErrorActionPreference = "Stop"

# --- Определить путь к конфигу ---
if (-not $AwgConf) {
    $AwgConf = Join-Path $PSScriptRoot "awg-client.conf"
}

# --- Проверка прав администратора ---
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "ОШИБКА: Запустите от имени администратора" -ForegroundColor Red
    Write-Host "  Правый клик -> Запустить от имени администратора" -ForegroundColor Yellow
    exit 1
}

# --- Проверка зависимостей ---
$wstunnelPath = Get-Command "wstunnel" -ErrorAction SilentlyContinue
if (-not $wstunnelPath) {
    $wstunnelPath = Get-Command "wstunnel.exe" -ErrorAction SilentlyContinue
}
if (-not $wstunnelPath) {
    Write-Host "ОШИБКА: wstunnel не найден. Скачайте с https://github.com/erebe/wstunnel/releases" -ForegroundColor Red
    exit 1
}

# WireGuard CLI
$wgPath = Get-Command "wireguard" -ErrorAction SilentlyContinue
if (-not $wgPath) {
    $wgPath = Get-Command "wireguard.exe" -ErrorAction SilentlyContinue
}
if (-not $wgPath) {
    Write-Host "ОШИБКА: wireguard не найден. Установите AmneziaWG или WireGuard" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $AwgConf)) {
    Write-Host "ОШИБКА: Конфиг не найден: $AwgConf" -ForegroundColor Red
    exit 1
}

# --- Переменные ---
$wstunnelProc = $null
$tunnelName = "awg-client"

# --- Очистка ---
function Cleanup {
    Write-Host "`n[*] Отключение..."
    try { & wireguard.exe /uninstalltunnelservice $tunnelName 2>$null } catch {}
    if ($wstunnelProc -and -not $wstunnelProc.HasExited) {
        try { $wstunnelProc.Kill() } catch {}
    }
    Write-Host "[*] Отключено."
}

# --- Попытка подключения ---
function TryConnect($Host) {
    Write-Host "[*] Подключение к ${Host}..."

    $proc = Start-Process -FilePath "wstunnel.exe" -ArgumentList @(
        "client",
        "-L", "udp://127.0.0.1:${LocalPort}:127.0.0.1:${LocalPort}?timeout_sec=0",
        "wss://${Host}:443"
    ) -PassThru -NoNewWindow

    Start-Sleep -Seconds 2

    if ($proc.HasExited) {
        Write-Host "[!] Не удалось подключиться к ${Host}" -ForegroundColor Yellow
        return $null
    }

    Write-Host "[+] WebSocket-туннель установлен через ${Host}" -ForegroundColor Green
    return $proc
}

# --- Основной блок ---
try {
    # Попробовать основной хост
    $wstunnelProc = TryConnect $WsHost

    if (-not $wstunnelProc -and $WsHostBackup) {
        Write-Host "[*] Пробую резервную ноду..."
        $wstunnelProc = TryConnect $WsHostBackup
    }

    if (-not $wstunnelProc) {
        Write-Host "ОШИБКА: Не удалось подключиться" -ForegroundColor Red
        exit 1
    }

    # Запуск WireGuard
    Write-Host "[*] Запуск Amnezia WireGuard..."
    & wireguard.exe /installtunnelservice $AwgConf

    Write-Host ""
    Write-Host "[+] VPN подключён! Нажмите Ctrl+C для отключения." -ForegroundColor Green
    Write-Host ""

    # Ожидание
    $wstunnelProc.WaitForExit()
}
finally {
    Cleanup
}
