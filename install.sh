#!/usr/bin/env bash
#
# Ставит AdGuard Home на реплику. Запускается НА САМОЙ НОДЕ, от root.
#
#   NB_KEY=<setup key> AGH_PASS_HASH='<bcrypt>' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/install.sh) 7
#
# Единственный аргумент — номер ноды. Из него выводится сеть клиентов:
#   нода N -> 10.(100+N).0.0/24, шлюз 10.(100+N).0.1
#
# AGH слушает 0.0.0.0:53 намеренно: VPN-интерфейс появляется и исчезает
# при рестартах, и привязка к его адресу означала бы, что AGH не стартует,
# если туннель поднялся позже. Доступ ограничивает firewall, а не bind-адрес.
#
# Фильтры, апстримы и правила сюда не прописываются — приедут с origin.
# Скрипт идемпотентен: повторный запуск безопасен.

set -euo pipefail

REPO="${REPO:-https://raw.githubusercontent.com/dykomenko/adh-fleet/main}"
APP_DIR=/opt/adguardhome

NUM="${1:?укажите номер ноды, например 7}"
: "${NB_KEY:?не задан NB_KEY — многоразовый setup key Netbird}"
: "${AGH_PASS_HASH:?не задан AGH_PASS_HASH — bcrypt-хеш пароля админа с origin}"

[[ "$NUM" =~ ^[0-9]+$ ]] || { echo "номер ноды должен быть числом" >&2; exit 1; }
(( NUM >= 1 && NUM <= 154 )) || { echo "номер вне диапазона 1..154" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }

CLIENT_NET="10.$((100 + NUM)).0.0/24"
VPN_GW="10.$((100 + NUM)).0.1"
echo "нода $(hostname -s), номер $NUM, сеть клиентов $CLIENT_NET"

command -v docker >/dev/null || { echo "docker не установлен" >&2; exit 1; }
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq curl; }

# --- 1. оверлей -------------------------------------------------------------
# Нужны ОБА флага, проверено на netbird 0.78.2:
#
#   --disable-dns            запрещает агенту править настройки DNS системы,
#                            но локальный резолвер при этом всё равно поднимается;
#   --dns-resolver-address   уводит этот резолвер с порта 53, который нужен AGH.
#
# Только вторым флагом порт освобождается. 5053 — из примера в справке netbird;
# 5353 занят mDNS и на образах с avahi может конфликтовать.
#
# Службу останавливаем ДО установщика: на работающей он отказывается
# ставиться («NetBird service is running») и молча выходит, оставляя
# старый бинарь.
systemctl stop netbird 2>/dev/null || true
curl -fsSL https://pkgs.netbird.io/install.sh | sh
systemctl start netbird 2>/dev/null || true
sleep 2

NB_RESOLVER="${NB_RESOLVER:-127.0.0.1:5053}"

nb_connect() {
  netbird down >/dev/null 2>&1 || true
  netbird up --setup-key "$NB_KEY" --hostname "$(hostname -s)" \
    --disable-dns --dns-resolver-address "$NB_RESOLVER"
}

nb_ip() {
  local ip=""
  for _ in $(seq 1 15); do
    ip="$(netbird status --json 2>/dev/null | jq -r '.netbirdIp // empty' | cut -d/ -f1)"
    [[ -n "$ip" ]] && break
    sleep 2
  done
  printf '%s' "$ip"
}

nb_connect
NB_IP="$(nb_ip)"

# Если резолвер агента всё ещё держит 53, значит флаг не применился
# к унаследованной конфигурации. Сбрасываем её и подключаемся заново.
if ss -ulnp 2>/dev/null | grep ':53 ' | grep -q netbird; then
  echo "резолвер netbird занимает порт 53 — сбрасываю конфигурацию агента"
  systemctl stop netbird
  rm -f /etc/netbird/config.json
  systemctl start netbird
  sleep 2
  nb_connect
  NB_IP="$(nb_ip)"
fi

[[ -n "$NB_IP" ]] || { echo "нода не получила адрес в оверлее" >&2; exit 1; }
echo "оверлей: $NB_IP"

