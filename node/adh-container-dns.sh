#!/usr/bin/env bash
#
# Направляет резолвер контейнера VPN-ноды на AdGuard Home.
#
# Зачем: Docker при наследовании resolv.conf хоста выбрасывает loopback-адреса
# и подставляет публичные — он не знает, что у контейнера сетевой namespace
# хоста и 127.0.0.1 здесь рабочий. В итоге Xray резолвит через 8.8.8.8
# и до AGH не доходит никогда, при том что на хосте resolv.conf указывает
# на AGH, а секции dns в конфиге Xray нет. Видно только изнутри контейнера.
#
# Что ищем: контейнер, который проксирует клиентский трафик. Опознаём по
# ОБРАЗУ — он стабилен, в отличие от имени каталога: стек лежит в /opt/remnanode,
# /opt/rwnode или /opt/selfsteal в зависимости от ноды. Сам каталог берётся
# из меток compose, поэтому список путей не нужен.
#
# Кого НЕ трогаем: заглушку selfsteal — она отдаёт статику, клиентские домены
# не резолвит, и перезапуск ради неё это лишний простой на боевой ноде.
# Опознаём её по ОБРАЗУ (caddy), а не по имени: каталог узла тоже может
# называться selfsteal, и исключение по имени убило бы настоящий контейнер.
#
# Существующий override не перезаписывается, а дополняется: на боевых нодах
# он есть почти всегда, и затереть его значило бы потерять чужую настройку.
#
#   ADH_DNS_MATCH     кого чинить (regex по «имя<TAB>образ»)
#   ADH_DNS_EXCLUDE   кого пропустить, проверяется первым

set -uo pipefail

MATCH="${ADH_DNS_MATCH:-remnawave/node|(^|[^a-z])(remnanode|rwnode)([^a-z]|$)}"
EXCLUDE="${ADH_DNS_EXCLUDE:-adguardhome|caddy|nginx}"

command -v docker >/dev/null || { echo "docker не найден" >&2; exit 1; }
command -v python3 >/dev/null || { echo "нужен python3 для правки override" >&2; exit 1; }

declare -A svc_by_dir
targets=""

while IFS=$'\t' read -r name image; do
  [[ -z "$name" ]] && continue
  printf '%s\t%s\n' "$name" "$image" | grep -qEi "$EXCLUDE" && continue
  printf '%s\t%s\n' "$name" "$image" | grep -qEi "$MATCH" || continue

  targets+="$name "

  dir="$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  svc="$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.service"}}')"

  if [[ -z "$dir" || -z "$svc" ]]; then
    echo "  $name: поднят не через compose — задайте резолвер вручную" >&2
    continue
  fi

  case " ${svc_by_dir[$dir]:-} " in
    *" $svc "*) ;;
    *) svc_by_dir["$dir"]="${svc_by_dir[$dir]:-}$svc " ;;
  esac
done < <(docker ps --format '{{.Names}}\t{{.Image}}')

if [[ -z "$targets" ]]; then
  echo "контейнер VPN-ноды не найден (искали: $MATCH)." >&2
  echo "Резолвер не настроен — клиенты фильтроваться НЕ будут." >&2
  echo "Если у вас другой образ или имя, задайте ADH_DNS_MATCH." >&2
  exit 1
fi

rc=0
for dir in "${!svc_by_dir[@]}"; do
  services="${svc_by_dir[$dir]}"

  if ! python3 - "$dir/docker-compose.override.yml" $services <<'PY'
import io, os, shutil, sys

path, services = sys.argv[1], sys.argv[2:]
BLOCK = ["    dns:", "      - 127.0.0.1"]

existed = os.path.exists(path)
if existed:
    shutil.copy2(path, path + ".bak-adh")
    lines = io.open(path, encoding="utf-8").read().split("\n")
else:
    lines = ["# Дополняется скриптом adh-container-dns.sh из adh-fleet.",
             "# Резолвер контейнера направлен на AdGuard Home: Docker иначе",
             "# подставляет публичные серверы вместо loopback хоста.",
             "services:"]

si = None
for i, l in enumerate(lines):
    if l.rstrip() == "services:":
        si = i
        break
if si is None:
    lines.append("services:")
    si = len(lines) - 1

def service_line(svc):
    for i in range(si + 1, len(lines)):
        if lines[i].strip() and not lines[i].startswith(" "):
            break
        if lines[i].rstrip() == "  %s:" % svc:
            return i
    return None

def block_end(start):
    for i in range(start + 1, len(lines)):
        if lines[i].strip() and not lines[i].startswith("    "):
            return i
    return len(lines)

changed = False
for svc in services:
    idx = service_line(svc)
    if idx is None:
        end = block_end(si)
        lines[end:end] = ["  %s:" % svc] + BLOCK
        changed = True
        continue

    body = lines[idx + 1:block_end(idx)]
    if any(l.strip().startswith("dns:") for l in body):
        if not any("127.0.0.1" in l for l in body):
            sys.stderr.write("  %s: в override уже задан чужой dns — "
                             "проверьте вручную\n" % svc)
            sys.exit(2)
        continue
    lines[idx + 1:idx + 1] = BLOCK
    changed = True

if changed:
    io.open(path, "w", encoding="utf-8").write("\n".join(lines))
    print("изменён" if existed else "создан")
else:
    print("уже настроен")
PY
  then
    echo "  $dir: override не тронут" >&2
    rc=1
    continue
  fi

  # shellcheck disable=SC2086
  docker compose -f "$dir/docker-compose.yml" up -d --force-recreate $services >/dev/null 2>&1 \
    || { echo "  $dir: не удалось пересоздать стек" >&2; rc=1; continue; }
done

sleep 2

# Проверяем по факту и только тех, кого чинили
for name in $targets; do
  if docker exec "$name" cat /etc/resolv.conf 2>/dev/null | grep -q '127.0.0.1'; then
    echo "  $name: резолвит через AGH"
  else
    echo "  $name: резолвит МИМО AGH — клиенты не фильтруются" >&2
    rc=1
  fi
done

exit $rc
