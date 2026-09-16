#!/usr/bin/env bash
#
# Ставит AdGuard Home на реплику. Запускается НА САМОЙ НОДЕ, от root.
#
#   NB_KEY_REPLICA='<setup key реплик>' AGH_PASS_HASH='<bcrypt>' \
#     bash <(curl -fsSL https://raw.githubusercontent.com/dykomenko/adh-fleet/main/install.sh) HK01
#
# Единственный обязательный аргумент — ИМЯ ноды. Под ним она появится
# в консоли Netbird, так что удобно брать то же, что используется в остальной
# инфраструктуре. Никаких номеров помнить не нужно.
#
# Второй аргумент — сеть клиентов, НЕОБЯЗАТЕЛЬНЫЙ:
#
#   install.sh HK01                    DNS доступен только с localhost.
#                                      Вариант для Xray/Remnawave: клиенты
#                                      не получают адресов в туннеле, DNS
#                                      запрашивает сам прокси с этой же машины.
#
#   install.sh HK01 10.107.0.0/24      Дополнительно открывает 53-й порт
#                                      для сети клиентов. Вариант для
#                                      WireGuard/OpenVPN, где у клиентов
#                                      есть адреса в туннельной подсети.
#
# Ключ именно РЕПЛИК (auto-assign группы agh-replica). С ключом origin нода
# попадёт в agh-origin, и синхронизатор её не найдёт — при этом установка
# пройдёт без единой ошибки.
#
# AGH слушает 0.0.0.0:53 намеренно: туннельный интерфейс появляется и исчезает
# при рестартах, и привязка к его адресу означала бы, что AGH не стартует,
# если туннель поднялся позже. Доступ ограничивает firewall, а не bind-адрес.
#
# Фильтры, апстримы и правила сюда не прописываются — приедут с origin.
# Скрипт идемпотентен: повторный запуск безопасен.

set -euo pipefail

REPO="${REPO:-https://raw.githubusercontent.com/dykomenko/adh-fleet/main}"
APP_DIR=/opt/adguardhome

NODE_NAME="${1:?укажите имя ноды, например HK01}"
CLIENT_NET="${2:-${CLIENT_NET:-}}"

# Принимаем имя ровно как в .env, чтобы не было шага переименования:
# ключей два, и подставить не тот — значит увести ноду в группу agh-origin,
# где синхронизатор её никогда не найдёт.
NB_KEY="${NB_KEY_REPLICA:-${NB_KEY:-}}"
[[ -n "$NB_KEY" ]] || {
  echo "не задан ключ реплик." >&2
  echo "Передайте NB_KEY_REPLICA из .env — именно ключ РЕПЛИК, не origin." >&2
  exit 1
}
: "${AGH_PASS_HASH:?не задан AGH_PASS_HASH — bcrypt-хеш пароля админа с origin}"

# Проверяем, что это действительно bcrypt, а не заглушка из гайда и не сам
# пароль. Без проверки нода встаёт с нерабочей учёткой и выглядит полностью
# исправной — ошибка всплывает только на origin как 401 от синхронизатора,
# причём указывает на реплику, а не на источник проблемы.
if [[ ! "$AGH_PASS_HASH" =~ ^\$2[aby]\$[0-9]{2}\$.{53}$ ]]; then
  echo "AGH_PASS_HASH не похож на bcrypt-хеш." >&2
  echo "Ожидается строка вида \$2a\$10\$... длиной 60 символов." >&2
  echo "Получено: ${AGH_PASS_HASH:0:20}… (${#AGH_PASS_HASH} симв.)" >&2
  echo >&2
  echo "Хеш печатает make-template.sh на origin-ноде и хранится в .env" >&2
  echo "как AGH_PASS_HASH. Не путайте с самим паролем — он нужен только" >&2
  echo "для setup-origin.sh." >&2
  exit 1
fi