if ss -ulnp 2>/dev/null | grep ':53 ' | grep -q netbird; then
  echo "резолвер netbird всё ещё на порту 53 — дальше идти нельзя." >&2
  echo "Сверьте флаги вашей версии: netbird up --help | grep -i dns" >&2
  exit 1
fi

# --- 2. освобождаем порт 53 -------------------------------------------------
# Отключаем stub-listener systemd-resolved и переводим resolv.conf на реальные
# апстримы: иначе резолвер ноды указывает на 127.0.0.53, который больше
# не слушает, и нода остаётся без DNS до самого конца установки.
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf \
    || echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
  systemctl restart systemd-resolved

  if [[ -f /run/systemd/resolve/resolv.conf ]]; then
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  fi
fi

if ss -ulnp 2>/dev/null | grep -q ':53 '; then
  echo "порт 53 всё ещё занят:" >&2
  ss -ulnp | grep ':53 ' >&2
  exit 1
fi

# --- 3. firewall ------------------------------------------------------------
# Делается ДО запуска AGH: иначе между стартом и правилами нода несколько
# секунд стоит открытым резолвером на публичном адресе.
if command -v ufw >/dev/null; then
  # Порт SSH берём из того, что реально слушает sshd — на нестандартном
  # порту иначе можно отрезать себе доступ включением ufw.
  mapfile -t SSH_PORTS < <(
    ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]}' | sort -u
  )
  [[ ${#SSH_PORTS[@]} -eq 0 ]] && SSH_PORTS=(22)
  for p in "${SSH_PORTS[@]}"; do
    echo "  ufw: разрешаю SSH на порту $p"
    ufw allow "$p/tcp" >/dev/null
  done

  ufw allow from 100.64.0.0/10 to any port 3000 proto tcp >/dev/null
  ufw allow from "$CLIENT_NET" to any port 53 >/dev/null

  if ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
    ufw --force enable >/dev/null
  fi
  echo "  ufw: 53 открыт только для $CLIENT_NET, 3000 — только для оверлея"
else
  echo "ВНИМАНИЕ: ufw не установлен." >&2
  echo "AGH будет слушать 0.0.0.0:53 — закройте порт своим фаерволом," >&2
  echo "иначе нода станет открытым резолвером." >&2
fi

# --- 4. конфиг из шаблона ---------------------------------------------------
# Готовый AdGuardHome.yaml на месте => мастер установки не запускается.
install -d "$APP_DIR/conf" "$APP_DIR/work"
curl -fsSL "$REPO/node/docker-compose.yml" -o "$APP_DIR/docker-compose.yml"

if ! curl -fsSL "$REPO/node/AdGuardHome.yaml.tmpl" -o "$APP_DIR/AdGuardHome.yaml.tmpl"; then
  cat >&2 <<'MSG'

Шаблон конфига не скачался.

Причина почти наверняка одна из двух:
  1. origin-нода ещё не настроена и шаблон не закоммичен в репозиторий.
     Пройдите docs/origin.md, шаг 5 — make-template.sh напечатает
     AGH_PASS_HASH и отдаст node/AdGuardHome.yaml.tmpl.
  2. репозиторий приватный, и curl получил 404 вместо файла.

MSG
  exit 1
fi

umask 077
sed -e "s|__NB_IP__|$NB_IP|g" \
    -e "s|__PASS_HASH__|$AGH_PASS_HASH|g" \
    "$APP_DIR/AdGuardHome.yaml.tmpl" > "$APP_DIR/conf/AdGuardHome.yaml"
umask 022

if grep -q '__NB_IP__\|__PASS_HASH__' "$APP_DIR/conf/AdGuardHome.yaml"; then
  echo "в конфиге остались неподставленные плейсхолдеры" >&2
  exit 1
fi

# --- 5. запуск --------------------------------------------------------------
docker compose -f "$APP_DIR/docker-compose.yml" up -d

echo
echo "нода $(hostname -s) готова"
echo "  DNS    0.0.0.0:53, доступен из $CLIENT_NET"
echo "  шлюз   $VPN_GW — поднимите на нём VPN, если ещё не поднят"
echo "  панель $NB_IP:3000"
echo
echo "фильтры приедут с origin в течение часа."
echo "нужно сейчас — запустите на origin: /opt/agh-sync/sync-now.sh"
