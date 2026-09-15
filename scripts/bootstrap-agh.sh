#!/usr/bin/env bash
#
# Разворачивает AdGuard Home на ноде. Запускается НА САМОЙ НОДЕ, от root.
# Обычно его не зовут руками — это делает scripts/add-node.sh с рабочей машины.
#
#   NB_KEY=<setup key> ./bootstrap-agh.sh <адрес шлюза VPN>
#
# До запуска в /opt/adguardhome должны лежать docker-compose.yml
# и AdGuardHome.yaml.tmpl — их кладёт add-node.sh.

set -euo pipefail

VPN_GW="${1:?укажите адрес шлюза VPN на этой ноде, например 10.107.0.1}"
: "${NB_KEY:?экспортируйте NB_KEY — многоразовый setup key Netbird}"

APP_DIR=/opt/adguardhome
TMPL="$APP_DIR/AdGuardHome.yaml.tmpl"

[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }
[[ -f "$TMPL" ]] || { echo "нет $TMPL — шаблон не доехал на ноду" >&2; exit 1; }
[[ -f "$APP_DIR/docker-compose.yml" ]] || { echo "нет $APP_DIR/docker-compose.yml" >&2; exit 1; }
command -v docker >/dev/null || { echo "docker не установлен" >&2; exit 1; }

command -v jq >/dev/null || { apt-get update -qq && apt-get install -y -qq jq; }

# --- 1. оверлей -------------------------------------------------------------
# --disable-dns обязателен: агент оверлея иначе правит /etc/resolv.conf,
# а на DNS-сервере это ровно то, чего быть не должно.
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
if systemctl is-active --quiet systemd-resolved; then
  sed -i 's/^#\?DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
  grep -q '^DNSStubListener=no' /etc/systemd/resolved.conf \
    || echo 'DNSStubListener=no' >> /etc/systemd/resolved.conf
  systemctl restart systemd-resolved
fi

# --- 3. конфиг из шаблона ---------------------------------------------------
# Готовый AdGuardHome.yaml на месте => мастер установки не запускается.
install -d "$APP_DIR/conf" "$APP_DIR/work"
sed -e "s|__VPN_GW__|$VPN_GW|g" -e "s|__NB_IP__|$NB_IP|g" "$TMPL" \
  > "$APP_DIR/conf/AdGuardHome.yaml"

if grep -q '__VPN_GW__\|__NB_IP__' "$APP_DIR/conf/AdGuardHome.yaml"; then
  echo "в конфиге остались неподставленные плейсхолдеры" >&2
  exit 1
fi

# --- 4. запуск --------------------------------------------------------------
docker compose -f "$APP_DIR/docker-compose.yml" up -d

echo
echo "нода $(hostname -s) готова"
echo "  DNS    $VPN_GW:53"
echo "  панель $NB_IP:3000"
echo "в список реплик попадёт в течение 15 минут"
