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
# Ненулевой код здесь означает, что список собрать не удалось: идти дальше
# бессмысленно, синхронизировать не с чем.
"$DIR/gen-sync.sh" || {
  echo "список реплик не собран, синхронизация не запущена" >&2
  exit 1
}

echo "запускаю синхронизацию..."

# Контейнера может ещё не быть: setup-origin.sh не поднимает его, пока
# нет ни одной реплики. Тогда поднимаем, а не пытаемся перезапустить.
if docker inspect agh-sync >/dev/null 2>&1; then
  docker restart agh-sync >/dev/null
else
  docker compose -f "$DIR/docker-compose.yml" up -d
fi

# runOnStart: true в sync.yaml => прогон стартует сразу после запуска
sleep 5
docker logs --tail 30 agh-sync

echo
echo "реплик в конфиге: $(grep -c '^  - url:' "$DIR/sync.yaml")"
