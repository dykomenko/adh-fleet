#!/usr/bin/env bash
#
# Снимает шаблон конфига с настроенной origin-ноды. Запускается НА ORIGIN.
#
#   VPN_GW=10.101.0.1 ./make-template.sh
#
# Результат — node/AdGuardHome.yaml.tmpl, который коммитится в репозиторий.
# Секретов в нём нет: адреса и bcrypt-хеш пароля заменены плейсхолдерами,
# а подставляются они уже на ноде во время установки.
#
# Переснимать нужно только если поменялись bind-адреса или пароль админа.
# Фильтры и правила в шаблоне не важны — они приезжают синхронизацией.

set -euo pipefail

CONF=/opt/adguardhome/conf/AdGuardHome.yaml
OUT="${1:-/tmp/AdGuardHome.yaml.tmpl}"

[[ -f "$CONF" ]] || { echo "нет $CONF — origin ещё не настроен" >&2; exit 1; }
command -v jq >/dev/null || { echo "нужен jq" >&2; exit 1; }

NB_IP="$(netbird status --json | jq -r '.netbirdIp // empty' | cut -d/ -f1)"
[[ -n "$NB_IP" ]] || { echo "не удалось определить адрес ноды в оверлее" >&2; exit 1; }

# bcrypt-хеш из секции users — он же понадобится как AGH_PASS_HASH при установке
HASH="$(grep -oE '\$2[aby]\$[0-9]{2}\$[A-Za-z0-9./]{53}' "$CONF" | head -1)"
[[ -n "$HASH" ]] || { echo "не нашёл bcrypt-хеш пароля в $CONF" >&2; exit 1; }

sed -e "s|${NB_IP}|__NB_IP__|g" \
    -e "s|${HASH//\//\\/}|__PASS_HASH__|g" \
    "$CONF" > "$OUT"

for ph in __NB_IP__ __PASS_HASH__; do
  grep -q "$ph" "$OUT" || { echo "плейсхолдер $ph не подставился" >&2; exit 1; }
done

# DNS должен слушать все интерфейсы: VPN-интерфейс появляется и исчезает
# при рестартах, привязка к его адресу ломает старт AGH после перезагрузки.
if ! grep -qE '^\s+- 0\.0\.0\.0\s*$' "$OUT"; then
  echo "ВНИМАНИЕ: в bind_hosts не видно 0.0.0.0." >&2
  echo "В мастере AGH для DNS-сервера должно быть выбрано «Все интерфейсы»," >&2
  echo "иначе реплики не примут этот шаблон — у них своя адресация." >&2
fi

# Страховка: убедиться, что в шаблон не утёк ни один bcrypt-хеш
if grep -qE '\$2[aby]\$[0-9]{2}\$' "$OUT"; then
  echo "в шаблоне остался bcrypt-хеш — публиковать нельзя" >&2
  exit 1
fi

echo "шаблон готов: $OUT"
echo "секретов не содержит, коммитьте в node/AdGuardHome.yaml.tmpl"
echo
echo "хеш пароля для установки нод (AGH_PASS_HASH):"
echo "$HASH"
