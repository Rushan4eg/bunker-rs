# Диагностика активного ядра.
#
# Проверки в подкопе писались, когда ядро было одно, и спрашивают они
# буквально про sing-box: имя бинарника, путь init-скрипта, строку версии,
# сокет 127.0.0.1:1602. При активном clash-rs каждая такая проверка отвечает
# "нет" - ядро работает, трафик идёт, а диагностика показывает шесть красных
# крестов и советует переустановить sing-box, которым никто не пользуется.
#
# Здесь те же шесть проверок, но заданные через слой core_*. Разбор и сборка
# ответа отделены от опроса системы: первое покрыто тестами, второе - три
# строки вокруг pgrep и netstat, которые вне роутера всё равно не проверить.
#
# shellcheck shell=ash

## --- ожидаемые сокеты ------------------------------------------------------

#######################################
# Сокеты, которые ядро обязано слушать.
#
# Порты у обоих ядер одни и те же, а вот адрес tproxy - нет. sing-box берёт
# его из конфига и садится ровно на 127.0.0.1. clash-rs адреса для tproxy не
# спрашивает: bind-address по умолчанию это BindAddress::all_v4(), то есть
# 0.0.0.0, и проверка на 127.0.0.1:1602 у него не сработает никогда. Поэтому
# для clash-rs спрашиваем только порт.
#
# DNS у обоих слушается по точному адресу: sing-box - инбаундом, clash-rs -
# полем dns.listen, которое разбирается как SocketAddr целиком.
#
# Outputs:
#   список подстрок через пробел
#######################################
core_diag_ports_expected() {
	if core_is_clash; then
		printf '%s:%s :%s' \
			"$SB_DNS_INBOUND_ADDRESS" "$SB_DNS_INBOUND_PORT" "$SB_TPROXY_INBOUND_PORT"
	else
		printf '%s:%s %s:%s' \
			"$SB_DNS_INBOUND_ADDRESS" "$SB_DNS_INBOUND_PORT" \
			"$SB_TPROXY_INBOUND_ADDRESS" "$SB_TPROXY_INBOUND_PORT"
	fi
}

#######################################
# Все ли ожидаемые сокеты есть в выводе netstat.
#
# Пробел в конце подстроки обязателен: без него ":1602" находится внутри
# ":16020" и посторонний слушатель засчитывается за наш. Локальный адрес в
# выводе netstat никогда не последняя колонка, так что пробел за ним есть
# всегда.
#
# Arguments:
#   listing: вывод netstat -ln или ss -ln
# Outputs:
#   1 если найдены все, иначе 0
#######################################
core_diag_ports_ok() {
	local listing="$1" endpoint

	[ -n "$listing" ] || {
		printf '0'
		return 0
	}

	for endpoint in $(core_diag_ports_expected); do
		case "$listing" in
		*"$endpoint "*) ;;
		*)
			printf '0'
			return 0
			;;
		esac
	done
	printf '1'
}

## --- версия ----------------------------------------------------------------

#######################################
# Дотягивает ли версия до минимальной для этого ядра.
# Arguments:
#   version: строка версии, может быть пустой
#   minimum: минимально допустимая
# Outputs:
#   1 или 0
#######################################
core_diag_version_ok() {
	local version="$1" minimum="$2"

	[ -n "$version" ] || {
		printf '0'
		return 0
	}

	if is_min_package_version "${version#v}" "$minimum"; then
		printf '1'
	else
		printf '0'
	fi
}

## --- ответ -----------------------------------------------------------------

#######################################
# Собрать ответ диагностики.
#
# Имена шести ключей остались от sing-box сознательно. Их читает main.js,
# который собран из TypeScript и правится не здесь; переименование ключей
# сломало бы панель диагностики у всех, кто обновит только пакет podkop.
# Смысл у ключей теперь другой - они про активное ядро, - поэтому рядом
# лежат core, core_version и core_min_version, по которым интерфейс и
# подписывает строки.
#
# Arguments:
#   core, version, minimum, installed, version_ok, service_exist,
#   autostart_disabled, process_running, ports_listening
#######################################
core_diag_status_json() {
	jq -n \
		--arg core "$1" \
		--arg version "$2" \
		--arg minimum "$3" \
		--argjson installed "$4" \
		--argjson version_ok "$5" \
		--argjson service_exist "$6" \
		--argjson autostart_disabled "$7" \
		--argjson process_running "$8" \
		--argjson ports_listening "$9" \
		'{
			core: $core,
			core_version: (if $version == "" then "not installed" else $version end),
			core_min_version: $minimum,
			sing_box_installed: $installed,
			sing_box_version_ok: $version_ok,
			sing_box_service_exist: $service_exist,
			sing_box_autostart_disabled: $autostart_disabled,
			sing_box_process_running: $process_running,
			sing_box_ports_listening: $ports_listening
		}'
}

#######################################
# Опросить систему и отдать ответ диагностики.
# Outputs:
#   JSON, см. core_diag_status_json
#######################################
core_diag_collect() {
	local name version minimum listing
	local installed=0 version_ok=0 service_exist=0
	local autostart_disabled=0 process_running=0 ports_listening=0

	name="$(core_current)"
	minimum="$(core_min_version)"

	if core_is_installed; then
		installed=1
		version="$(core_version 2>/dev/null)"
		version_ok="$(core_diag_version_ok "$version" "$minimum")"
	fi

	if core_service_exists; then
		service_exist=1
		# Автозапуск ядра подкоп выключает намеренно: сервис поднимает он
		# сам, после того как соберёт конфиг и поставит правила nft.
		core_service_is_enabled || autostart_disabled=1
	fi

	pgrep "$(core_binary)" >/dev/null 2>&1 && process_running=1

	listing="$(netstat -ln 2>/dev/null)"
	[ -n "$listing" ] || listing="$(ss -ln 2>/dev/null)"
	ports_listening="$(core_diag_ports_ok "$listing")"

	core_diag_status_json "$name" "${version:-}" "$minimum" \
		"$installed" "$version_ok" "$service_exist" \
		"$autostart_disabled" "$process_running" "$ports_listening"
}

## --- логи ------------------------------------------------------------------

#######################################
# Шаблон для grep по логам: подкоп плюс активное ядро.
#######################################
core_diag_log_pattern() { printf 'podkop|%s' "$(core_binary)"; }

#######################################
# Логи ядра из системного журнала.
#
# Команда check_sing_box_logs была в диспетчере и в справке, но самой функции
# в скрипте не было - апстримная опечатка, из-за которой вызов заканчивался
# "not found" и кодом 127.
#
# Arguments:
#   lines: сколько строк показать, по умолчанию 100
#######################################
core_diag_logs() {
	local lines="${1:-100}" bin logs

	command -v logread >/dev/null 2>&1 || {
		echo "Error: logread command not found" >&2
		return 1
	}

	bin="$(core_binary)"
	logs="$(logread | grep -F "$bin")"

	[ -n "$logs" ] || {
		echo "No log entries for core '$bin'" >&2
		return 1
	}

	printf '%s\n' "$logs" | tail -n "$lines"
}
