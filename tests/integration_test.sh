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
. "$PODKOP_LIB/core_installer.sh"
. "$PODKOP_LIB/core_watchdog.sh"
. "$PODKOP_LIB/clash_subscriptions.sh"

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
	clash_rulesets.sh ruleset_dispatch.sh clash_config_builder.sh podkop_extras.sh \
	core_installer.sh core_watchdog.sh clash_subscriptions.sh; do
	grep -q "PODKOP_LIB/$m" "$SRC" || missing="$missing $m"
done
assert_eq "" "$missing"

it "podkop проверяет наличие каждого модуля перед сорсингом"
missing=""
for m in core.sh clash_config_manager.sh clash_config_facade.sh \
	clash_rulesets.sh ruleset_dispatch.sh clash_config_builder.sh podkop_extras.sh \
	core_installer.sh core_watchdog.sh clash_subscriptions.sh; do
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

# ============================ установщик ядра ===============================

it "установщик подключён и его функции на месте"
assert_eq "да" "$(have core_installer_update)"

it "в podkop есть команды установки и отката ядра"
assert_contains "install_core | update_core)" "$(cat "$SRC")"

it "откат ядра тоже доступен командой"
assert_contains "rollback_core)" "$(cat "$SRC")"

it "команды описаны в справке, а не только в диспетчере"
assert_contains "install_core            Install" "$(cat "$SRC")"

it "прокси прокидывается в установщик существующим хелпером"
assert_contains 'CORE_INSTALLER_PROXY="$(get_service_proxy_address)"' "$(cat "$SRC")"

# Без этого подкоп в clash-режиме собрал бы конфиг и дёрнул сервис, которого
# нет: clash-rs ставится не пакетом, а нами в рантайме.
it "старт отказывается работать, если ядро не установлено"
assert_contains "core_installer_is_installed" "$(sed -n '/^start_main()/,/^}/p' "$SRC")"

it "Makefile кладёт init-скрипт clash-rs в пакет"
assert_contains "init.d/clash-rs" "$(cat "$(dirname "$0")/../podkop/Makefile")"

it "при удалении пакета сервис ядра останавливается"
assert_contains "/etc/init.d/clash-rs stop" "$(cat "$(dirname "$0")/../podkop/Makefile")"

# ============================ интерфейс LuCI ================================
#
# Опции бэкенда без галочек в интерфейсе никто не найдёт: подкоп настраивают
# через LuCI, а не через uci. Файлы settings.js и section.js собираются не из
# TypeScript, а правятся руками, поэтому и проверяем их как текст.

UI="$(dirname "$0")/../luci-app-podkop/htdocs/luci-static/resources/view/podkop"

it "выбор ядра есть в настройках"
assert_contains '"core",' "$(cat "$UI/settings.js")"

it "в выборе ядра оба варианта"
assert_contains 'o.value("clash-rs", "clash-rs")' "$(cat "$UI/settings.js")"

it "по умолчанию в интерфейсе тоже sing-box"
assert_contains 'o.value("sing-box", "sing-box")' "$(cat "$UI/settings.js")"

it "блокировка DoH есть в настройках"
assert_contains '"block_doh",' "$(cat "$UI/settings.js")"

it "сторож ядра есть в настройках"
assert_contains '"core_watchdog",' "$(cat "$UI/settings.js")"

it "тип подключения bypass есть в секциях"
assert_contains 'o.value("bypass", "Bypass")' "$(cat "$UI/section.js")"

# node на Windows - нативная программа и POSIX-путь не понимает, а конверсию
# путей мы для всего набора отключили ради jq. Поэтому под Windows приводим
# путь через cygpath; на линуксе он не нужен и ветка не выполняется.
js_ok() {
	command -v node > /dev/null 2>&1 || return 0 # нет node - нечем проверять
	f="$1"
	if [ -n "$WINDIR" ] && command -v cygpath > /dev/null 2>&1; then
		f=$(cygpath -w "$f")
	fi
	node --check "$f" > /dev/null 2>&1
}

it "settings.js остался валидным JS"
js_ok "$UI/settings.js" && r=да || r=нет
assert_eq "да" "$r"

it "section.js остался валидным JS"
js_ok "$UI/section.js" && r=да || r=нет
assert_eq "да" "$r"

# ============================ сторож и подписки =============================

it "сторож ядра подключён"
assert_eq "да" "$(have core_watchdog_tick)"

it "подписки подключены"
assert_eq "да" "$(have clash_sub_configure_section)"

# Без этой ветки сторож получил бы от подкопа справку и код 1, то есть сделал
# бы только рестарт ядра - ровно без того, ради чего он написан.
it "podkop умеет команду восстановления dnsmasq"
assert_contains "dnsmasq_restore)" "$(cat "$SRC")"

it "цикл сторожа запускается командой"
assert_contains "watchdog)" "$(cat "$SRC")"

it "обе команды описаны в справке"
assert_contains "dnsmasq_restore         Restore" "$(cat "$SRC")"

it "билдер знает тип секции subscription"
assert_contains "subscription)" "$(cat "$PODKOP_LIB/clash_config_builder.sh")"

# На sing-box подписок нет вовсе, и молчаливое "Unknown type" тут никому не
# помогает: надо сказать, что делать.
it "при sing-box подписка даёт внятный отказ, а не Unknown type"
assert_contains "Subscriptions require the clash-rs core" "$(cat "$SRC")"

it "подписка есть в интерфейсе секций"
assert_contains 'o.value("subscription"' "$(cat "$UI/section.js")"

it "поле ссылки подписки есть в интерфейсе"
assert_contains '"subscription_url",' "$(cat "$UI/section.js")"

finish
