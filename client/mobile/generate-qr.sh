#!/bin/bash
# Генерация QR-кода из VLESS URI
#
# Использование:
#   ./generate-qr.sh "vless://uuid@host:443?..."
#   ./generate-qr.sh ./vless-uri.txt
#   ./generate-qr.sh ./vless-uri.txt output.png

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Использование: $0 <vless-uri|файл> [output.png]"
    echo ""
    echo "Примеры:"
    echo "  $0 'vless://uuid@host:443?...'       # Из аргумента"
    echo "  $0 ./vless-uri.txt                    # Из файла"
    echo "  $0 ./vless-uri.txt my-vpn.png         # С указанием выходного файла"
    exit 1
fi

# Проверка qrencode
if ! command -v qrencode &>/dev/null; then
    echo "ОШИБКА: qrencode не найден" >&2
    echo "Установите: sudo apt install qrencode (Linux) / brew install qrencode (macOS)" >&2
    exit 1
fi

INPUT="$1"
OUTPUT="${2:-vless-qr.png}"

# Определить источник URI
if [ -f "$INPUT" ]; then
    URI=$(cat "$INPUT" | tr -d '[:space:]')
else
    URI="$INPUT"
fi

# Валидация
if [[ ! "$URI" =~ ^vless:// ]]; then
    echo "ОШИБКА: Невалидный VLESS URI (должен начинаться с vless://)" >&2
    exit 1
fi

# QR в терминал
echo "=== QR-код (отсканируйте в приложении) ==="
echo ""
qrencode -t UTF8 "$URI"
echo ""

# QR в файл
qrencode -t PNG -s 6 -o "$OUTPUT" "$URI"
echo "QR-код сохранён: ${OUTPUT}"
echo ""
echo "VLESS URI: ${URI}"
