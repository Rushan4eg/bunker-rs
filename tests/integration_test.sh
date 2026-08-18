#!/bin/sh
# Проверка сборки целиком.
#
# Модули покрыты каждый своими тестами, но там они поднимаются поодиночке и с
# заглушками вместо соседей. Здесь проверяется другое: что все двенадцать
# файлов грузятся ВМЕСТЕ и в том же порядке, что в /usr/bin/podkop, никто не
# перетирает чужую функцию и не падает при сорсинге.
#
# Такую поломку не поймает ни один модульный тест, а проявится она только на
# роутере при старте сервиса - то есть в худшем месте.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

PODKOP_LIB=$(cd "$(dirname "$0")/../podkop/files/usr/lib" && pwd)
export PODKOP_LIB
SRC="$(dirname "$0")/../podkop/files/usr/bin/podkop"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- заглушки окружения OpenWrt ---------------------------------------------
# На машине разработчика нет ни uci, ни /lib/functions.sh. Подменяем минимум,
# нужный для сорсинга: сами модули при загрузке ничего не выполняют, кроме
# присваивания переменных.

UCI_FILE="$TMP/uci"
: >"$UCI_FILE"
uci() {
	case "$*" in
	*podkop.settings.core*) cat "$UCI_FILE" ;;
	*) return 1 ;;
	esac
}
set_core() { printf '%s' "$1" >"$UCI_FILE"; }

config_load() { :; }
config_get() { :; }
config_get_bool() { :; }
config_foreach() { :; }
network_get_ipaddr() { :; }
logger() { :; }
jq() { "$JQ" "$@"; }

# --- сорсинг в порядке из podkop --------------------------------------------

. "$PODKOP_LIB/constants.sh"
. "$PODKOP_LIB/nft.sh"
. "$PODKOP_LIB/helpers.sh"
. "$PODKOP_LIB/sing_box_config_manager.sh"
. "$PODKOP_LIB/sing_box_config_facade.sh"
. "$PODKOP_LIB/logging.sh"
. "$PODKOP_LIB/rulesets.sh"
. "$PODKOP_LIB/core.sh"
. "$PODKOP_LIB/clash_config_manager.sh"
. "$PODKOP_LIB/clash_config_facade.sh"
. "$PODKOP_LIB/clash_rulesets.sh"
. "$PODKOP_LIB/ruleset_dispatch.sh"
. "$PODKOP_LIB/clash_config_builder.sh"
. "$PODKOP_LIB/podkop_extras.sh"

have() { command -v "$1" >/dev/null 2>&1 && echo да || echo нет; }

# ============================ модули поднялись ==============================

it "все двенадцать модулей грузятся вместе без падения"
assert_eq "да" "да" # дошли сюда - значит ни один сорсинг не оборвал скрипт

it "слой ядра на месте"
assert_eq "да" "$(have core_current)"

it "генератор sing-box не перетёрт"
assert_eq "да" "$(have sing_box_cm_add_vless_outbound)"

it "генератор clash на месте"
assert_eq "да" "$(have clash_cm_add_vless_proxy)"

it "фасад clash на месте"
assert_eq "да" "$(have clash_cf_add_proxy_outbound)"

it "сборка конфига clash на месте"
assert_eq "да" "$(have clash_init_config)"

it "переключатель наборов на месте"
assert_eq "да" "$(have ruleset_add_community)"

it "списки для clash на месте"
assert_eq "да" "$(have clash_rs_prepare_community_list)"

it "блокировка DoH и bypass на месте"
assert_eq "да" "$(have podkop_extras_doh_apply)"

it "работа со списками sing-box не перетёрта"
assert_eq "да" "$(have get_ruleset_tag)"

# ============================ развилка живая ================================

it "по умолчанию активен sing-box"
set_core ""
assert_eq "sing-box" "$(core_current)"

it "формат наборов при sing-box - srs"
set_core "sing-box"
assert_eq "srs" "$(ruleset_format)"

it "формат наборов при clash-rs - текстовый"
set_core "clash-rs"
assert_eq "text" "$(ruleset_format)"

it "каталоги ядер не пересекаются"
set_core "sing-box"
sb=$(core_tmp_folder)
set_core "clash-rs"
assert_ne "$sb" "$(core_tmp_folder)"

# ============================ сам podkop ====================================

it "podkop подключает все новые модули"
missing=""
for m in core.sh clash_config_manager.sh clash_config_facade.sh \
	clash_rulesets.sh ruleset_dispatch.sh clash_config_builder.sh podkop_extras.sh; do
	grep -q "PODKOP_LIB/$m" "$SRC" || missing="$missing $m"
done
assert_eq "" "$missing"

it "podkop проверяет наличие каждого модуля перед сорсингом"
missing=""
for m in core.sh clash_config_manager.sh clash_config_facade.sh \
	clash_rulesets.sh ruleset_dispatch.sh clash_config_builder.sh podkop_extras.sh; do
	grep -q "check_required_file \"\$PODKOP_LIB/$m\"" "$SRC" || missing="$missing $m"
done
assert_eq "" "$missing"

it "в podkop не осталось прямых вызовов init-скрипта sing-box"
assert_eq "0" "$(grep -cE '^[[:space:]]*/etc/init\.d/sing-box (start|stop)' "$SRC")"

it "старт сервиса идёт через слой ядра"
assert_eq "1" "$(grep -c 'core_service_start' "$SRC")"

it "перед стартом глушится невыбранное ядро"
assert_eq "1" "$(grep -c 'core_disable_others' "$SRC")"

it "выбор генератора конфига есть в start_main"
assert_contains "clash_init_config" "$(sed -n '/^start_main()/,/^}/p' "$SRC")"

it "списки сообщества идут через диспетчер, а не через .srs напрямую"
assert_contains "ruleset_add_community" "$(sed -n '/^configure_community_list_handler()/,/^}/p' "$SRC")"

it "жёсткой ссылки на .srs в обработчике больше нет"
assert_not_contains 'SRS_MAIN_URL/$tag.srs' "$(sed -n '/^configure_community_list_handler()/,/^}/p' "$SRC")"

# ============================ конфиг ========================================

it "в конфиг добавлена опция выбора ядра"
assert_contains "option core" "$(cat "$(dirname "$0")/../podkop/files/etc/config/podkop")"

it "в конфиг добавлена опция блокировки DoH"
assert_contains "option block_doh" "$(cat "$(dirname "$0")/../podkop/files/etc/config/podkop")"

finish
