#!/bin/sh
# Тесты диагностики активного ядра.
#
# Проверяем то, что можно проверить без роутера: какие сокеты ядро обязано
# слушать, как разбирается вывод netstat, как сравнивается версия и что
# оказывается в ответе. Сам опрос системы (pgrep, netstat, init-скрипты) - три
# строки в core_diag_collect, они проверяются на железе.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

LIB=$(cd "$(dirname "$0")/../podkop/files/usr/lib" && pwd)

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- окружение --------------------------------------------------------------
UCI_CORE_FILE="$TMP/uci_core"
: >"$UCI_CORE_FILE"

uci() {
	case "$*" in
	*podkop.settings.core*) cat "$UCI_CORE_FILE" ;;
	*) return 1 ;;
	esac
}
set_core() { printf '%s' "$1" >"$UCI_CORE_FILE"; }

jq() { "$JQ" "$@"; }
logger() { :; }

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
. "$LIB/core.sh"
. "$LIB/core_diagnostics.sh"

# Вывод netstat -ln, каким его отдаёт busybox: колонки через пробелы,
# локальный адрес третьей колонкой.
netstat_singbox() {
	cat <<'EOF'
tcp        0      0 127.0.0.1:1602          0.0.0.0:*               LISTEN
udp        0      0 127.0.0.42:53           0.0.0.0:*
EOF
}

netstat_clash() {
	cat <<'EOF'
tcp        0      0 0.0.0.0:1602            0.0.0.0:*               LISTEN
udp        0      0 127.0.0.42:53           0.0.0.0:*
EOF
}

# ============================ ожидаемые сокеты ==============================

it "для sing-box tproxy ждём по точному адресу"
set_core "sing-box"
assert_eq "127.0.0.42:53 127.0.0.1:1602" "$(core_diag_ports_expected)"

# clash-rs не спрашивает адрес для tproxy: bind-address по умолчанию 0.0.0.0,
# и проверка на 127.0.0.1 у него не сработает никогда.
it "для clash-rs tproxy ждём только по порту"
set_core "clash-rs"
assert_eq "127.0.0.42:53 :1602" "$(core_diag_ports_expected)"

# ============================ разбор netstat ================================

it "sing-box: оба сокета на месте"
set_core "sing-box"
assert_eq "1" "$(core_diag_ports_ok "$(netstat_singbox)")"

# Тот самый ложный отрицательный результат, ради которого всё и переписано.
it "clash-rs на 0.0.0.0 засчитывается"
set_core "clash-rs"
assert_eq "1" "$(core_diag_ports_ok "$(netstat_clash)")"

it "старая проверка на 127.0.0.1 не увидела бы clash-rs"
set_core "sing-box"
assert_eq "0" "$(core_diag_ports_ok "$(netstat_clash)")"

it "нет DNS - проверка не пройдена"
set_core "clash-rs"
assert_eq "0" "$(core_diag_ports_ok "tcp 0 0 0.0.0.0:1602 0.0.0.0:* LISTEN")"

it "нет tproxy - проверка не пройдена"
assert_eq "0" "$(core_diag_ports_ok "udp 0 0 127.0.0.42:53 0.0.0.0:*")"

it "пустой вывод netstat - проверка не пройдена"
assert_eq "0" "$(core_diag_ports_ok "")"

# Без пробела в конце подстрока ":1602" находится внутри ":16020" и чужой
# слушатель засчитывался бы за наш.
it "порт 16020 не выдаёт себя за 1602"
set_core "clash-rs"
assert_eq "0" "$(core_diag_ports_ok "tcp 0 0 0.0.0.0:16020 0.0.0.0:* LISTEN
udp 0 0 127.0.0.42:53 0.0.0.0:*")"

# ============================ версия ========================================

it "версия выше минимальной подходит"
assert_eq "1" "$(core_diag_version_ok "1.13.18" "1.12.0")"

it "версия равная минимальной подходит"
assert_eq "1" "$(core_diag_version_ok "0.10.0" "0.10.0")"

it "версия ниже минимальной не подходит"
assert_eq "0" "$(core_diag_version_ok "0.9.9" "0.10.0")"

