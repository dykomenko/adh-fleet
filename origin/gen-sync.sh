#!/usr/bin/env bash
#
# Собирает sync.yaml по составу группы agh-replica в оверлее.
# Живёт на origin в /opt/agh-sync/gen-sync.sh, запускается кроном раз в час.
# Это то, из-за чего добавление ноды не требует правок на origin.
#
# Синхронизатор перезапускается только если состав реально изменился.
# Нужен немедленный прогон — /opt/agh-sync/sync-now.sh

set -euo pipefail

DIR=/opt/agh-sync
OUT="$DIR/sync.yaml"
PASS_FILE="$DIR/admin.pass"
GROUP=agh-replica

[[ -f "$PASS_FILE" ]] || { echo "нет $PASS_FILE" >&2; exit 1; }
PASS="$(cat "$PASS_FILE")"

umask 077
{
  # Раз в час: правила меняются редко, гонять чаще смысла нет.
  printf 'cron: "17 * * * *"\n'
  printf 'runOnStart: true\n'
  printf 'continueOnError: true\n\n'
  printf 'origin:\n'
  printf '  url: http://127.0.0.1:3000\n'
  printf '  username: admin\n'
  printf '  password: %s\n\n' "$PASS"
  printf 'replicas:\n'

  # Адреса, а не имена: у netbird отключено управление DNS (иначе его
  # резолвер занимает порт 53, нужный AdGuard Home), поэтому имена вида
  # node07.netbird.cloud на нодах не разрешаются.
  #
  # Офлайн-ноды намеренно не отфильтровываются: continueOnError позволит
  # пропустить недоступную и обновить остальные, а вернувшаяся догонится сама.
  #
  # Структура вывода netbird status --json менялась между версиями —
  # сверьте фактические имена полей перед первым запуском.
  netbird status --json \
    | jq -r --arg g "$GROUP" '
        .peers.details[]?
        | select(.groups[]? == $g)
        | (.netbirdIp // .ip // empty)
        | split("/")[0]
      ' \
    | sort -u \
    | while read -r addr; do
        [[ -n "$addr" ]] || continue
        printf '  - url: http://%s:3000\n' "$addr"
        printf '    username: admin\n'
        printf '    password: %s\n' "$PASS"
      done

  printf '\nfeatures:\n'
  printf '  dhcp:\n'
  printf '    serverConfig: false\n'
  printf '    staticLeases: false\n'
} > "$OUT.new"
umask 022

# Пустой список реплик — почти наверняка сбой опроса оверлея, а не факт.
# Затирать рабочий конфиг таким не нужно.
if ! grep -q '^  - url:' "$OUT.new"; then
  echo "список реплик пуст, файл не заменён — проверьте netbird status --json" >&2
  rm -f "$OUT.new"
  exit 1
fi

if cmp -s "$OUT.new" "$OUT" 2>/dev/null; then
  rm -f "$OUT.new"
  exit 0
fi

mv "$OUT.new" "$OUT"
docker restart agh-sync >/dev/null
echo "состав реплик изменился: $(grep -c '^  - url:' "$OUT") шт., синхронизатор перезапущен"
