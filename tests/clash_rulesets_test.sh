#!/bin/sh
# Тесты списков правил для clash-rs.
#
# Сеть здесь не трогается вообще: разбор проверяется на фикстурах из
# tests/fixtures, а скачивание - на подменённом _clash_rs_fetch. Иначе тесты
# зависели бы от доступности raw.githubusercontent.com, который как раз и
# отдаёт 429 при частых запросах - ради этого ретраи и переписаны.
#
# shellcheck shell=sh
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

DIR=$(cd "$(dirname "$0")" && pwd)
FIX="$DIR/fixtures"
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=/dev/null
. "$DIR/../podkop/files/usr/lib/clash_rulesets.sh"

CR=$(printf '\r')

# Число строк в строке-результате
count_lines() {
	[ -n "$1" ] || {
		echo 0
		return 0
	}
	printf '%s\n' "$1" | grep -c ''
}

# Файл нулевого размера - отдельный случай от «файла из одних комментариев»
ZERO="$TMP/zero.lst"
: >"$ZERO"

# ============================ чистка ========================================

it "комментарии и пустые строки выброшены"
out=$(clash_rs_clean_list "$FIX/domains.lst")
assert_eq "7" "$(count_lines "$out")"

it "строка комментария не попадает в результат"
assert_not_contains "#" "$out"

it "хвостовой комментарий // срезан"
assert_not_contains "хвост" "$out"

it "домен перед хвостовым комментарием остался"
assert_contains "youtube.com" "$out"

it "пробелы по краям срезаны"
assert_contains "
spaced.example.com
" "
$out
"

it "CRLF не доезжает до результата"
crlf_out=$(clash_rs_clean_list "$FIX/crlf.lst")
assert_not_contains "$CR" "$crlf_out"

it "из CRLF-файла остаются только записи"
assert_eq "example.com
.crlf.example" "$crlf_out"

it "файл из одних комментариев чистится в пустоту"
assert_eq "" "$(clash_rs_clean_list "$FIX/empty.lst")"

it "файл нулевого размера чистится в пустоту"
assert_eq "" "$(clash_rs_clean_list "$ZERO")"

it "несуществующий файл - ошибка"
clash_rs_clean_list "$TMP/no-such-file.lst" >/dev/null 2>&1
assert_eq "1" "$?"

# ============================ behavior ======================================

it "список из одних подсетей - ipcidr"
assert_eq "ipcidr" "$(clash_rs_detect_behavior "$FIX/subnets.lst")"

it "битый адрес не превращает список подсетей в смешанный"
# 999.1.1.1 похож на домен по форме, но последняя метка числовая
assert_eq "ipcidr" "$(clash_rs_detect_behavior "$FIX/subnets.lst")"

it "список из одних доменов - domain"
assert_eq "domain" "$(clash_rs_detect_behavior "$FIX/domains.lst")"

it "смешанный список - classical"
assert_eq "classical" "$(clash_rs_detect_behavior "$FIX/mixed.lst")"

it "готовые правила DOMAIN-SUFFIX - classical"
assert_eq "classical" "$(clash_rs_detect_behavior "$FIX/classical.lst")"

it "CRLF не мешает определить behavior"
assert_eq "domain" "$(clash_rs_detect_behavior "$FIX/crlf.lst")"

it "по файлу из одних комментариев behavior не определяется"
assert_eq "" "$(clash_rs_detect_behavior "$FIX/empty.lst")"

it "файл из одних комментариев - ненулевой код возврата"
clash_rs_detect_behavior "$FIX/empty.lst" >/dev/null
assert_eq "1" "$?"

it "файл нулевого размера - ненулевой код возврата"
clash_rs_detect_behavior "$ZERO" >/dev/null
assert_eq "1" "$?"

# ============================ payload: домены ===============================

it "домен получает +. - суффиксное совпадение как у sing-box"
out=$(clash_rs_build_payload "$FIX/domains.lst" domain text)
assert_contains "+.habr.com" "$out"

it "ведущая точка превращается в +."
assert_contains "+.ua" "$out"

it "маска *. сохраняется как есть"
assert_contains "*.wildcard.example" "$out"

