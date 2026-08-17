#!/bin/sh
# Прогоняет все тесты из tests/*_test.sh.
#
#   sh tests/run.sh                 все
#   sh tests/run.sh manager         только те, чьё имя содержит manager
#   JQ=/path/to/jq.exe sh tests/run.sh    свой jq (Windows)
#
# shellcheck shell=sh
set -e

DIR=$(cd "$(dirname "$0")" && pwd)
FILTER="${1:-}"
JQ="${JQ:-jq}"
export JQ

if ! "$JQ" --version >/dev/null 2>&1; then
	echo "jq не найден. Укажи путь: JQ=/путь/к/jq sh tests/run.sh" >&2
	exit 2
fi

total_failed=0
total_files=0

for f in "$DIR"/*_test.sh; do
	[ -f "$f" ] || continue
	name=$(basename "$f" _test.sh)
	if [ -n "$FILTER" ]; then
		case "$name" in
		*"$FILTER"*) ;;
		*) continue ;;
		esac
	fi

	total_files=$((total_files + 1))
	printf '\n%s\n' "$name"

	# Каждый файл в своей оболочке: переменные и функции одного теста
	# не должны протекать в следующий.
	if ! sh "$f"; then
		total_failed=$((total_failed + 1))
	fi
done

if [ "$total_files" -eq 0 ]; then
	echo "тестов не найдено${FILTER:+ по фильтру '$FILTER'}" >&2
	exit 2
fi

printf '\n────────────────────────\n'
if [ "$total_failed" -eq 0 ]; then
	printf 'файлов: %d, все прошли\n' "$total_files"
	exit 0
fi
printf 'файлов: %d, провалено: %d\n' "$total_files" "$total_failed"
exit 1