# clash-rs представляется как "clash-rs v0.10.8", и ведущая v ломала бы sort -V.
it "ведущая v в версии не мешает"
assert_eq "1" "$(core_diag_version_ok "v0.10.8" "0.10.0")"

it "пустая версия не подходит"
assert_eq "0" "$(core_diag_version_ok "" "0.10.0")"

it "двузначные части сравниваются как числа, а не как текст"
assert_eq "1" "$(core_diag_version_ok "1.13.2" "1.9.0")"

# ============================ ответ =========================================

RESP=$(core_diag_status_json "clash-rs" "0.10.8" "0.10.0" 1 1 1 1 1 1)

it "ответ - валидный JSON"
assert_valid_json "$RESP"

it "в ответе есть имя активного ядра"
assert_jq '.core' "clash-rs" "$RESP"

it "в ответе есть версия ядра"
assert_jq '.core_version' "0.10.8" "$RESP"

it "в ответе есть минимальная версия"
assert_jq '.core_min_version' "0.10.0" "$RESP"

# Имена ключей исторические: их читает main.js, собранный из TypeScript.
# Переименование сломало бы панель диагностики у всех, кто обновит только
# пакет podkop.
it "ключи для интерфейса остались прежними"
assert_jq '[.sing_box_installed, .sing_box_version_ok, .sing_box_service_exist,
	.sing_box_autostart_disabled, .sing_box_process_running,
	.sing_box_ports_listening] | join(",")' "1,1,1,1,1,1" "$RESP"

it "флаги остаются числами, а не строками"
assert_jq '.sing_box_installed | type' "number" "$RESP"

RESP_OFF=$(core_diag_status_json "sing-box" "" "1.12.0" 0 0 0 0 0 0)

it "неустановленное ядро подписано словами, а не пустой строкой"
assert_jq '.core_version' "not installed" "$RESP_OFF"

it "у неустановленного ядра все флаги нули"
assert_jq '[.sing_box_installed, .sing_box_ports_listening] | join(",")' "0,0" "$RESP_OFF"

it "имя ядра в ответе не подменяется значением по умолчанию"
assert_jq '.core' "sing-box" "$RESP_OFF"

# ============================ логи ==========================================

it "шаблон логов включает подкоп и активное ядро"
set_core "clash-rs"
assert_eq "podkop|clash-rs" "$(core_diag_log_pattern)"

it "при sing-box шаблон логов прежний"
set_core "sing-box"
assert_eq "podkop|sing-box" "$(core_diag_log_pattern)"

# ============================ сам скрипт ====================================
#
# Проверки уровня "строка не соврёт про ядро": их не поймать модульно, потому
# что подкоп целиком не подключить - при сорсинге он выполнит диспетчер.

SRC="$(dirname "$0")/../podkop/files/usr/bin/podkop"

it "модуль диагностики подключён"
assert_contains 'PODKOP_LIB/core_diagnostics.sh' "$(cat "$SRC")"

it "модуль проверяется перед сорсингом"
assert_contains 'check_required_file "$PODKOP_LIB/core_diagnostics.sh"' "$(cat "$SRC")"

# Ровно тот баг: при активном clash-rs в логе стояло sing-box.
it "лог dnsmasq называет активное ядро"
assert_not_contains 'Configure dnsmasq for sing-box' "$(cat "$SRC")"

it "остановка ядра тоже не называет sing-box"
assert_not_contains 'log "Stop sing-box"' "$(cat "$SRC")"

it "проверки ядра идут через core_diag_collect"
assert_contains "core_diag_collect" "$(sed -n '/^check_sing_box()/,/^}/p' "$SRC")"

# Команда была в диспетчере и в справке, а функции не существовало - вызов
# заканчивался кодом 127.
it "у команды показа логов появилась реализация"
assert_contains "check_sing_box_logs() {" "$(cat "$SRC")"

it "показ конфига берёт путь у слоя ядра"
assert_contains 'core_config_path' "$(sed -n '/^show_sing_box_config()/,/^}/p' "$SRC")"

it "версия ядра в системной информации отдаётся отдельным полем"
assert_contains "core_version: \$core_version" "$(cat "$SRC")"

finish
