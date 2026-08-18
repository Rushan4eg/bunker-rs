#!/bin/sh
# Тесты переключателя наборов правил.
#
# Проверяем именно развилку, а не реализации: обе они покрыты своими
# тестами. Поэтому функции нижних слоёв подменены заглушками, которые
# записывают, что их позвали и с чем. Так видно, что при sing-box идёт
# .srs-ветка и не трогается clash-ветка, и наоборот.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
: >"$CALLS"

# --- окружение --------------------------------------------------------------

SRS_MAIN_URL="https://example.invalid/releases"
SB_FAKEIP_DNS_RULE_TAG="fakeip-dns-rule-tag"

UCI_CORE_FILE="$TMP/uci_core"
: >"$UCI_CORE_FILE"
uci() {
	case "$*" in
	*podkop.settings.core*) cat "$UCI_CORE_FILE" ;;
	*) return 1 ;;
	esac
}
set_core() { printf '%s' "$1" >"$UCI_CORE_FILE"; }

. "$(dirname "$0")/../podkop/files/usr/lib/core.sh"

# --- заглушки нижних слоёв --------------------------------------------------

log_call() { printf '%s\n' "$1" >>"$CALLS"; }

clash_rs_list_url() {
	log_call "clash_rs_list_url $1 $2"
	case "$1" in
	нетакого) return 1 ;;
	esac
	printf 'https://example.invalid/raw/%s/%s.lst' "$2" "$1"
}
clash_rs_provider_name() { printf '%s-%s-provider' "$1" "$2"; }
clash_rs_prepare_community_list() {
	log_call "clash_rs_prepare_community_list сервис=$1 вид=$2 каталог=$3"
	case "$1" in
	нетакого) return 1 ;;
	esac
	printf '{"type":"file","behavior":"domain","format":"yaml","path":"%s/%s-domains.lst"}' "$3" "$1"
}
clash_rs_interval_to_seconds() {
	case "$1" in
	1d) printf '86400' ;;
	1h) printf '3600' ;;
	*) printf '86400' ;;
	esac
}
# Сигнатура повторяет НАСТОЯЩУЮ у менеджера: name, behavior, format, url,
# path, interval. Прежняя заглушка читала интервал шестым аргументом - то
# есть повторяла ошибку вызывающего кода, и тест её не ловил. Заглушка
# должна следовать контракту, а не реализации.
clash_cm_add_raw_rule_provider() {
	log_call "clash_cm_add_raw_rule_provider имя=$2 описание=$3"
	printf '%s' "$1"
}
clash_cm_add_ruleset_rule() {
	log_call "clash_cm_add_ruleset_rule набор=$2 цель=$3"
	printf '%s' "$1"
}
sing_box_cm_add_remote_ruleset() {
	log_call "sing_box_cm_add_remote_ruleset тег=$2 формат=$3 url=$4 detour=$5 интервал=$6"
	printf '%s' "$1"
}
sing_box_cm_patch_route_rule() {
	log_call "sing_box_cm_patch_route_rule правило=$2 ключ=$3 значение=$4"
	printf '%s' "$1"
}
sing_box_cm_patch_dns_route_rule() {
	log_call "sing_box_cm_patch_dns_route_rule правило=$2 ключ=$3 значение=$4"
	printf '%s' "$1"
}

. "$(dirname "$0")/../podkop/files/usr/lib/ruleset_dispatch.sh"

reset_calls() { : >"$CALLS"; }
calls() { cat "$CALLS"; }

# ============================ формат ========================================

it "у sing-box формат наборов - srs"
set_core "sing-box"
assert_eq "srs" "$(ruleset_format)"

it "у clash-rs формат наборов - текстовый"
set_core "clash-rs"
assert_eq "text" "$(ruleset_format)"

it "ядро по умолчанию оставляет srs"
set_core ""
assert_eq "srs" "$(ruleset_format)"

# ============================ ссылки ========================================

it "sing-box берёт бинарник из релизов"
set_core "sing-box"
assert_eq "https://example.invalid/releases/telegram.srs" "$(ruleset_community_url telegram)"

it "clash-rs берёт текстовый список доменов"
set_core "clash-rs"
assert_eq "https://example.invalid/raw/domains/telegram.lst" "$(ruleset_community_url telegram domains)"

it "clash-rs берёт текстовый список подсетей, когда просят подсети"
set_core "clash-rs"
assert_eq "https://example.invalid/raw/subnets/telegram.lst" "$(ruleset_community_url telegram subnets)"

