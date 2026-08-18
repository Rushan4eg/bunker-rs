#!/bin/sh
# Тесты слоя выбора ядра.
#
# Слой ходит в uci и в init-скрипты, которых на машине разработчика нет.
# Поэтому uci подменяется заглушкой, а пути сервисов и бинарников
# переопределяются через переменные окружения - ровно для этого они и
# вынесены в core.sh отдельными параметрами.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- заглушка uci -----------------------------------------------------------
# Значение подставляем через файл: так его видно и из подоболочек, в которых
# core_current вызывается внутри $( ).
UCI_CORE_FILE="$TMP/uci_core"
: >"$UCI_CORE_FILE"

uci() {
	# нас интересует только `uci -q get podkop.settings.<key>`
	case "$*" in
	*podkop.settings.core*) cat "$UCI_CORE_FILE" ;;
	*podkop.settings.config_path*) cat "$TMP/uci_path" 2>/dev/null ;;
	*) return 1 ;;
	esac
}

set_core() { printf '%s' "$1" >"$UCI_CORE_FILE"; }
set_path_mode() { printf '%s' "$1" >"$TMP/uci_path"; }

# --- заглушки сервисов ------------------------------------------------------
mk_service() {
	cat >"$1" <<'EOF'
#!/bin/sh
echo "$(basename "$0") $1" >> "$SERVICE_LOG"
case "$1" in
enabled) exit "${SERVICE_ENABLED_RC:-0}" ;;
esac
exit 0
EOF
	chmod +x "$1"
}

SERVICE_LOG="$TMP/service.log"
export SERVICE_LOG
: >"$SERVICE_LOG"

CORE_SB_SERVICE="$TMP/sing-box"
CORE_CR_SERVICE="$TMP/clash-rs"
mk_service "$CORE_SB_SERVICE"
mk_service "$CORE_CR_SERVICE"

. "$(dirname "$0")/../podkop/files/usr/lib/core.sh"

# переопределяем после подключения: в core.sh стоят значения по умолчанию
CORE_SB_SERVICE="$TMP/sing-box"
CORE_CR_SERVICE="$TMP/clash-rs"

# ============================ выбор ядра ====================================

it "пустая настройка даёт ядро по умолчанию"
set_core ""
assert_eq "sing-box" "$(core_current)"

it "явно выбранный sing-box"
set_core "sing-box"
assert_eq "sing-box" "$(core_current)"

it "явно выбранный clash-rs"
set_core "clash-rs"
assert_eq "clash-rs" "$(core_current)"

it "опечатка в имени ядра не оставляет роутер без ядра"
set_core "clash-rss"
assert_eq "sing-box" "$(core_current)"

it "мусор в настройке тоже откатывает к умолчанию"
set_core "; rm -rf /"
assert_eq "sing-box" "$(core_current)"

it "core_is_clash истинно только для clash-rs"
set_core "clash-rs"
core_is_clash && r=да || r=нет
assert_eq "да" "$r"

it "core_is_clash ложно для sing-box"
set_core "sing-box"
core_is_clash && r=да || r=нет
assert_eq "нет" "$r"

# ============================ свойства ======================================

it "бинарник sing-box"
set_core "sing-box"
assert_eq "sing-box" "$(core_binary)"

it "бинарник clash-rs"
set_core "clash-rs"
assert_eq "clash-rs" "$(core_binary)"

it "минимальная версия sing-box"
set_core "sing-box"
assert_eq "1.12.0" "$(core_min_version)"

it "минимальная версия clash-rs"
set_core "clash-rs"
assert_eq "0.10.0" "$(core_min_version)"

it "каталог наборов правил лежит внутри каталога ядра"
set_core "clash-rs"
assert_eq "/tmp/clash-rs/rulesets" "$(core_ruleset_folder)"

# ============================ путь конфига ==================================

# Опция хранит ПОЛНЫЙ путь, а не режим: в UI выбор называется Flash или RAM,
# наружу уходит "/etc/sing-box/config.json" либо "/tmp/sing-box/config.json".
it "sing-box без настройки берёт путь по умолчанию"
set_core "sing-box"
set_path_mode ""
assert_eq "/etc/sing-box/config.json" "$(core_config_path)"