[[ "$NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] || {
  echo "имя ноды «$NODE_NAME» не годится для hostname." >&2
  echo "Допустимы буквы, цифры, точка, дефис и подчёркивание. Например: HK01" >&2
  exit 1
}

if [[ -n "$CLIENT_NET" ]]; then
  [[ "$CLIENT_NET" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] || {
    echo "сеть клиентов «$CLIENT_NET» не похожа на CIDR, например 10.107.0.0/24" >&2
    exit 1
  }
fi

[[ $EUID -eq 0 ]] || { echo "нужен root" >&2; exit 1; }

echo "нода $NODE_NAME (хост $(hostname -s))"
if [[ -n "$CLIENT_NET" ]]; then
  echo "  сеть клиентов: $CLIENT_NET — 53-й порт будет открыт для неё"
else
  echo "  сеть клиентов не задана — 53-й порт только с localhost"
fi

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

# Состояние старой установки удаляется целиком. В 0.78 у агента появились
# профили, и конфигурация может лежать не только в /etc/netbird/config.json —
# остатки уводят ноду в чужую сеть, что по выводу команд не видно.
if [[ "${NB_KEEP_STATE:-}" != "1" ]]; then
  systemctl stop netbird 2>/dev/null || true
  rm -rf /etc/netbird /var/lib/netbird
fi

systemctl start netbird 2>/dev/null || true
sleep 2

NB_RESOLVER="${NB_RESOLVER:-127.0.0.1:5053}"

# Management URL задаётся ЯВНО. Без него агент берёт адрес из унаследованного
# состояния, и заметить это невозможно: он пишет «Connected» и получает адрес,
# просто в чужой сети. В консоли при этом пусто, а ноды не видят друг друга.
# Для self-hosted Netbird переопределите NB_MGMT.
NB_MGMT="${NB_MGMT:-https://api.netbird.io:443}"

nb_connect() {
  netbird down >/dev/null 2>&1 || true
  netbird up --management-url "$NB_MGMT" \
    --setup-key "$NB_KEY" --hostname "$NODE_NAME" \
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

# Сверяем, к тому ли серверу подключились. Агент пишет «Connected» и выдаёт
# адрес даже когда ушёл в чужую сеть — без этой проверки нода выглядит
# установленной, но origin её никогда не увидит.
NB_MGMT_ACTUAL="$(netbird status -d 2>/dev/null | awk '/^Management:/ {print $NF}')"
case "$NB_MGMT_ACTUAL" in
  *"${NB_MGMT#https://}"*|*api.netbird.io*) : ;;
  *)
    echo "нода подключена не к тому management-серверу:" >&2
    echo "  ожидался: $NB_MGMT" >&2
    echo "  фактически: ${NB_MGMT_ACTUAL:-не определён}" >&2
    exit 1
    ;;
esac

echo "оверлей: $NB_IP ($(netbird status -d 2>/dev/null | awk '/^FQDN:/ {print $2}'))"

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
# Делается ДО запуска AGH: иначе между стартом и появлением правил нода
# несколько секунд стоит открытым резолвером на публичном адресе.
#
# Чистый iptables, без ufw: на нодах его обычно нет, а тащить пакет ради
# трёх правил незачем. Политика INPUT не трогается — только отдельная
# цепочка для портов 53 и 3000, чтобы не задеть правила уже стоящего VPN.
command -v iptables >/dev/null || { echo "iptables не найден" >&2; exit 1; }

printf 'CLIENT_NET=%s\n' "$CLIENT_NET" > /etc/adh-firewall.conf
printf 'OVERLAY_IF=%s\n' "${OVERLAY_IF:-wt0}" >> /etc/adh-firewall.conf
curl -fsSL "$REPO/node/adh-firewall.sh"      -o /usr/local/sbin/adh-firewall.sh
curl -fsSL "$REPO/node/adh-firewall.service" -o /etc/systemd/system/adh-firewall.service
chmod 755 /usr/local/sbin/adh-firewall.sh

# Пустой юнит systemd считает замаскированным, и enable упадёт с
# «Unit file is masked» — причина при этом выглядит не связанной с загрузкой.
for f in /usr/local/sbin/adh-firewall.sh /etc/systemd/system/adh-firewall.service; do
  [[ -s "$f" ]] || { echo "файл $f пуст — загрузка не удалась" >&2; rm -f "$f"; exit 1; }
done

systemctl daemon-reload
systemctl enable --now adh-firewall.service

# Правила живут в памяти ядра и после перезагрузки исчезли бы — юнит
# накатывает их заново при каждой загрузке, до старта docker.
systemctl is-enabled --quiet adh-firewall.service \
  || { echo "юнит adh-firewall не включился — правила не переживут перезагрузку" >&2; exit 1; }

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

# Адреса не подставляются: и DNS, и панель слушают все интерфейсы,
# а ограничивает доступ iptables. Единственная подстановка — хеш пароля,
# без которого синхронизатор не смог бы авторизоваться на реплике.
umask 077
sed -e "s|__PASS_HASH__|$AGH_PASS_HASH|g" \
    "$APP_DIR/AdGuardHome.yaml.tmpl" > "$APP_DIR/conf/AdGuardHome.yaml"
umask 022

if grep -q '__PASS_HASH__' "$APP_DIR/conf/AdGuardHome.yaml"; then
  echo "в конфиге остался неподставленный плейсхолдер" >&2
  exit 1
fi

# --- 5. запуск --------------------------------------------------------------
docker compose -f "$APP_DIR/docker-compose.yml" up -d

# --- 6. системный резолвер ноды направляется на AGH -------------------------
# Одна из двух половин, нужных для фильтрации клиентского трафика.
# Вторая — отсутствие секции dns в конфиге Xray: пока она есть, Xray резолвит
# встроенным резолвером и системный не спрашивает вовсе. Убрать надо обе,
# по отдельности не работает ни одна.
#
# Симптом при пропуске: в журнале AGH только собственные проверки
# администратора и ни одного клиентского домена.
#
# Делается ПОСЛЕ старта контейнера: переключить резолвер на ещё не поднятый
# AGH означало бы оставить ноду без DNS посреди установки.
if [[ "${SKIP_RESOLV:-}" != "1" ]]; then
  command -v dig >/dev/null || apt-get install -y -qq dnsutils >/dev/null 2>&1 || true

  agh_ready=""
  for _ in $(seq 1 20); do
    if dig +short +time=1 +tries=1 @127.0.0.1 example.com >/dev/null 2>&1; then
      agh_ready=1; break
    fi
    sleep 1
  done

  if [[ -n "$agh_ready" ]]; then
    # Символьная ссылка заменяется обычным файлом: пока /etc/resolv.conf
    # указывает на каталог systemd-resolved, содержимое перезапишется.
    cp -a /etc/resolv.conf /etc/resolv.conf.adh-backup 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:2\n' > /etc/resolv.conf

    if getent hosts example.com >/dev/null 2>&1; then
      echo "системный резолвер переключён на AGH"
    else
      echo "резолвинг через AGH не заработал — возвращаю прежний resolv.conf" >&2
      rm -f /etc/resolv.conf
      cp -a /etc/resolv.conf.adh-backup /etc/resolv.conf 2>/dev/null \
        || ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    fi
  else
    echo "AGH не ответил на 127.0.0.1:53 — резолвер ноды оставлен прежним." >&2
    echo "Фильтрация до клиентов не дойдёт, пока это не исправлено." >&2
  fi
fi

# --- 7. резолвер контейнеров в host-сети ------------------------------------
# Docker при наследовании resolv.conf хоста выбрасывает loopback-адреса
# и подставляет публичные. В итоге Xray резолвит через 8.8.8.8 и до AGH
# не доходит никогда — при том, что на хосте resolv.conf указывает на AGH,
# а секции dns в конфиге Xray нет. Видно только изнутри контейнера.
#
# Логика вынесена в отдельный скрипт: она нужна и Ansible-роли, и здесь,
# а дублировать её в двух местах значит однажды поправить только одно.
curl -fsSL "$REPO/node/adh-container-dns.sh" -o /usr/local/sbin/adh-container-dns.sh
chmod 755 /usr/local/sbin/adh-container-dns.sh
echo "резолвер контейнеров:"
/usr/local/sbin/adh-container-dns.sh || echo "  часть контейнеров осталась без AGH — см. выше" >&2

echo
echo "нода $NODE_NAME готова"
if [[ -n "$CLIENT_NET" ]]; then
  echo "  DNS    0.0.0.0:53 — с localhost и из $CLIENT_NET"
else
  echo "  DNS    0.0.0.0:53 — только с localhost"
fi
echo "  резолвер ноды: $(grep -m1 '^nameserver' /etc/resolv.conf 2>/dev/null || echo '?')"
echo "  панель $NB_IP:3000"
echo
echo "фильтры приедут с origin в течение часа."
echo "нужно сейчас — запустите на origin: /opt/agh-sync/sync-now.sh"
