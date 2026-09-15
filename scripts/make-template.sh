#!/usr/bin/env bash
#
# Снимает шаблон конфига с настроенной origin-ноды. Запускается НА ORIGIN.
#
#   VPN_GW=10.101.0.1 ./make-template.sh [выходной файл]
#
# Шаблон — это то, что превращает установку реплики в одну команду:
# если AdGuardHome.yaml лежит на месте до первого старта,
# AGH не показывает мастер установки вовсе.
#
# ВНИМАНИЕ: результат содержит bcrypt-хеш пароля админа. Не публиковать,
# в git не коммитить (он уже в .gitignore).

set -euo pipefail

CONF=/opt/adguardhome/conf/AdGuardHome.yaml
OUT="${1:-/opt/adguardhome/AdGuardHome.yaml.tmpl}"
: "${VPN_GW:?экспортируйте VPN_GW — адрес шлюза VPN на origin, например 10.101.0.1}"

[[ -f "$CONF" ]] || { echo "нет $CONF — origin ещё не настроен" >&2; exit 1; }
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 1; }

NB_IP="$(netbird status --json | jq -r '.netbirdIp // empty' | cut -d/ -f1)"
[[ -n "$NB_IP" ]] || { echo "не удалось определить адрес ноды в оверлее" >&2; exit 1; }

sed -e "s|${VPN_GW}|__VPN_GW__|g" -e "s|${NB_IP}|__NB_IP__|g" "$CONF" > "$OUT"

grep -q '__VPN_GW__' "$OUT" || { echo "плейсхолдер __VPN_GW__ не подставился — проверьте VPN_GW" >&2; exit 1; }
grep -q '__NB_IP__'  "$OUT" || { echo "плейсхолдер __NB_IP__ не подставился" >&2; exit 1; }

echo "шаблон готов: $OUT"
echo "заберите его на рабочую машину в node/AdGuardHome.yaml.tmpl"
echo "он содержит хеш пароля админа — храните как секрет"
