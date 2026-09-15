#!/usr/bin/env bash
#
# Разворачивает синхронизатор на origin-ноде. Запускается НА ORIGIN, от root.
# AdGuard Home к этому моменту уже должен быть настроен вручную.
#
#   AGH_PASS='<пароль админа>' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/origin/setup-origin.sh)
#
# Ставит adguardhome-sync, генератор списка реплик и крон. Идемпотентен.

set -euo pipefail

REPO="${REPO:-https://raw.githubusercontent.com/dykomenko/adh-fleet/main}"
DIR=/opt/agh-sync

: "${AGH_PASS:?не задан AGH_PASS — пароль админа AdGuard Home}"
[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker не установлен" >&2; exit 1; }
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq curl; }
command -v netbird >/dev/null || { echo "netbird не установлен — origin должен быть в оверлее" >&2; exit 1; }

install -d -m 755 "$DIR"

# Пароль — единственный секрет на origin, лежит только здесь
umask 077
printf '%s' "$AGH_PASS" > "$DIR/admin.pass"
umask 022
chmod 600 "$DIR/admin.pass"

curl -fsSL "$REPO/origin/docker-compose.yml" -o "$DIR/docker-compose.yml"
curl -fsSL "$REPO/origin/gen-sync.sh"        -o "$DIR/gen-sync.sh"
curl -fsSL "$REPO/origin/sync-now.sh"        -o "$DIR/sync-now.sh"
chmod 700 "$DIR/gen-sync.sh" "$DIR/sync-now.sh"

echo "собираю список реплик..."
"$DIR/gen-sync.sh" || {
  echo
  echo "список реплик пуст — это нормально, если реплик ещё нет." >&2
  echo "поднимите первую ноду и запустите $DIR/sync-now.sh" >&2
  exit 0
}

docker compose -f "$DIR/docker-compose.yml" up -d

# Крон раз в час: новая нода подхватится в течение часа,
# либо сразу через sync-now.sh
cat > /etc/cron.d/agh-sync-gen <<'CRON'
# Пересборка списка реплик по составу группы agh-replica в оверлее
5 * * * * root /opt/agh-sync/gen-sync.sh
CRON
chmod 644 /etc/cron.d/agh-sync-gen

echo
echo "origin готов"
echo "  реплик в конфиге: $(grep -c '^  - url:' "$DIR/sync.yaml")"
echo "  ручной прогон:    $DIR/sync-now.sh"
echo "  логи:             docker logs agh-sync"
