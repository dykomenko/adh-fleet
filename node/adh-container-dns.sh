#!/usr/bin/env bash
#
# Направляет резолвер контейнеров в host-сети на AdGuard Home.
#
# Зачем: Docker при наследовании resolv.conf хоста выбрасывает loopback-адреса
# и подставляет публичные — он не знает, что у контейнера сетевой namespace
# хоста и 127.0.0.1 здесь рабочий. В итоге Xray резолвит через 8.8.8.8
# и до AGH не доходит никогда, при том что на хосте resolv.conf указывает
# на AGH, а секции dns в конфиге Xray нет. Видно только изнутри контейнера.
#
# Почему по host-сети, а не по имени папки: стек может лежать в /opt/remnanode,
# /opt/rwnode, /opt/selfsteal или где угодно ещё. Признак «сеть хоста» точен
# и не требует угадывать путь — каталог берётся из меток compose.
#
# Существующий override не перезаписывается, а дополняется: на боевых нодах
# он есть почти всегда, и затереть его значило бы потерять чужую настройку.
# Правка точечная, комментарии и остальное содержимое сохраняются.
#
#   ADH_DNS_EXCLUDE='adguardhome'   контейнеры, которые пропустить (regex)

set -uo pipefail

EXCLUDE="${ADH_DNS_EXCLUDE:-adguardhome}"

command -v docker >/dev/null || { echo "docker не найден" >&2; exit 1; }
command -v python3 >/dev/null || { echo "нужен python3 для правки override" >&2; exit 1; }

declare -A svc_by_dir
found=0

for cid in $(docker ps -q); do
  name="$(docker inspect "$cid" --format '{{.Name}}' | tr -d '/')"
  [[ "$name" =~ $EXCLUDE ]] && continue
  [[ "$(docker inspect "$cid" --format '{{.HostConfig.NetworkMode}}')" == host ]] || continue
  found=1

  dir="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}')"
  svc="$(docker inspect "$cid" --format '{{index .Config.Labels "com.docker.compose.service"}}')"

  if [[ -z "$dir" || -z "$svc" ]]; then
    echo "  $name: поднят не через compose — задайте резолвер вручную" >&2
    continue
  fi

  case " ${svc_by_dir[$dir]:-} " in
    *" $svc "*) ;;
    *) svc_by_dir["$dir"]="${svc_by_dir[$dir]:-}$svc " ;;
  esac
done

if (( found == 0 )); then
  echo "контейнеров в host-сети не найдено — настраивать нечего" >&2
  exit 0
fi

rc=0
for dir in "${!svc_by_dir[@]}"; do
  services="${svc_by_dir[$dir]}"

  if ! python3 - "$dir/docker-compose.override.yml" $services <<'PY'
import io, os, shutil, sys

path, services = sys.argv[1], sys.argv[2:]
BLOCK = ["    dns:", "      - 127.0.0.1"]

if os.path.exists(path):
    shutil.copy2(path, path + ".bak-adh")
    lines = io.open(path, encoding="utf-8").read().split("\n")
else:
    lines = ["# Дополняется скриптом adh-container-dns.sh из adh-fleet.",
             "# Резолвер контейнера направлен на AdGuard Home: Docker иначе",
             "# подставляет публичные серверы вместо loopback хоста.",
             "services:"]

def services_index(ls):
    for i, l in enumerate(ls):
        if l.rstrip() == "services:":
            return i
    return None

si = services_index(lines)
if si is None:
    lines += ["services:"]
    si = len(lines) - 1

def service_line(ls, svc):
    for i in range(si + 1, len(ls)):
        if ls[i].strip() and not ls[i].startswith(" "):
            break                      # вышли из services:
        if ls[i].rstrip() == "  %s:" % svc:
            return i
    return None

def block_end(ls, start):
    for i in range(start + 1, len(ls)):
        s = ls[i]
        if s.strip() and not s.startswith("    "):
            return i
    return len(ls)

changed = False
for svc in services:
    idx = service_line(lines, svc)
    if idx is None:
        end = block_end(lines, si) if si is not None else len(lines)
        lines[end:end] = ["  %s:" % svc] + BLOCK
        changed = True
        continue

    end = block_end(lines, idx)
    body = lines[idx + 1:end]
    if any(l.strip().startswith("dns:") for l in body):
        if not any("127.0.0.1" in l for l in body):
            sys.stderr.write("  %s: в override уже есть dns: без 127.0.0.1 — "
                             "проверьте вручную\n" % svc)
            sys.exit(2)
        continue                        # уже настроено, не трогаем
    lines[idx + 1:idx + 1] = BLOCK
    changed = True

if changed:
    io.open(path, "w", encoding="utf-8").write("\n".join(lines))
    print("изменён" if os.path.exists(path + ".bak-adh") else "создан")
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

# Проверяем по факту, а не по намерению
for cid in $(docker ps -q); do
  name="$(docker inspect "$cid" --format '{{.Name}}' | tr -d '/')"
  [[ "$name" =~ $EXCLUDE ]] && continue
  [[ "$(docker inspect "$cid" --format '{{.HostConfig.NetworkMode}}')" == host ]] || continue

  if docker exec "$cid" cat /etc/resolv.conf 2>/dev/null | grep -q '127.0.0.1'; then
    echo "  $name: резолвит через AGH"
  else
    echo "  $name: резолвит МИМО AGH — клиенты не фильтруются" >&2
    rc=1
  fi
done

exit $rc
