#!/usr/bin/env bash
#
# Снимает наследие прежнего подхода: секцию dns, которую adh-fleet дописывал
# в docker-compose.override.yml рядом с compose VPN-ноды.
#
# Зачем это нужно. Файл docker-compose.override.yml у remnanode принадлежит
# стороннему инструменту configure-remnanode-tls-mount (сертификаты Hysteria2).
# Он:
#
#   - отказывается работать, если файл не помечен его строкой managed-by —
#     то есть там, где override создавали мы, его TLS-часть не ставится вовсе;
#   - свой файл генерирует с нуля и кладёт поверх — то есть там, где мы
#     дописали dns в его файл, наша правка исчезает при следующем прогоне.
#
# Конфликт в обе стороны, и третьим файлом он не решается: инструмент запускает
# compose с явными -f, любой дополнительный override игнорируется.
#
# Поэтому резолвер контейнерам отдаётся через /etc/resolv.conf хоста с адресом
# docker-моста (см. install.sh): Docker выбрасывает при наследовании только
# loopback, а адрес моста пропускает как есть. Compose не участвует вовсе,
# а этот скрипт убирает то, что осталось от старой схемы.
#
# Контейнеры НЕ перезапускаются. Правка файла на работающий контейнер
# не влияет: он продолжает жить с текущими настройками, а новое состояние
# подхватится при ближайшем пересоздании — своём или от чужого скрипта.
#
# Идемпотентен: на чистой ноде ничего не находит и выходит с нулём.
# DRY_RUN=1 — только показать, что было бы сделано.

set -uo pipefail

DRY="${DRY_RUN:-}"

# Корень со стеками. Переопределяется только в тестах.
OPT="${ADH_OPT:-/opt}"

# Чужую секцию dns не трогаем: в whitelist только то, что писали мы сами —
# адреса и опции resolv.conf. Встретилось что-то ещё — файл оставляем как есть
# и говорим вслух, пусть решает человек.
AWK_STRIP='
function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
{ lines[NR] = $0 }
END {
  foreign = 0; dropped = 0
  i = 1
  while (i <= NR) {
    l = lines[i]
    if (l ~ /^[ \t]+dns(_opt)?:[ \t]*$/) {
      ind = indent(l); j = i + 1; cnt = 0; ok = 1; last = i
      while (j <= NR) {
        c = lines[j]
        if (c ~ /^[ \t]*$/) { j++; continue }
        if (indent(c) <= ind) break
        if (c ~ /^[ \t]*-[ \t]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[ \t]*$/) cnt++
        else if (c ~ /^[ \t]*-[ \t]*(timeout|attempts|ndots)(:[0-9]+)?[ \t]*$/) cnt++
        else ok = 0
        last = j
        j++
      }
      if (ok && cnt > 0) {
        for (k = i; k <= last; k++) drop[k] = 1
        dropped += last - i + 1
        i = j
        continue
      }
      foreign = 1
    } else if (l ~ /^[ \t]+dns(_opt)?:[ \t]*[^ \t]/) {
      # Список в одну строку (dns: [127.0.0.1]) мы не писали никогда — чужое.
      foreign = 1
    }
    i++
  }

  if (foreign) exit 5
  if (!dropped) exit 4

  # Остались ли у сервисов свойства кроме снятых. Если нет — файл был целиком
  # нашим: ключ сервиса без содержимого compose не принимает, и чинить такой
  # файл нечем, его нужно удалять.
  props = 0
  for (i = 1; i <= NR; i++) {
    if (drop[i]) continue
    l = lines[i]
    if (l ~ /^[ \t]*$/ || l ~ /^[ \t]*#/) continue
    if (indent(l) >= 4) props++
  }

  for (i = 1; i <= NR; i++) if (!drop[i]) print lines[i]
  if (!props) exit 3
  exit 0
}
'

# Каталоги со стеками. Основной источник — метки compose у контейнеров: путь
# у разных нод разный (/opt/remnanode, /opt/rwnode, /opt/selfsteal), угадывать
# его не нужно. Плюс обычные места на случай остановленного стека.
candidates() {
  if command -v docker >/dev/null; then
    docker ps -a --format '{{.ID}}' 2>/dev/null | while read -r id; do
      docker inspect "$id" \
        --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null
    done
  fi
  ls -d "$OPT"/*/ "$OPT"/*/*/ 2>/dev/null
}

files="$(candidates | sed 's:/*$::' | grep -v '^$' | sort -u \
  | while read -r d; do
      [[ -f "$d/docker-compose.override.yml" ]] && echo "$d/docker-compose.override.yml"
    done | sort -u)"

[[ -n "$files" ]] || { echo "override-файлов не найдено — чистить нечего"; exit 0; }

touched=0
left=0

while read -r f; do
  [[ -n "$f" ]] || continue

  out="$(awk "$AWK_STRIP" "$f")"
  rc=$?

  case "$rc" in
    4) ;;  # нашей секции dns в файле нет
    5)
      echo "! $f: секция dns не похожа на нашу — не трогаю, посмотрите сами" >&2
      left=$((left + 1))
      ;;
    3)
      echo "- $f: файл был целиком нашим (только dns) — удаляю"
      echo "    он блокировал configure-remnanode-tls-mount: тот отказывается"
      echo "    работать с чужим override — «Override is not managed by this script»"
      if [[ -z "$DRY" ]]; then
        cp -a "$f" "$f.removed-by-adh" 2>/dev/null || true
        rm -f "$f"
      fi
      touched=$((touched + 1))
      ;;
    0)
      echo "- $f: снимаю нашу секцию dns, остальное сохраняю"
      if [[ -z "$DRY" ]]; then
        cp -a "$f" "$f.bak-adh-cleanup" 2>/dev/null || true
        printf '%s\n' "$out" > "$f"
      fi
      touched=$((touched + 1))
      ;;
    *)
      echo "! $f: awk вернул $rc — пропускаю" >&2
      left=$((left + 1))
      ;;
  esac
done <<< "$files"

# Бэкапы прежнего скрипта не удаляем: это копии ЧУЖИХ файлов, и решать их
# судьбу должен человек. Но сказать о них стоит — иначе так и останутся.
stale="$(ls "$OPT"/*/docker-compose.override.yml.bak-adh \
  "$OPT"/*/*/docker-compose.override.yml.bak-adh 2>/dev/null)"
if [[ -n "$stale" ]]; then
  echo
  echo "остались бэкапы прежнего подхода, удалите вручную, когда убедитесь:"
  printf '  %s\n' $stale
fi

echo
if (( touched )); then
  echo "поправлено файлов: $touched"
  echo "контейнеры не перезапускались — правки вступят в силу при их ближайшем"
  echo "пересоздании. Резолвер контейнерам сейчас отдаёт /etc/resolv.conf хоста"
  echo "через адрес docker-моста, compose для этого не нужен."
else
  echo "наследия прежнего подхода не найдено"
fi
(( left == 0 )) || exit 1
