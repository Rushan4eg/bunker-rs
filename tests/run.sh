#!/bin/sh
# Прогоняет все тесты из tests/*_test.sh.
#
#   sh tests/run.sh                 все
#   sh tests/run.sh manager         только те, чьё имя содержит manager
#   JQ=/path/to/jq.exe sh tests/run.sh    свой jq (Windows)
#
# shellcheck shell=sh
set -e

# Windows: слой MSYS переписывает аргументы, похожие на пути, когда shell
# зовёт нативную программу - "/dns-query" превращается в
# "C:/Program Files/Git/dns-query", и проверки путей внутри конфига врут.
#
# Отключается это переменными, но читает их MSYS при ЗАПУСКЕ процесса, а не
# при каждом вызове дочерней программы. Поэтому обычный export внутри скрипта
# уже поздно - надо перезапустить себя, чтобы переменные были в окружении с
# самого начала. Делаем это один раз и только под Windows; на линуксе, где
# гоняется CI и живёт роутер, ветка не выполняется вовсе.
if [ -z "$PODKOP_TESTS_REEXEC" ] && [ -n "$WINDIR" ]; then
	PODKOP_TESTS_REEXEC=1
	MSYS_NO_PATHCONV=1
	MSYS2_ARG_CONV_EXCL='*'
	export PODKOP_TESTS_REEXEC MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL
	exec "${PODKOP_TESTS_SHELL:-sh}" "$0" "$@"
fi

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
