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

# CLIENT_NET необязателен. У Xray и подобных прокси клиенты не получают
# адресов в туннельной подсети: DNS запрашивает сам прокси с этой же машины,
# и localhost'а достаточно. Правило для сети клиентов нужно только там,
# где туннель раздаёт адреса — WireGuard, OpenVPN.
CLIENT_NET="${CLIENT_NET:-}"

# Сети docker, из которых разрешён 53-й порт. Можно перечислить несколько
# через пробел: install.sh добавляет сюда обнаруженные мосты, если docker
# настроен на нестандартный пул адресов. Пусто — контейнеры к AGH не достучатся.
DOCKER_NET="${DOCKER_NET:-172.16.0.0/12}"

# Панель разрешаем по ИНТЕРФЕЙСУ оверлея, а не по диапазону адресов.
#
# Netbird раздаёт адреса шире, чем 100.64.0.0/10: в одном парке встречаются
# и 100.72.x.x, и 100.28.x.x. Правило по сети отбросило бы половину нод,
# причём выглядело бы это как «реплика не отвечает», а не как отказ firewall.
# Совпадение по интерфейсу от пула адресов не зависит вовсе.
#
# Несуществующий на момент применения интерфейс iptables принимает спокойно —
# правило просто не будет срабатывать, пока netbird не поднимет wt0.
OVERLAY_IF=${OVERLAY_IF:-wt0}

apply() {
  local ipt="$1"; shift
  local localhost_net="$1"; shift
  local client_rules="$1"; shift

  command -v "$ipt" >/dev/null || return 0

  # Цепочка и ссылка на неё из INPUT первым правилом
  "$ipt" -N "$CHAIN" 2>/dev/null || "$ipt" -F "$CHAIN"
  "$ipt" -C INPUT -j "$CHAIN" 2>/dev/null || "$ipt" -I INPUT 1 -j "$CHAIN"

  # Localhost — всегда и на оба порта.
  #
  # Порт 53: сам хост должен уметь спросить свой резолвер.
  #
  # Порт 3000 не менее обязателен, хотя выглядит лишним:
  #   - синхронизатор на origin ходит к своему AGH как http://127.0.0.1:3000,
  #     и в host-сети контейнера это именно localhost;
  #   - доступ к панели документирован через ssh -L, а проброшенный канал
  #     приходит с 127.0.0.1.
  # Без этого правила и то и другое молча упирается в DROP ниже.
  "$ipt" -A "$CHAIN" -p udp --dport 53   -s "$localhost_net" -j ACCEPT
  "$ipt" -A "$CHAIN" -p tcp --dport 53   -s "$localhost_net" -j ACCEPT
  "$ipt" -A "$CHAIN" -p tcp --dport 3000 -s "$localhost_net" -j ACCEPT

  # То же самое, но по ИНТЕРФЕЙСУ, и без этого схема ломается на части нод.
  #
  # Запрос с самой ноды на адрес docker-моста уходит через lo, но адрес
  # источника ядро выбирает по маршруту. Если к мосту не подключён ни один
  # контейнер — а так и будет там, где всё поднято с network_mode: host, —
  # docker0 остаётся в состоянии NO-CARRIER, и источником становится
  # ПУБЛИЧНЫЙ адрес ноды. Правило по 127.0.0.0/8 такой пакет не ловит,
  # пакет доходит до DROP, и нода тихо резолвит через запасной сервер:
  # фильтрации нет, а выглядит всё исправным.
  #
  # Совпадение по lo от выбора адреса не зависит вовсе. Это безопасно:
  # извне на lo пакет не приходит, ядро отбрасывает такие как martian.
  "$ipt" -A "$CHAIN" -p udp --dport 53   -i lo -j ACCEPT
  "$ipt" -A "$CHAIN" -p tcp --dport 53   -i lo -j ACCEPT
  "$ipt" -A "$CHAIN" -p tcp --dport 3000 -i lo -j ACCEPT

  # Docker-сети. Контейнеры обращаются к AGH по адресу моста (172.17.0.1),
  # потому что Docker выбрасывает loopback при наследовании resolv.conf хоста,
  # а адрес моста пропускает. Так резолвер достаётся контейнерам сам,
  # и compose-файлы трогать не нужно — это важно, потому что override
  # у remnanode принадлежит стороннему инструменту и перезаписывается им.
  if [[ "$ipt" == iptables ]]; then
    local net
    for net in $DOCKER_NET; do
      "$ipt" -A "$CHAIN" -p udp --dport 53 -s "$net" -j ACCEPT
      "$ipt" -A "$CHAIN" -p tcp --dport 53 -s "$net" -j ACCEPT
    done
  fi

  if [[ "$client_rules" == yes && -n "$CLIENT_NET" ]]; then
    # DNS — только клиентам этой ноды
    "$ipt" -A "$CHAIN" -p udp --dport 53 -s "$CLIENT_NET" -j ACCEPT
    "$ipt" -A "$CHAIN" -p tcp --dport 53 -s "$CLIENT_NET" -j ACCEPT
  fi

  # Панель — только с интерфейса оверлея, там ходит синхронизатор
  "$ipt" -A "$CHAIN" -p tcp --dport 3000 -i "$OVERLAY_IF" -j ACCEPT

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

# Netbird 0.79 перехватывает DNS на уровне пакетов: ставит в своей таблице
# nftables правило dnat с 127.0.0.1:53 на свой резолвер (127.0.0.1:5053).
# До AdGuard Home запросы тогда не доходят вовсе — он отвечает REFUSED,
# выглядит это как «AGH сломался», хотя сам он исправен.
#
# Флаг --disable-dns от этого не спасает: в 0.79 правило ставится и при
# DisableDNS=True. В 0.78 такой цепочки не было.
#
# Снимаем правило здесь, потому что юнит и так отрабатывает при каждой
# загрузке — после netbird, но до старта docker.
strip_netbird_dns_dnat() {
  command -v nft >/dev/null || return 0
  nft list chain ip netbird netbird-nat-output >/dev/null 2>&1 || return 0

  local handles
  handles="$(nft -a list chain ip netbird netbird-nat-output 2>/dev/null     | grep -E 'dport 53 .*dnat' | grep -oE 'handle [0-9]+$' | awk '{print $2}')"

  local h
  for h in $handles; do
    nft delete rule ip netbird netbird-nat-output handle "$h" 2>/dev/null       && echo "netbird: снят перехват DNS (handle $h)"
  done
}

strip_netbird_dns_dnat

echo "firewall: 53 — с lo, из ${DOCKER_NET}${CLIENT_NET:+ и из $CLIENT_NET}; 3000 — с lo и с интерфейса $OVERLAY_IF"
