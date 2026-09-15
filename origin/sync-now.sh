#!/usr/bin/env bash
#
# Немедленный прогон синхронизации. Запускается НА ORIGIN, руками.
#
#   /opt/agh-sync/sync-now.sh
#
# Обычный график — раз в час. Этот скрипт нужен, когда ждать не хочется:
# поменяли правила на origin или только что подняли новую ноду.

set -euo pipefail

DIR=/opt/agh-sync

# Сначала пересобрать список реплик — вдруг появилась новая нода.
# Выход 0 без изменений тоже нормален.
"$DIR/gen-sync.sh" || true

echo "запускаю синхронизацию..."
docker restart agh-sync >/dev/null

# runOnStart: true в sync.yaml => прогон стартует сразу после перезапуска
sleep 5
docker logs --tail 30 agh-sync

echo
echo "реплик в конфиге: $(grep -c '^  - url:' "$DIR/sync.yaml")"
