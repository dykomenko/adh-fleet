#!/usr/bin/env bash
#
# Обновляет AdGuard Home на нодах. Запускается С РАБОЧЕЙ МАШИНЫ.
#
#   ./scripts/fleet-update.sh node02 node03 node07
#   ./scripts/fleet-update.sh              # хосты из NODES в .env
#
# Намеренно НЕ запускается на origin: держать там ssh-доступ ко всему парку
# означает, что компрометация одной ноды открывает остальные. Рабочая машина
# и так имеет доступ ко всем нодам — пусть управление остаётся на ней.

set -euo pipefail

PARALLEL="${PARALLEL:-8}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -gt 0 ]]; then
  HOSTS=("$@")
else
  # .env живёт рядом с репозиторием, а не внутри него — так секреты
  # физически не могут попасть в публичный git.
  for env in "$ROOT/../.env" "$ROOT/.env"; do
    [[ -f "$env" ]] && { set -a; . "$env"; set +a; break; }
  done
  : "${NODES:?передайте хосты аргументами или задайте NODES в .env}"
  read -r -a HOSTS <<< "$NODES"
fi

echo "обновляю ${#HOSTS[@]} нод, параллельно по $PARALLEL"
echo

printf '%s\n' "${HOSTS[@]}" \
  | xargs -P "$PARALLEL" -I{} -r sh -c '
      out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 {} \
        "cd /opt/adguardhome && docker compose pull -q && docker compose up -d" 2>&1) \
        && echo "ok  {}" \
        || { echo "ОШИБКА {}"; echo "$out" | sed "s/^/      /"; }
    '

echo
echo "точка отката — digest образа до обновления фиксируется так:"
echo "  ssh <нода> \"docker inspect --format '{{index .RepoDigests 0}}' adguardhome\""
