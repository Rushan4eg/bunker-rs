#!/bin/sh
# Харнесс для юнит-тестов shell-модулей подкопа.
#
# Модули устроены как чистые преобразования: на входе конфиг строкой, на
# выходе он же изменённый. Роутер для проверки не нужен вовсе - достаточно
# jq и сравнения JSON, поэтому всё гоняется локально и в CI.
#
# Сравниваем не текст, а разобранный JSON: порядок ключей в выводе jq не
# гарантирован, и построчный diff ловил бы несуществующие отличия.
#
# shellcheck shell=sh

# Портативный jq для Windows кладём куда угодно и указываем через JQ=
JQ="${JQ:-jq}"

TESTS_RUN=0
TESTS_FAILED=0
CURRENT_TEST=""

# --- вывод ------------------------------------------------------------------

if [ -t 1 ] && [ -z "$NO_COLOR" ]; then
	C_OK=$(printf '\033[32m')
	C_BAD=$(printf '\033[31m')
	C_DIM=$(printf '\033[2m')
	C_OFF=$(printf '\033[0m')
else
	C_OK="" C_BAD="" C_DIM="" C_OFF=""
fi

_pass() { printf '  %sOK%s   %s\n' "$C_OK" "$C_OFF" "$1"; }

_fail() {
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$C_BAD" "$C_OFF" "$1"
	shift
	for line in "$@"; do
		printf '       %s%s%s\n' "$C_DIM" "$line" "$C_OFF"
	done
}

# --- объявление теста -------------------------------------------------------

it() {
	CURRENT_TEST="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
}

# --- проверки ---------------------------------------------------------------

# assert_eq <ожидаемое> <полученное>
assert_eq() {
	if [ "$1" = "$2" ]; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "ожидалось: $1" "получено:  $2"
	fi
}

# assert_ne <не должно быть> <полученное>
assert_ne() {
	if [ "$1" != "$2" ]; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "не должно было быть: $1"
	fi
}

# assert_contains <подстрока> <строка>
assert_contains() {
	case "$2" in
	*"$1"*) _pass "$CURRENT_TEST" ;;
	*) _fail "$CURRENT_TEST" "не найдено: $1" "в строке:   $(_clip "$2")" ;;
	esac
}

# assert_not_contains <подстрока> <строка>
assert_not_contains() {
	case "$2" in
	*"$1"*) _fail "$CURRENT_TEST" "не должно было встретиться: $1" ;;
	*) _pass "$CURRENT_TEST" ;;
	esac
}

# assert_json_eq <ожидаемый JSON> <полученный JSON>
# Сравнение по смыслу: ключи сортируются, пробелы не важны.
assert_json_eq() {
	local want got
	want=$(_strip_cr "$(printf '%s' "$1" | "$JQ" -S . 2>/dev/null)")
	got=$(_strip_cr "$(printf '%s' "$2" | "$JQ" -S . 2>/dev/null)")

	if [ -z "$got" ]; then
		_fail "$CURRENT_TEST" "результат не разобрался как JSON" "получено: $(_clip "$2")"
		return
	fi
	if [ "$want" = "$got" ]; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "ожидалось: $(printf '%s' "$want" | tr -d '\n' | tr -s ' ')" \
			"получено:  $(printf '%s' "$got" | tr -d '\n' | tr -s ' ')"
	fi
}

# assert_jq <фильтр> <ожидаемое> <JSON>
# Достаёт из JSON кусок фильтром и сравнивает. Основной способ проверки:
# читается как утверждение о конфиге, а не как сравнение двух простыней.
assert_jq() {
	local filter="$1" want="$2" json="$3" got
	got=$(_strip_cr "$(printf '%s' "$json" | "$JQ" -r "$filter" 2>&1)")
	if [ "$got" = "$want" ]; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "фильтр:    $filter" "ожидалось: $want" "получено:  $got"
	fi
}

# assert_valid_json <JSON>
assert_valid_json() {
	if printf '%s' "$1" | "$JQ" -e . >/dev/null 2>&1; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "невалидный JSON" "получено: $(_clip "$1")"
	fi
}

# --- служебное --------------------------------------------------------------

# Срезает возврат каретки.
#
# Под Windows нативный jq.exe отдаёт вывод с \r на конце, и разные оболочки
# обходятся с ним по-разному: bash из состава Git его проглатывает, dash -
# нет. Из-за этого один и тот же тест был зелёным под bash и красным под
# dash, причём в отчёте обе строки выглядели одинаково - разница только в
# невидимом байте. Харнесс, который врёт в зависимости от оболочки, хуже
# отсутствующего, поэтому чистим на входе всех сравнений.
#
# На линуксе (CI и роутер) \r не появляется вовсе, так что это чистая
# страховка, а не подгонка результата.
#
# Проверка через case, а не безусловный вызов tr: на каждую проверку
# приходится по два сравнения, а внешний процесс под Windows стоит десятки
# миллисекунд. При двух с половиной сотнях тестов безусловный tr добавлял
# к прогону больше, чем сами тесты.
CR=$(printf '\r')

_strip_cr() {
	case "$1" in
	*"$CR"*) printf '%s' "$1" | tr -d '\r' ;;
	*) printf '%s' "$1" ;;
	esac
}

_clip() {
	if [ "${#1}" -gt 160 ]; then
		printf '%s...' "$(printf '%s' "$1" | cut -c1-160)"
	else
		printf '%s' "$1"
	fi
}

# Пустой конфиг Clash - отправная точка почти каждого теста
clash_empty_config() {
	printf '%s' '{"proxies":[],"proxy-groups":[],"rules":[],"rule-providers":{}}'
}

finish() {
	printf '\n'
	if [ "$TESTS_FAILED" -eq 0 ]; then
		printf '%sвсе %d проверок прошли%s\n' "$C_OK" "$TESTS_RUN" "$C_OFF"
		exit 0
	fi
	printf '%sпровалено %d из %d%s\n' "$C_BAD" "$TESTS_FAILED" "$TESTS_RUN" "$C_OFF"
	exit 1
}
