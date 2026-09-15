#!/usr/bin/env bash
#
# Добавляет ноду в парк. Запускается НА РАБОЧЕЙ МАШИНЕ.
#
#   ./scripts/add-node.sh <ssh-хост> <номер ноды>
#   ./scripts/add-node.sh node07 7
#
# Адрес шлюза VPN выводится из номера: 10.(100+N).0.1
# Ключ берётся из .env и уходит на ноду только через ssh — на диске не остаётся.

set -euo pipefail

HOST="${1:?ssh-хост новой ноды}"
NUM="${2:?номер ноды, например 7}"

[[ "$NUM" =~ ^[0-9]+$ ]] || { echo "номер ноды должен быть числом" >&2; exit 1; }
(( NUM >= 1 && NUM <= 154 )) || { echo "номер вне диапазона 1..154" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT/.env" ]]; then
  set -a; . "$ROOT/.env"; set +a
fi
: "${NB_KEY:?NB_KEY не задан — заполните .env по образцу .env.example}"

TMPL="$ROOT/node/AdGuardHome.yaml.tmpl"
[[ -f "$TMPL" ]] || {
  echo "нет $TMPL" >&2
  echo "сначала снимите шаблон с origin: scripts/make-template.sh" >&2
  exit 1
}

VPN_GW="10.$((100 + NUM)).0.1"
echo "нода $HOST -> шлюз $VPN_GW"

ssh "$HOST" 'install -d /opt/adguardhome'
scp -q "$TMPL" "$ROOT/node/docker-compose.yml" "$HOST:/opt/adguardhome/"

# Скрипт передаётся по stdin, ключ — через окружение сессии.
ssh "$HOST" "NB_KEY='$NB_KEY' bash -s -- '$VPN_GW'" < "$ROOT/scripts/bootstrap-agh.sh"

echo
echo "готово. Проверка через минуту:"
echo "  ssh $HOST 'dig @$VPN_GW doubleclick.net +short'"
