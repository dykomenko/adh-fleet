#!/usr/bin/env bash
#
# Ставит AdGuard Home на реплику. Запускается НА САМОЙ НОДЕ, от root.
#
#   NB_KEY=<setup key> AGH_PASS_HASH='<bcrypt>' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/install.sh) 7
#
# Единственный аргумент — номер ноды. Из него выводится адресация:
#   нода N -> сеть 10.(100+N).0.0/24, шлюз и DNS 10.(100+N).0.1
#
# Фильтры, апстримы и правила сюда не прописываются — они приедут с origin
# синхронизацией. Скрипт идемпотентен: повторный запуск безопасен.

set -euo pipefail

REPO="${REPO:-https://raw.githubusercontent.com/dykomenko/adh-fleet/main}"
APP_DIR=/opt/adguardhome

NUM="${1:?укажите номер ноды, например 7}"
: "${NB_KEY:?не задан NB_KEY — многоразовый setup key Netbird}"
: "${AGH_PASS_HASH:?не задан AGH_PASS_HASH — bcrypt-хеш пароля админа с origin}"

[[ "$NUM" =~ ^[0-9]+$ ]] || { echo "номер ноды должен быть числом" >&2; exit 1; }
(( NUM >= 1 && NUM <= 154 )) || { echo "номер вне диапазона 1..154" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }

VPN_GW="10.$((100 + NUM)).0.1"
echo "нода $(hostname -s), номер $NUM, шлюз $VPN_GW"

command -v docker >/dev/null || { echo "docker не установлен" >&2; exit 1; }
command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq curl; }

# --- 1. оверлей -------------------------------------------------------------
# --disable-dns обязателен: агент иначе правит /etc/resolv.conf,
# а на DNS-сервере этого быть не должно.
command -v netbird >/dev/null || curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --setup-key "$NB_KEY" --hostname "$(hostname -s)" --disable-dns

NB_IP=""
for _ in $(seq 1 15); do
  NB_IP="$(netbird status --json 2>/dev/null | jq -r '.netbirdIp // empty' | cut -d/ -f1)"
  [[ -n "$NB_IP" ]] && break
  sleep 2
done
[[ -n "$NB_IP" ]] || { echo "нода не получила адрес в оверлее" >&2; exit 1; }
echo "оверлей: $NB_IP"

# --- 2. освобождаем порт 53 -------------------------------------------------
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf \
    || echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
  systemctl restart systemd-resolved
fi

# --- 3. конфиг из шаблона ---------------------------------------------------
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
sed -e "s|__VPN_GW__|$VPN_GW|g" \
    -e "s|__NB_IP__|$NB_IP|g" \
    -e "s|__PASS_HASH__|$AGH_PASS_HASH|g" \
    "$APP_DIR/AdGuardHome.yaml.tmpl" > "$APP_DIR/conf/AdGuardHome.yaml"
umask 022

if grep -q '__VPN_GW__\|__NB_IP__\|__PASS_HASH__' "$APP_DIR/conf/AdGuardHome.yaml"; then
  echo "в конфиге остались неподставленные плейсхолдеры" >&2
  exit 1
fi

# --- 4. запуск --------------------------------------------------------------
docker compose -f "$APP_DIR/docker-compose.yml" up -d

echo
echo "нода $(hostname -s) готова"
echo "  DNS    $VPN_GW:53"
echo "  панель $NB_IP:3000"
echo
echo "фильтры приедут с origin в течение часа."
echo "нужно сейчас — запустите на origin: /opt/agh-sync/sync-now.sh"