it "sing-box игнорирует вид списка - у него один файл на сервис"
set_core "sing-box"
assert_eq "https://example.invalid/releases/telegram.srs" "$(ruleset_community_url telegram subnets)"

it "отсутствующий текстовый список даёт ошибку, а не битую ссылку"
set_core "clash-rs"
ruleset_community_url нетакого domains >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

it "у sing-box того же сервиса ссылка всё равно собирается"
set_core "sing-box"
assert_eq "https://example.invalid/releases/нетакого.srs" "$(ruleset_community_url нетакого)"

# ============================ ветка sing-box ================================

it "sing-box: добавляется удалённый набор"
set_core "sing-box"
reset_calls
ruleset_add_community '{}' telegram "rule-1" "1d" "direct-out" >/dev/null
assert_contains "sing_box_cm_add_remote_ruleset тег=telegram формат=binary" "$(calls)"

it "sing-box: набор прописывается в правило маршрута"
set_core "sing-box"
reset_calls
ruleset_add_community '{}' telegram "rule-1" "1d" "direct-out" >/dev/null
assert_contains "sing_box_cm_patch_route_rule правило=rule-1 ключ=rule_set значение=telegram" "$(calls)"

it "sing-box: набор дублируется в правило fakeip, иначе домены не попадут в поддельные адреса"
set_core "sing-box"
reset_calls
ruleset_add_community '{}' telegram "rule-1" "1d" "direct-out" >/dev/null
assert_contains "sing_box_cm_patch_dns_route_rule правило=fakeip-dns-rule-tag" "$(calls)"

it "sing-box: выход для скачивания передаётся дальше"
set_core "sing-box"
reset_calls
ruleset_add_community '{}' telegram "rule-1" "1d" "VLESS-out" >/dev/null
assert_contains "detour=VLESS-out" "$(calls)"

it "sing-box: clash-ветка не трогается"
set_core "sing-box"
reset_calls
ruleset_add_community '{}' telegram "rule-1" "1d" "direct-out" >/dev/null
assert_not_contains "clash_cm_" "$(calls)"

# ============================ ветка clash-rs ================================

it "clash-rs: заводится провайдер правил"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_contains "clash_cm_add_raw_rule_provider имя=community-telegram-provider" "$(calls)"

# Ключевое: список готовится нами, а не отдаётся ядру сырой ссылкой. В
# списках itdoginfo домены голые, а у Clash голый домен в behavior=domain -
# точное совпадение, тогда как sing-box матчил суффиксом. Отдай мы сырое -
# "www.4pda.to" молча перестал бы попадать в туннель.
it "clash-rs: список готовится через prepare, а не отдаётся ядру ссылкой"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_contains "clash_rs_prepare_community_list сервис=telegram вид=domains" "$(calls)"

it "clash-rs: готовится в каталог активного ядра"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_contains "каталог=/tmp/clash-rs/rulesets" "$(calls)"

it "clash-rs: провайдер уходит типом file, а не http на сырой список"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_contains '"type":"file"' "$(calls)"

it "clash-rs: добавляется правило со ссылкой на набор"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_contains "clash_cm_add_ruleset_rule набор=community-telegram-provider цель=main" "$(calls)"

it "clash-rs: правило DNS не дублируется - fake-ip работает поверх всех правил"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_not_contains "dns_route_rule" "$(calls)"

it "clash-rs: sing-box-ветка не трогается"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' telegram "main" "1d" "" >/dev/null
assert_not_contains "sing_box_cm_" "$(calls)"

it "clash-rs: отсутствующий список не создаёт ни провайдера, ни правила"
set_core "clash-rs"
reset_calls
ruleset_add_community '{}' нетакого "main" "1d" "" >/dev/null 2>&1
assert_not_contains "clash_cm_add_ruleset_rule" "$(calls)"

it "clash-rs: отсутствующий список возвращает ошибку"
set_core "clash-rs"
ruleset_add_community '{}' нетакого "main" "1d" "" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

# ============================ каталоги ======================================

it "каталог наборов у sing-box свой"
set_core "sing-box"
assert_eq "/tmp/sing-box/rulesets" "$(ruleset_folder)"

it "каталог наборов у clash-rs свой, чтобы форматы не смешались"
set_core "clash-rs"
assert_eq "/tmp/clash-rs/rulesets" "$(ruleset_folder)"

# ============================ конфиг проходит насквозь ======================

it "конфиг возвращается, а не теряется"
set_core "clash-rs"
assert_eq '{"proxies":[]}' "$(ruleset_add_community '{"proxies":[]}' telegram "main" "1d" "")"

finish