it "домен с числовой первой меткой не теряется"
assert_contains "+.24.kg" "$out"

it "в payload доменов ровно семь записей"
assert_eq "7" "$(count_lines "$out")"

it "подсети из смешанного списка в behavior domain выброшены"
out=$(clash_rs_build_payload "$FIX/mixed.lst" domain text)
assert_eq "+.telegram.org
+.t.me" "$out"

# ============================ payload: подсети ==============================

it "подсеть с маской переносится как есть"
out=$(clash_rs_build_payload "$FIX/subnets.lst" ipcidr text)
assert_contains "91.108.4.0/22" "$out"

it "голый адрес получает маску /32"
assert_contains "1.2.3.4/32" "$out"

it "битая строка в payload не попадает"
assert_not_contains "999.1.1.1" "$out"

it "в payload подсетей ровно четыре записи"
assert_eq "4" "$(count_lines "$out")"

it "домены из смешанного списка в behavior ipcidr выброшены"
out=$(clash_rs_build_payload "$FIX/mixed.lst" ipcidr text)
assert_eq "149.154.160.0/20
91.108.4.0/22" "$out"

# ============================ payload: classical ============================

it "смешанный список раскладывается по типам правил"
out=$(clash_rs_build_payload "$FIX/mixed.lst" classical text)
assert_eq "DOMAIN-SUFFIX,telegram.org
IP-CIDR,149.154.160.0/20
DOMAIN-SUFFIX,t.me
IP-CIDR,91.108.4.0/22" "$out"

it "готовое правило DOMAIN остаётся точным, а не суффиксным"
out=$(clash_rs_build_payload "$FIX/classical.lst" classical text)
assert_contains "DOMAIN,exact.example.com" "$out"

it "цель правила отрезается: в payload её быть не должно"
assert_not_contains "PROXY" "$out"

it "ведущая точка в готовом правиле убирается"
assert_contains "DOMAIN-SUFFIX,ua" "$out"

it "DOMAIN-KEYWORD в classical сохраняется"
assert_contains "DOMAIN-KEYWORD,rutracker" "$out"

it "DOMAIN-KEYWORD в behavior domain выражается нечем и выбрасывается"
out=$(clash_rs_build_payload "$FIX/classical.lst" domain text)
assert_not_contains "rutracker" "$out"

it "DOMAIN из готового правила в behavior domain остаётся без +."
assert_contains "
exact.example.com
" "
$out
"

# ============================ payload: форматы ==============================

it "yaml начинается с ключа payload"
out=$(clash_rs_build_payload "$FIX/subnets.lst" ipcidr yaml)
assert_eq "payload:" "$(printf '%s\n' "$out" | head -n1)"

it "записи yaml идут списком в одинарных кавычках"
assert_contains "  - '1.2.3.4/32'" "$out"

it "формат по умолчанию - yaml"
assert_contains "payload:" "$(clash_rs_build_payload "$FIX/subnets.lst" ipcidr)"

it "неизвестный формат - код возврата 2"
clash_rs_build_payload "$FIX/subnets.lst" ipcidr srs >/dev/null 2>&1
assert_eq "2" "$?"

it "неизвестный behavior - код возврата 3"
clash_rs_build_payload "$FIX/subnets.lst" nonsense text >/dev/null 2>&1
assert_eq "3" "$?"

it "payload из файла без записей - код возврата 1"
clash_rs_build_payload "$FIX/empty.lst" domain text >/dev/null 2>&1
assert_eq "1" "$?"

it "payload из файла нулевого размера - код возврата 1"
clash_rs_build_payload "$ZERO" domain text >/dev/null 2>&1
assert_eq "1" "$?"

# ============================ конвертация целиком ===========================

it "convert печатает определённый behavior"
assert_eq "ipcidr" "$(clash_rs_convert_list "$FIX/subnets.lst" "$TMP/subnets.payload" text)"

it "convert пишет payload в файл"
assert_eq "91.108.4.0/22
149.154.160.0/20
1.2.3.4/32
5.6.7.0/24" "$(cat "$TMP/subnets.payload")"