it "sing-box отдаёт заданный путь как есть"
set_core "sing-box"
set_path_mode "/tmp/sing-box/config.json"
assert_eq "/tmp/sing-box/config.json" "$(core_config_path)"

it "sing-box не переписывает нестандартный путь"
set_core "sing-box"
set_path_mode "/srv/my/config.json"
assert_eq "/srv/my/config.json" "$(core_config_path)"

it "clash-rs без настройки кладёт конфиг на флеш"
set_core "clash-rs"
set_path_mode ""
assert_eq "/etc/clash-rs/config.json" "$(core_config_path)"

it "clash-rs наследует намерение не изнашивать флеш"
set_core "clash-rs"
set_path_mode "/tmp/sing-box/config.json"
assert_eq "/tmp/clash-rs/config.json" "$(core_config_path)"

it "clash-rs при пути на флеше остаётся на флеше"
set_core "clash-rs"
set_path_mode "/etc/sing-box/config.json"
assert_eq "/etc/clash-rs/config.json" "$(core_config_path)"

# ============================ сервис ========================================

it "start дёргает init-скрипт выбранного ядра"
set_core "clash-rs"
: >"$SERVICE_LOG"
core_service_start
assert_contains "clash-rs start" "$(cat "$SERVICE_LOG")"

it "start не трогает чужой init-скрипт"
set_core "clash-rs"
: >"$SERVICE_LOG"
core_service_start
assert_not_contains "sing-box" "$(cat "$SERVICE_LOG")"

it "stop дёргает выбранное ядро"
set_core "sing-box"
: >"$SERVICE_LOG"
core_service_stop
assert_contains "sing-box stop" "$(cat "$SERVICE_LOG")"

it "core_service_exists видит существующий скрипт"
set_core "sing-box"
core_service_exists && r=да || r=нет
assert_eq "да" "$r"

it "core_service_exists не выдумывает несуществующий"
set_core "sing-box"
CORE_SB_SERVICE="$TMP/нет-такого"
core_service_exists && r=да || r=нет
CORE_SB_SERVICE="$TMP/sing-box"
assert_eq "нет" "$r"

# ============================ переключение ==================================

it "при выборе clash-rs глушится sing-box"
set_core "clash-rs"
: >"$SERVICE_LOG"
core_disable_others
assert_contains "sing-box stop" "$(cat "$SERVICE_LOG")"

it "при выборе clash-rs sing-box ещё и выключается из автозапуска"
set_core "clash-rs"
: >"$SERVICE_LOG"
core_disable_others
assert_contains "sing-box disable" "$(cat "$SERVICE_LOG")"

it "активное ядро при этом не трогается"
set_core "clash-rs"
: >"$SERVICE_LOG"
core_disable_others
assert_not_contains "clash-rs" "$(cat "$SERVICE_LOG")"

it "симметрично: при выборе sing-box глушится clash-rs"
set_core "sing-box"
: >"$SERVICE_LOG"
core_disable_others
assert_contains "clash-rs stop" "$(cat "$SERVICE_LOG")"

# ============================ версия ========================================

it "версия sing-box разбирается из третьего поля"
set_core "sing-box"
cat >"$TMP/sing-box-bin" <<'EOF'
#!/bin/sh
echo "sing-box version 1.12.17"
EOF
chmod +x "$TMP/sing-box-bin"
CORE_SB_BIN="$TMP/sing-box-bin"
assert_eq "1.12.17" "$(core_version)"

it "версия clash-rs разбирается и теряет ведущую v"
set_core "clash-rs"
cat >"$TMP/clash-bin" <<'EOF'
#!/bin/sh
echo "clash-rs v0.10.8"
EOF
chmod +x "$TMP/clash-bin"
CORE_CR_BIN="$TMP/clash-bin"
assert_eq "0.10.8" "$(core_version)"

it "не установленное ядро не выдумывает версию"
set_core "clash-rs"
CORE_CR_BIN="$TMP/нет-такого-бинарника"
core_version >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

finish
