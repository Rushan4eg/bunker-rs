# Слой ядра.
#
# Подкоп исторически прибит к sing-box: имя бинарника, путь init-скрипта и
# формат конфига рассыпаны по 211 местам основного скрипта. Чтобы рядом мог
# жить clash-rs, всё это собрано здесь, а наружу торчат функции core_*.
#
# Ядро выбирается опцией podkop.settings.core. Значение по умолчанию -
# sing-box: существующие установки должны продолжать работать ровно как
# работали, без миграции конфига и без сюрпризов после обновления.
#
# Все пути и команды берутся из переменных, а не зашиты в тело функций -
# иначе слой было бы нечем тестировать, кроме как на живом роутере.
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- поддерживаемые ядра ---------------------------------------------------

CORE_DEFAULT="sing-box"
CORE_SUPPORTED="sing-box clash-rs"

# sing-box
CORE_SB_BIN="${CORE_SB_BIN:-sing-box}"
CORE_SB_SERVICE="${CORE_SB_SERVICE:-/etc/init.d/sing-box}"
CORE_SB_MIN_VERSION="1.12.0"
CORE_SB_TMP_FOLDER="/tmp/sing-box"

# clash-rs
CORE_CR_BIN="${CORE_CR_BIN:-clash-rs}"
CORE_CR_SERVICE="${CORE_CR_SERVICE:-/etc/init.d/clash-rs}"
CORE_CR_MIN_VERSION="0.10.0"
CORE_CR_TMP_FOLDER="/tmp/clash-rs"

## --- выбор -----------------------------------------------------------------

#######################################
# Имя активного ядра.
# Читает podkop.settings.core, при пустом или неизвестном значении возвращает
# ядро по умолчанию. Неизвестное значение не считается ошибкой сознательно:
# опечатка в конфиге не должна оставлять роутер без интернета.
# Outputs:
#   sing-box | clash-rs
#######################################
core_current() {
	local value found item
	value=$(uci -q get podkop.settings.core 2>/dev/null)
	[ -n "$value" ] || {
		printf '%s' "$CORE_DEFAULT"
		return 0
	}

	found=0
	for item in $CORE_SUPPORTED; do
		[ "$item" = "$value" ] && found=1 && break
	done

	if [ "$found" = "1" ]; then
		printf '%s' "$value"
	else
		printf '%s' "$CORE_DEFAULT"
	fi
}

core_is_clash() { [ "$(core_current)" = "clash-rs" ]; }
core_is_sing_box() { [ "$(core_current)" = "sing-box" ]; }

## --- свойства --------------------------------------------------------------

core_binary() {
	if core_is_clash; then printf '%s' "$CORE_CR_BIN"; else printf '%s' "$CORE_SB_BIN"; fi
}

core_service() {
	if core_is_clash; then printf '%s' "$CORE_CR_SERVICE"; else printf '%s' "$CORE_SB_SERVICE"; fi
}

core_min_version() {
	if core_is_clash; then printf '%s' "$CORE_CR_MIN_VERSION"; else printf '%s' "$CORE_SB_MIN_VERSION"; fi
}

core_tmp_folder() {
	if core_is_clash; then printf '%s' "$CORE_CR_TMP_FOLDER"; else printf '%s' "$CORE_SB_TMP_FOLDER"; fi
}

core_ruleset_folder() { printf '%s/rulesets' "$(core_tmp_folder)"; }

#######################################
# Путь к файлу конфига.
# Учитывает podkop.settings.sing_box_config_path (flash или ram), который уже
# есть в UI. Для clash-rs та же развилка, только имя файла другое.
#######################################
core_config_path() {
	local mode
	mode=$(uci -q get podkop.settings.sing_box_config_path 2>/dev/null)

	if core_is_clash; then
		case "$mode" in
		ram) printf '/tmp/clash-rs/config.json' ;;
		*) printf '/etc/clash-rs/config.json' ;;
		esac
	else
		case "$mode" in
		ram) printf '/tmp/sing-box/config.json' ;;
		*) printf '/etc/sing-box/config.json' ;;
		esac
	fi
}

## --- состояние -------------------------------------------------------------

core_is_installed() {
	command -v "$(core_binary)" >/dev/null 2>&1
}

#######################################
# Версия установленного ядра.
# Формат вывода у ядер разный, поэтому разбор свой на каждое:
#   sing-box version 1.12.17   -> третье поле
#   clash-rs v0.10.8           -> второе поле, без ведущей v
# Outputs:
#   версия, либо пусто если ядро не установлено
#######################################
core_version() {
	local bin raw
	bin=$(core_binary)
	command -v "$bin" >/dev/null 2>&1 || return 1

	raw=$("$bin" -V 2>/dev/null || "$bin" version 2>/dev/null || "$bin" --version 2>/dev/null)
	[ -n "$raw" ] || return 1

	if core_is_clash; then
		printf '%s' "$raw" | head -n1 | awk '{print $NF}' | sed 's/^v//'
	else
		printf '%s' "$raw" | head -n1 | awk '{print $3}'
	fi
}

#######################################
# Проверить конфиг, не запуская сервис.
# У sing-box это `sing-box check -c file`, у clash-rs проверка конфига
# отдельной командой не выделена - запускаем с -d на временном каталоге и
# смотрим код возврата.
# Arguments:
#   path: путь к конфигу (необязательно, по умолчанию core_config_path)
# Returns:
#   0 если конфиг принят
#######################################
core_check_config() {
	local path bin
	path="${1:-$(core_config_path)}"
	bin=$(core_binary)

	[ -f "$path" ] || return 1

	if core_is_clash; then
		"$bin" -t -f "$path" >/dev/null 2>&1
	else
		"$bin" check -c "$path" >/dev/null 2>&1
	fi
}

## --- управление сервисом ---------------------------------------------------

core_service_start() { "$(core_service)" start >/dev/null 2>&1; }
core_service_stop() { "$(core_service)" stop >/dev/null 2>&1; }
core_service_restart() { "$(core_service)" restart >/dev/null 2>&1; }
core_service_enable() { "$(core_service)" enable >/dev/null 2>&1; }
core_service_disable() { "$(core_service)" disable >/dev/null 2>&1; }
core_service_is_enabled() { "$(core_service)" enabled >/dev/null 2>&1; }
core_service_exists() { [ -x "$(core_service)" ]; }

#######################################
# Остановить и выключить ядро, которое сейчас НЕ выбрано.
# Нужно при переключении: два ядра одновременно поднимут по tproxy-инбаунду
# на один порт, и второе молча не стартует.
#######################################
core_disable_others() {
	local active item service
	active=$(core_current)

	for item in $CORE_SUPPORTED; do
		[ "$item" = "$active" ] && continue
		case "$item" in
		clash-rs) service="$CORE_CR_SERVICE" ;;
		*) service="$CORE_SB_SERVICE" ;;
		esac
		[ -x "$service" ] || continue
		"$service" stop >/dev/null 2>&1
		"$service" disable >/dev/null 2>&1
	done
}