it "convert из CRLF-файла оставляет файл без CR"
clash_rs_convert_list "$FIX/crlf.lst" "$TMP/crlf.payload" text >/dev/null
assert_not_contains "$CR" "$(cat "$TMP/crlf.payload")"

it "convert с явным behavior не спорит с содержимым"
assert_eq "classical" "$(clash_rs_convert_list "$FIX/domains.lst" "$TMP/forced.payload" text classical)"

it "явно заданный behavior применяется к payload"
assert_contains "DOMAIN-SUFFIX,habr.com" "$(cat "$TMP/forced.payload")"

it "convert пустого списка - код возврата 1"
clash_rs_convert_list "$FIX/empty.lst" "$TMP/empty.payload" text >/dev/null 2>&1
assert_eq "1" "$?"

it "после неудачной конвертации файла payload не остаётся"
assert_eq "нет" "$([ -f "$TMP/empty.payload" ] && echo "есть" || echo "нет")"

# ============================ адреса списков ================================

it "домены сервиса берутся из Services"
assert_eq "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Services/telegram.lst" \
	"$(clash_rs_list_url telegram domains)"

it "подсети сервиса берутся из Subnets/IPv4"
assert_eq "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Subnets/IPv4/telegram.lst" \
	"$(clash_rs_list_url telegram subnets)"

it "страновой список лежит отдельным файлом"
assert_eq "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst" \
	"$(clash_rs_list_url russia_inside)"

it "категория берётся из Categories"
assert_eq "https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Categories/geoblock.lst" \
	"$(clash_rs_list_url geoblock domains)"

it "тип списка по умолчанию - домены"
assert_eq "$(clash_rs_list_url youtube domains)" "$(clash_rs_list_url youtube)"

it "неизвестный сервис - ошибка"
clash_rs_list_url nosuchservice domains >/dev/null 2>&1
assert_eq "1" "$?"

it "у roblox нет списка IPv6 - ошибка, а не битый URL"
clash_rs_list_url roblox subnets6 >/dev/null 2>&1
assert_eq "1" "$?"

# ============================ интервал ======================================

it "1d - это сутки"
assert_eq "86400" "$(clash_rs_interval_to_seconds 1d)"

it "12h - это полсуток"
assert_eq "43200" "$(clash_rs_interval_to_seconds 12h)"

it "30m - это полчаса"
assert_eq "1800" "$(clash_rs_interval_to_seconds 30m)"

it "голое число считается секундами"
assert_eq "3600" "$(clash_rs_interval_to_seconds 3600)"

it "мусор в интервале - ошибка"
clash_rs_interval_to_seconds "1y" >/dev/null 2>&1
assert_eq "1" "$?"

# ============================ описание провайдеров ==========================

it "провайдер из файла описан типом file"
provider=$(clash_rs_file_provider_json domain yaml /tmp/clash-rs/rulesets/telegram-domains.lst)
assert_jq '.type' "file" "$provider"

it "у провайдера из файла есть behavior"
assert_jq '.behavior' "domain" "$provider"

it "у провайдера из файла есть путь"
# сравнение хвостом, а не целиком: на Windows msys переписывает /tmp/... в
# C:/... при передаче аргумента в родной jq.exe, к модулю это отношения не имеет
assert_jq '.path | endswith("/rulesets/telegram-domains.lst")' "true" "$provider"

