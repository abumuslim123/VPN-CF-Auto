#!/bin/bash
# Отправка уведомлений в Telegram
#
# Использование:
#   notify-telegram.sh --type alert --message "Нода 1 недоступна"
#   notify-telegram.sh --type config --message "Новый конфиг" --file /data/clients/ivan/vless-qr.png
#   notify-telegram.sh --type info --message "Домен обновлён"

source "$(dirname "$0")/common.sh"

MSG_TYPE=""
MESSAGE=""
FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --type)    MSG_TYPE="$2"; shift 2 ;;
        --message) MESSAGE="$2"; shift 2 ;;
        --file)    FILE="$2"; shift 2 ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
    esac
done

if [ -z "$MESSAGE" ]; then
    echo "ОШИБКА: Укажите --message" >&2
    exit 1
fi

if [ -z "${TG_BOT_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then
    echo "ВНИМАНИЕ: TG_BOT_TOKEN или TG_CHAT_ID не заданы, пропускаю отправку" >&2
    echo "Сообщение: ${MESSAGE}"
    exit 0
fi

# Добавить иконку по типу
case $MSG_TYPE in
    alert)  MESSAGE="🚨 ${MESSAGE}" ;;
    config) MESSAGE="📋 ${MESSAGE}" ;;
    info)   MESSAGE="ℹ️ ${MESSAGE}" ;;
esac

# Отправить сообщение
tg_notify "$MESSAGE"
echo "Telegram: сообщение отправлено"

# Отправить файл, если указан
if [ -n "$FILE" ] && [ -f "$FILE" ]; then
    # Определить тип файла для правильной отправки
    if [[ "$FILE" =~ \.(png|jpg|jpeg)$ ]]; then
        tg_send_photo "$FILE" "$MESSAGE"
    else
        tg_send_file "$FILE" "$MESSAGE"
    fi
    echo "Telegram: файл отправлен (${FILE})"
fi
