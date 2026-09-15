#!/usr/bin/env bash
#
# Обновляет AdGuard Home на всём парке в одном окне времени.
# Запускается НА ORIGIN (там есть netbird status со списком нод).
#
#   ./fleet-update.sh          — обновить всё
#   ./fleet-update.sh --list   — только показать состав парка
#
# Версии не должны разъезжаться дольше пары минут: пока они разные,
# синхронизатор может спотыкаться на расхождении API.

set -euo pipefail

PARALLEL=8

hosts() {
  netbird status --json \
    | jq -r '.peers.details[]? | select(.groups[]? | test("^agh-")) | .fqdn' \
    | sort -u
}

if [[ "${1:-}" == "--list" ]]; then
  hosts
  exit 0
fi

echo "точка отката (текущий образ на этой ноде):"
docker inspect --format '{{index .RepoDigests 0}}' adguardhome 2>/dev/null \
  || echo "  не удалось определить"
echo

hosts | xargs -P "$PARALLEL" -I{} -r sh -c \
  'echo "-- {}"; ssh -o BatchMode=yes {} "cd /opt/adguardhome && docker compose pull -q && docker compose up -d" || echo "!! {} не обновилась"'

echo
echo "готово. Проверьте выборочно: docker compose -f /opt/adguardhome/docker-compose.yml images"