it "провайдер по http описан типом http"
provider=$(clash_rs_http_provider_json ipcidr text https://example.test/x.lst /tmp/x.lst 1d)
assert_jq '.type' "http" "$provider"

it "интервал провайдера - число секунд, а не строка"
assert_jq '.interval' "86400" "$provider"

it "формат провайдера передаётся как есть"
assert_jq '.format' "text" "$provider"

it "имя провайдера собирается из секции, имени и типа"
assert_eq "main-telegram-community-provider" "$(clash_rs_provider_name main telegram community)"

it "без типа имя провайдера короче"
assert_eq "main-telegram-provider" "$(clash_rs_provider_name main telegram)"

# ============================ ретраи скачивания =============================
# Сеть не трогаем: подменяем одну попытку скачивания и паузу.

FETCH_LOG="$TMP/fetch.log"
SLEEP_LOG="$TMP/sleep.log"
FETCH_MODE="fail"

_clash_rs_sleep() { printf '%s\n' "$1" >>"$SLEEP_LOG"; }
_clash_rs_jitter() { echo 0; }

# заглушки зовёт модуль, а не сам тест
# shellcheck disable=SC2329
_clash_rs_fetch() {
	printf '%s\n' "$1" >>"$FETCH_LOG"
	case "$FETCH_MODE" in
	ok)
		printf 'data\n' >"$2"
		return 0
		;;
	second-ok)
		if [ "$(count_attempts)" -ge 2 ]; then
			printf 'data\n' >"$2"
			return 0
		fi
		return 1
		;;
	ratelimit) return 2 ;;
	empty)
		: >"$2"
		return 0
		;;
	*) return 1 ;;
	esac
}

count_attempts() { grep -c '' <"$FETCH_LOG"; }

run_download() {
	FETCH_MODE="$1"
	: >"$FETCH_LOG"
	: >"$SLEEP_LOG"
	clash_rs_download_list "https://example.test/x.lst" "$TMP/dl.lst" "" "${2:-4}"
}

it "успешное скачивание с первой попытки"
run_download ok
assert_eq "0" "$?"

it "при успехе пауз нет"
assert_eq "" "$(cat "$SLEEP_LOG")"

it "успех со второй попытки - результат успешный"
run_download second-ok
assert_eq "0" "$?"

it "успех со второй попытки - ровно одна пауза"
assert_eq "1" "$(count_lines "$(cat "$SLEEP_LOG")")"

it "все попытки провалены - ошибка"
run_download fail 4
assert_eq "1" "$?"

it "попыток ровно столько, сколько заказано"
assert_eq "4" "$(count_attempts)"

it "пауза удваивается, а не остаётся прежней"
# ради этого всё и затевалось: три попытки подряд по 2 секунды попадают
# в одно окно лимита и смысла не имеют
assert_eq "5
10
20" "$(cat "$SLEEP_LOG")"

it "на 429 первая пауза заведомо больше окна лимита"
run_download ratelimit 3
assert_eq "30
60" "$(cat "$SLEEP_LOG")"

it "429 после всех попыток - ошибка"
run_download ratelimit 2
assert_eq "1" "$?"

it "пустой ответ считается неудачей"
run_download empty 2
assert_eq "1" "$?"

it "число попыток берётся из настройки, если не задано аргументом"
CLASH_RS_DOWNLOAD_RETRIES=2
FETCH_MODE="fail"
: >"$FETCH_LOG"
: >"$SLEEP_LOG"
clash_rs_download_list "https://example.test/x.lst" "$TMP/dl.lst"
assert_eq "2" "$(count_attempts)"

# ============================ подготовка целиком ============================

it "подготовка списка сообщества выдаёт описание провайдера"
# переменную читает модуль
# shellcheck disable=SC2034
CLASH_RS_DOWNLOAD_RETRIES=1
# shellcheck disable=SC2329
_clash_rs_fetch() {
	cp "$FIX/subnets.lst" "$2"
	return 0
}
provider=$(clash_rs_prepare_community_list telegram subnets "$TMP/rulesets" text)
assert_jq '.behavior' "ipcidr" "$provider"

it "payload списка сообщества лежит в заказанном каталоге"
assert_jq '.path | endswith("/rulesets/telegram-subnets.lst")' "true" "$provider"

it "payload списка сообщества действительно записан"
assert_contains "1.2.3.4/32" "$(cat "$TMP/rulesets/telegram-subnets.lst")"

it "неизвестный сервис до скачивания не доходит"
clash_rs_prepare_community_list nosuchservice domains "$TMP/rulesets" text >/dev/null 2>&1
assert_eq "1" "$?"

it "неудачное скачивание не оставляет провайдера"
_clash_rs_fetch() { return 1; }
clash_rs_prepare_community_list telegram domains "$TMP/rulesets" text >/dev/null 2>&1
assert_eq "1" "$?"

finish
