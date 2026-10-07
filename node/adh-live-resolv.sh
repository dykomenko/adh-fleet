#!/usr/bin/env bash
#
# Переводит резолвер УЖЕ ЗАПУЩЕННЫХ контейнеров на AdGuard Home,
# не пересоздавая их.
#
# Зачем нужен отдельный скрипт. Docker формирует /etc/resolv.conf контейнера
# один раз, при создании, и монтирует получившийся файл внутрь. Правка
# resolv.conf хоста на уже работающий контейнер не влияет никак: он живёт
# с тем, что ему досталось при создании — на боевых нодах это адрес хостера
# или 1.1.1.1, то есть мимо AGH. Выглядит это как «фильтрация не применилась»,
# при том что на хосте всё настроено верно.
#
# Пересоздавать контейнер ради этого не нужно: Docker монтирует файл
# /var/lib/docker/containers/<id>/resolv.conf и сам пишет в его заголовке,
# что файл можно править. Мы перезаписываем его НА МЕСТЕ, сохраняя inode —
# иначе монтирование разорвётся. Xray замечает изменение в пределах секунд:
# резолвер Go перечитывает файл по времени модификации.
#
# При следующем пересоздании контейнера Docker возьмёт resolv.conf хоста,
# где уже стоит адрес моста, — правка самоустранится, оставшись верной.
#
#   ADH_DNS_MATCH     кого чинить (regex по «имя<TAB>образ»)
#   ADH_DNS_EXCLUDE   кого пропустить, проверяется первым
#   ADH_DNS_FALLBACK  запасной резолвер (пусто = без него, fail-closed)

set -uo pipefail

MATCH="${ADH_DNS_MATCH:-remnawave/node|(^|[^a-z])(remnanode|rwnode)([^a-z]|$)}"
# AGH исключаем всегда: он резолвит через свои апстримы, а не через resolv.conf,
# и указывать его на самого себя незачем. Заглушку selfsteal тоже не трогаем —
# клиентских доменов она не резолвит.
EXCLUDE="${ADH_DNS_EXCLUDE:-adguardhome|caddy|nginx}"
FALLBACK="${ADH_DNS_FALLBACK-1.1.1.1}"

command -v docker >/dev/null || { echo "docker не найден" >&2; exit 1; }

GW="$(ip -4 addr show docker0 2>/dev/null | grep -oE 'inet [0-9.]+' | awk '{print $2}' | head -1)"
[[ -n "$GW" ]] || GW="$(docker network inspect bridge \
  -f '{{range .IPAM.Config}}{{.Gateway}}{{end}}' 2>/dev/null)"
[[ -n "$GW" ]] || { echo "адрес docker-моста не определён — чинить нечем" >&2; exit 1; }

# Проверяем, что AGH по этому адресу действительно отвечает. Иначе правка
# оставила бы контейнер с неработающим первым резолвером: при живом запасном
# это лишняя секунда на каждый запрос, при fail-closed — потеря связи.
if command -v dig >/dev/null; then
  if [[ -z "$(dig +short +time=2 +tries=1 @"$GW" example.com 2>/dev/null)" ]]; then
    echo "AGH не отвечает на $GW:53 — сначала разберитесь с этим." >&2
    echo "Если dig @127.0.0.2 example.com отвечает, AGH исправен, и дело" >&2
    echo "в пути до адреса моста: обновите adh-firewall.sh (правило по lo)." >&2
    exit 1
  fi
fi

touched=0
skipped=0

while IFS=$'\t' read -r name image; do
  [[ -z "$name" ]] && continue
  printf '%s\t%s\n' "$name" "$image" | grep -qEi "$EXCLUDE" && continue
  printf '%s\t%s\n' "$name" "$image" | grep -qEi "$MATCH" || continue

  path="$(docker inspect "$name" -f '{{.ResolvConfPath}}' 2>/dev/null)"
  if [[ -z "$path" || ! -f "$path" ]]; then
    echo "! $name: resolv.conf контейнера не найден — пропускаю" >&2
    skipped=$((skipped + 1))
    continue
  fi

  if grep -qE "^nameserver[[:space:]]+${GW//./\.}$" "$path"; then
    echo "= $name: уже указывает на $GW"
    continue
  fi

  cp -a "$path" "$path.bak-adh" 2>/dev/null || true
  {
    echo "# Правлено adh-live-resolv.sh: резолвер направлен на AdGuard Home."
    echo "# Docker перегенерирует файл при пересоздании контейнера, взяв"
    echo "# /etc/resolv.conf хоста — там уже стоит тот же адрес."
    echo "nameserver $GW"
    [[ -n "$FALLBACK" ]] && echo "nameserver $FALLBACK"
    echo 'options timeout:1 attempts:1'
    echo 'search .'
  } > "$path"

  echo "- $name: резолвер переведён на $GW"
  touched=$((touched + 1))
done < <(docker ps --format '{{.Names}}\t{{.Image}}')

echo
if (( touched )); then
  echo "поправлено контейнеров: $touched, перезапусков не было"
  echo "проверьте реальный трафик: tcpdump -ni lo udp port 53 | grep $GW"
else
  echo "менять было нечего"
fi
(( skipped == 0 )) || exit 1
