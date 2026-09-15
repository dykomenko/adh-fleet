#!/usr/bin/env bash
#
# Собирает личную копию гайда из обезличенной. Запускается НА РАБОЧЕЙ МАШИНЕ.
#
#   ./scripts/make-personal-guide.sh
#
# Источник правды — docs/guide.html в репозитории, там плейсхолдеры.
# Результат — ../guide/agh-runbook.html с подставленными ключами из ../.env,
# за пределами рабочего дерева git. Делиться можно только исходником.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/docs/guide.html"
OUT_DIR="$(cd "$ROOT/.." && pwd)/guide"
OUT="$OUT_DIR/agh-runbook.html"

[[ -f "$SRC" ]] || { echo "нет $SRC" >&2; exit 1; }

for env in "$ROOT/../.env" "$ROOT/.env"; do
  [[ -f "$env" ]] && { set -a; . "$env"; set +a; break; }
done
: "${NB_KEY_ORIGIN:?не задан NB_KEY_ORIGIN в .env}"
: "${NB_KEY_REPLICA:?не задан NB_KEY_REPLICA в .env}"

# Пока хеша нет, в команду попадает заполнитель. Он намеренно сделан
# непохожим на значение и в угловых скобках: прежняя версия подставляла
# «ХЕШ-ИЗ-ШАГА-5», это выглядело как настоящее значение, было скопировано
# в продакшен и дало ноду с нерабочей учёткой.
if [[ -n "${AGH_PASS_HASH:-}" ]]; then
  HASH_SHOWN="$AGH_PASS_HASH"
else
  HASH_SHOWN='<СНАЧАЛА-ВЫПОЛНИТЕ-ШАГ-5-И-ЗАПОЛНИТЕ-AGH_PASS_HASH-В-ENV>'
  echo "ВНИМАНИЕ: AGH_PASS_HASH в .env пуст." >&2
  echo "В команду установки реплики попадёт заполнитель, а не хеш." >&2
  echo "После шага 5 заполните .env и пересоберите гайд." >&2
fi

mkdir -p "$OUT_DIR"

# Подставляем по минимальному якорю, а не по строке целиком: текст команд
# вокруг правится часто, и длинный шаблон молча переставал совпадать.
sed -e "s|<title>AdGuard Home на каждой ноде</title>|<title>AdGuard Home на каждой ноде — личная копия</title>|" \
    -e "s|--setup-key \&lt;КЛЮЧ\&gt;|--setup-key ${NB_KEY_ORIGIN}|g" \
    -e "s|--setup-key \"\$NB_KEY_ORIGIN\"|--setup-key ${NB_KEY_ORIGIN}|g" \
    -e "s|NB_KEY_REPLICA='\.\.\.'|NB_KEY_REPLICA='${NB_KEY_REPLICA}'|g" \
    -e "s|AGH_PASS_HASH='\.\.\.'|AGH_PASS_HASH='${HASH_SHOWN}'|g" \
    "$SRC" > "$OUT.tmp"

# Баннер сразу после шапки — чтобы копию нельзя было спутать с исходником
BANNER=$(cat <<'HTML'
    <div class="note warn" style="margin-top:20px">
      <span class="note-label">Личная копия — не передавать</span>
      <p>В командах ниже подставлены рабочие setup key вашего аккаунта Netbird. Файл лежит за пределами репозитория намеренно: обезличенная версия с плейсхолдерами — в <code class="inl">adh-fleet/docs/guide.html</code>, делиться можно только ей.</p>
    </div>
HTML
)
printf '%s\n' "$BANNER" > "$OUT.banner"
sed '/<\/header>/r '"$OUT.banner" "$OUT.tmp" > "$OUT"
rm -f "$OUT.tmp" "$OUT.banner"

subs=$(grep -c "$NB_KEY_ORIGIN\|$NB_KEY_REPLICA" "$OUT" || true)
(( subs >= 2 )) || { echo "ключи не подставились — проверьте плейсхолдеры в $SRC" >&2; exit 1; }

echo "личная копия: $OUT"
echo "подстановок ключей: $subs"
