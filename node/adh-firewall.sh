#!/usr/bin/env bash
#
# Ограничивает доступ к портам AdGuard Home. Ставится в /usr/local/sbin/
# и запускается юнитом adh-firewall.service при загрузке.
#
# Настройка — /etc/adh-firewall.conf:
#   CLIENT_NET=10.107.0.0/24
#
# Политика INPUT по умолчанию НЕ трогается: на нодах уже стоит VPN
# со своими правилами, и менять её означало бы рисковать чужой настройкой.
# Вместо этого — отдельная цепочка ровно для двух портов. Прочие порты,
# включая SSH, не затрагиваются вообще, так что отрезать себе доступ нельзя.
#
# Скрипт идемпотентен: цепочка очищается и собирается заново.

set -uo pipefail

CHAIN=ADH-INPUT
CONF=/etc/adh-firewall.conf

[[ -f "$CONF" ]] || { echo "нет $CONF" >&2; exit 1; }
# shellcheck source=/dev/null
. "$CONF"
: "${CLIENT_NET:?в $CONF не задан CLIENT_NET}"

OVERLAY_NET=${OVERLAY_NET:-100.64.0.0/10}

apply() {
  local ipt="$1"; shift
  local localhost_net="$1"; shift
  local client_rules="$1"; shift

  command -v "$ipt" >/dev/null || return 0

  # Цепочка и ссылка на неё из INPUT первым правилом
  "$ipt" -N "$CHAIN" 2>/dev/null || "$ipt" -F "$CHAIN"
  "$ipt" -C INPUT -j "$CHAIN" 2>/dev/null || "$ipt" -I INPUT 1 -j "$CHAIN"

  # Сам хост всегда может спросить свой резолвер
  "$ipt" -A "$CHAIN" -p udp --dport 53 -s "$localhost_net" -j ACCEPT
  "$ipt" -A "$CHAIN" -p tcp --dport 53 -s "$localhost_net" -j ACCEPT

  if [[ "$client_rules" == yes ]]; then
    # DNS — только клиентам этой ноды
    "$ipt" -A "$CHAIN" -p udp --dport 53 -s "$CLIENT_NET" -j ACCEPT
    "$ipt" -A "$CHAIN" -p tcp --dport 53 -s "$CLIENT_NET" -j ACCEPT
    # Панель — только из оверлея, там ходит синхронизатор
    "$ipt" -A "$CHAIN" -p tcp --dport 3000 -s "$OVERLAY_NET" -j ACCEPT
  fi

  # Всё остальное на этих портах — молча отбрасываем
  "$ipt" -A "$CHAIN" -p udp --dport 53   -j DROP
  "$ipt" -A "$CHAIN" -p tcp --dport 53   -j DROP
  "$ipt" -A "$CHAIN" -p tcp --dport 3000 -j DROP
}

apply iptables  127.0.0.0/8 yes
# По IPv6 клиенты не ходят — сети туннелей у нас IPv4. Оставляем только
# локальный доступ, остальное закрываем: иначе нода окажется открытым
# резолвером по IPv6, что легко упустить.
apply ip6tables ::1/128     no

echo "firewall: 53 открыт для $CLIENT_NET, 3000 — для $OVERLAY_NET"
