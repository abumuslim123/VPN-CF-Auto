#!/bin/bash
# Цикл мониторинга — запускается в Docker-контейнере healthcheck
#
# Выполняет healthcheck.sh каждые HEALTHCHECK_INTERVAL секунд

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${HEALTHCHECK_INTERVAL:-300}"

echo "Запуск мониторинга (интервал: ${INTERVAL}с)"

while true; do
    "${SCRIPT_DIR}/healthcheck.sh" 2>&1 || true
    sleep "$INTERVAL"
done
