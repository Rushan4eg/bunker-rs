# Сторож ядра.
#
# Ценность сторожа не в перезапуске. Подкоп при старте перенастраивает dnsmasq
# на резолвер ядра (dnsmasq_configure в /usr/bin/podkop: список server
# заменяется на 127.0.0.42, noresolv 1, cachesize 0). Пока ядро живо, это
# ровно то, что нужно - через него ходит вся DNS-маршрутизация. Но если ядро
# упало, dnsmasq остаётся смотреть в мёртвый резолвер, и роутер теряет DNS
# ЦЕЛИКОМ: не проксируемый трафик, а вообще весь. Пользователь видит «интернета
# нет» и не имеет ни одной подсказки, почему.
#
# Поэтому порядок восстановления обязателен и зафиксирован в
# core_watchdog_recover:
#
#   1) вернуть dnsmasq на рабочий резолвер;
#   2) только потом пытаться поднять ядро.
#
# Наоборот нельзя: старт ядра может занять секунды, может не удаться вовсе, и
# всё это время роутер сидит без DNS. Восстановление dnsmasq стоит одну
# перезагрузку конфига и работает независимо от того, поднимется ядро или нет.
#
# Почему этого не делает procd. У clash-rs в init-скрипте стоит respawn 3600 5
# 5, у sing-box - свой. Respawn ловит только смерть процесса и ничего не знает
# ни про dnsmasq, ни про зависшее ядро, которое живо как процесс, но не
# обрабатывает запросы. Сторож закрывает ровно эти две дыры, а с respawn не
# конфликтует: пока procd поднимает ядро сам, сторож видит его живым и молчит.
#
# Устройство модуля - как в core_installer.sh, два слоя:
#
#   чистые функции  - core_watchdog_decide, core_watchdog_verdict,
#                     core_watchdog_backoff, core_watchdog_clamp_interval,
#                     core_watchdog_normalize_address,
#                     core_watchdog_window_expired. Ни одна ничего не запускает
#                     и никуда не пишет, поэтому проверяются тестами целиком.
#   тонкие обёртки  - всё, что стучится наружу: _core_watchdog_process_running,
#                     _core_watchdog_http_probe, _core_watchdog_dnsmasq_restore,
#                     _core_watchdog_core_start, _core_watchdog_now,
#                     _core_watchdog_sleep. В тестах подменяются заглушками,
#                     своей логики не содержат.
#
# Ядро сторожу безразлично: имя бинарника, init-скрипт и путь к конфигу берутся
# из core.sh (core_binary, core_service_start, core_config_path), поэтому один и
# тот же код работает и с sing-box, и с clash-rs.
#
# Зависимости: core.sh (слой ядра), constants.sh (SB_DNS_INBOUND_ADDRESS,
# SB_CLASH_API_CONTROLLER_PORT), curl и jq - оба уже в DEPENDS пакета.
#
# Использование:
#   core_watchdog_tick     # одна проверка, код возврата ниже
#   core_watchdog_loop     # бесконечный цикл с паузой core_watchdog_interval
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- параметры ---------------------------------------------------------------
# Всё через :- чтобы переопределялось снаружи: из podkop, из тестов или руками
# при отладке на роутере.

# Файл состояния. Состояние обязано переживать перезапуск самого сторожа - иначе
# счётчик попыток обнуляется вместе с процессом, и предохранитель не
# предохраняет ни от чего.
#
# Лежит в tmpfs, а не на флеше, сознательно. Во-первых, файл переписывается на
# каждой попытке восстановления, а флеш роутера этого не любит. Во-вторых,
# перезагрузка - это новая ситуация: считать попытки, сделанные до ребута,
# незачем.
CORE_WATCHDOG_STATE_FILE="${CORE_WATCHDOG_STATE_FILE:-/tmp/podkop-core-watchdog.state}"

# Интервал проверки. Тридцать секунд - компромисс: netshift проверяет каждые
# десять, но там нет запроса в Clash API, а у нас каждая проверка это ещё и
# curl. На слабом роутере опрос раз в десять секунд заметен, а пользователь всё
# равно замечает пропажу DNS не быстрее чем за минуту.
CORE_WATCHDOG_INTERVAL_DEFAULT="${CORE_WATCHDOG_INTERVAL_DEFAULT:-30}"

# Границы вменяемости интервала. Ноль или единица в конфиге превратили бы сторож
# в busy-loop, который сам по себе положит роутер - а это ровно то, от чего он
# должен защищать.
CORE_WATCHDOG_INTERVAL_MIN="${CORE_WATCHDOG_INTERVAL_MIN:-5}"
CORE_WATCHDOG_INTERVAL_MAX="${CORE_WATCHDOG_INTERVAL_MAX:-3600}"

# Сколько проверок подряд должны провалиться, прежде чем сторож вмешается.
#
# Это не перестраховка. Ложное срабатывание здесь дороже пропущенного падения:
# восстановление dnsmasq снимает DNS-маршрутизацию подкопа, и вернуть её может
# только podkop restart. Ядро, которое ещё поднимается (или на секунду задумалось
# под нагрузкой), не должно стоить пользователю работающего проксирования.
CORE_WATCHDOG_MISSES="${CORE_WATCHDOG_MISSES:-2}"

# Пауза между попытками: базовая и потолок. Растёт вдвое с каждой попыткой
# (30, 60, 120, 240, 300...) - как в netshift. Смысл в том, что ядро, упавшее
# из-за нехватки памяти или битого конфига, от немедленного повторного старта
# не починится, а лог и флеш будут гореть.
CORE_WATCHDOG_COOLDOWN="${CORE_WATCHDOG_COOLDOWN:-30}"
CORE_WATCHDOG_COOLDOWN_MAX="${CORE_WATCHDOG_COOLDOWN_MAX:-300}"

# Предохранитель: сколько попыток разрешено за окно. Исчерпали - только пишем в
# лог и ничего не трогаем до конца окна.
#
# Окно, а не «сдаться навсегда» (как в netshift). Причина падения бывает
# временной - обновление списков съело память, флеш был занят, - и сторож,
# который замолкает до перезагрузки, бесполезен ровно в том случае, ради
# которого его ставили. DNS при этом уже восстановлен первой же попыткой, то
# есть без интернета роутер не остаётся в любом случае.
CORE_WATCHDOG_ATTEMPTS="${CORE_WATCHDOG_ATTEMPTS:-5}"
CORE_WATCHDOG_WINDOW="${CORE_WATCHDOG_WINDOW:-1800}"

# Сколько ждать после старта, прежде чем проверять, поднялось ли ядро. Ни
# sing-box, ни clash-rs не открывают Clash API мгновенно.
CORE_WATCHDOG_START_GRACE="${CORE_WATCHDOG_START_GRACE:-5}"

# Clash API. Порт общий для обоих ядер (constants.sh), путь - любой
# существующий: нам нужен факт HTTP-ответа, а не его содержимое.
CORE_WATCHDOG_API_PORT="${CORE_WATCHDOG_API_PORT:-${SB_CLASH_API_CONTROLLER_PORT:-9090}}"
CORE_WATCHDOG_API_PATH="${CORE_WATCHDOG_API_PATH:-/version}"
CORE_WATCHDOG_API_TIMEOUT="${CORE_WATCHDOG_API_TIMEOUT:-5}"

# Адрес контроллера. Пусто - берётся из конфига ядра (см.
# core_watchdog_config_api_address). Зашивать 127.0.0.1 нельзя: подкоп поднимает
# контроллер на адресе LAN, а не на локалхосте, и проверка стучалась бы в
# закрытый порт на живом ядре.
CORE_WATCHDOG_API_ADDRESS="${CORE_WATCHDOG_API_ADDRESS:-}"

# Резолвер, на который подкоп переводит dnsmasq. По нему и определяется, что
# dnsmasq сейчас перенастроен на ядро.
CORE_WATCHDOG_DNS_ADDRESS="${CORE_WATCHDOG_DNS_ADDRESS:-${SB_DNS_INBOUND_ADDRESS:-127.0.0.42}}"

# Чем восстанавливать dnsmasq. Своей реализации у сторожа нет и быть не должно:
# бэкап лежит в dhcp.@dnsmasq[0].podkop_server / podkop_noresolv /
# podkop_cachesize, и разбирает его dnsmasq_restore в /usr/bin/podkop. Второй
# такой же разборщик означал бы второе место, где чинить один и тот же баг.
CORE_WATCHDOG_PODKOP_BIN="${CORE_WATCHDOG_PODKOP_BIN:-/usr/bin/podkop}"
CORE_WATCHDOG_DNSMASQ_RESTORE_CMD="${CORE_WATCHDOG_DNSMASQ_RESTORE_CMD:-dnsmasq_restore}"

# Ограничитель числа проходов цикла. Ноль - бесконечно, то есть боевой режим;
# положительное значение нужно тестам, чтобы core_watchdog_loop когда-нибудь
# закончился.
CORE_WATCHDOG_TICKS="${CORE_WATCHDOG_TICKS:-0}"

## --- коды возврата core_watchdog_tick ----------------------------------------
#
#   0 - ядро живо, вмешательство не потребовалось
#   1 - сторож выключен опцией
#   2 - подозрение: проверка провалилась, но промахов пока меньше порога
#   3 - кулдаун: пробовать снова рано
#   4 - предохранитель: попытки за окно исчерпаны, только лог
#   5 - вмешались, ядро поднялось
#   6 - вмешались, ядро подняться не смогло

## --- служебное ---------------------------------------------------------------

# Логи есть только внутри подкопа; в тестах и при ручном запуске модуль должен
# работать молча, а не падать на отсутствующей функции log. Проверяется именно
# функция: command -v для функции печатает её имя, а для внешней программы -
# путь, и посторонний бинарник с именем log в PATH нас бы обманул.
_core_watchdog_log() {
	case "$(command -v log 2> /dev/null)" in
	log) log "$1" "${2:-info}" ;;
	esac
	return 0
}

# jq на роутере системный, в тестах подсовывается через JQ=
_core_watchdog_jq() {
	"${JQ:-jq}" "$@"
}

# Текущее время в секундах эпохи. Отдельной обёрткой - чтобы тесты могли
# двигать часы, не дожидаясь получаса реального времени.
_core_watchdog_now() {
	date +%s 2> /dev/null || printf '0'
}

# Пауза. Отдельной обёрткой по той же причине, что и в clash_rulesets.sh: тест,
# который честно спит, никто не станет гонять.
_core_watchdog_sleep() {
	sleep "$1"
}

## --- настройки из UCI --------------------------------------------------------

#######################################
# Включён ли сторож.
#
# По умолчанию ВЫКЛЮЧЕН. В подкопе принято, что автоматика, которая сама трогает
# конфиг и дёргает сервисы, включается осознанно: сторож перенастраивает
# dnsmasq и перезапускает ядро, и делать это на всех установках сразу после
# обновления пакета - не то, чего пользователь просил.
#
# Returns:
#   0 если включён
#######################################
core_watchdog_enabled() {
	local value
	value=$(uci -q get podkop.settings.core_watchdog 2> /dev/null)

	case "$value" in
	1 | on | true | yes | enabled) return 0 ;;
	esac
	return 1
}

#######################################
# Интервал проверки из конфига, приведённый к разумным границам.
# Outputs:
#   секунды
#######################################
core_watchdog_interval() {
	core_watchdog_clamp_interval "$(uci -q get podkop.settings.core_watchdog_interval 2> /dev/null)"
}

#######################################
# Привести интервал к границам. Чистая функция.
# Мусор и пустое значение дают значение по умолчанию, а не ошибку: опечатка в
# конфиге не должна выключать сторож молча.
# Arguments:
#   value: строка из конфига
# Outputs:
#   секунды
#######################################
core_watchdog_clamp_interval() {
	local value="$1"

	case "$value" in
	'' | *[!0-9]*)
		printf '%s' "$CORE_WATCHDOG_INTERVAL_DEFAULT"
		return 0
		;;
	esac

	if [ "$value" -lt "$CORE_WATCHDOG_INTERVAL_MIN" ]; then
		printf '%s' "$CORE_WATCHDOG_INTERVAL_MIN"
	elif [ "$value" -gt "$CORE_WATCHDOG_INTERVAL_MAX" ]; then
		printf '%s' "$CORE_WATCHDOG_INTERVAL_MAX"
	else
		printf '%s' "$value"
	fi
}

#######################################
# Разрешено ли подкопу трогать dnsmasq.
# Опция dont_touch_dhcp означает, что DNS настраивает пользователь сам; в этом
# случае подкоп dnsmasq не перенастраивал, и восстанавливать нечего - вызов
# dnsmasq_restore затёр бы чужую настройку.
# Returns:
#   0 если dnsmasq наш
#######################################
core_watchdog_dnsmasq_managed() {
	[ "$(uci -q get podkop.settings.dont_touch_dhcp 2> /dev/null)" != "1" ]
}

#######################################
# Смотрит ли dnsmasq сейчас в резолвер ядра.
# Именно это состояние и опасно при мёртвом ядре.
# Returns:
#   0 если перенастроен на ядро
#######################################
core_watchdog_dnsmasq_hijacked() {
	local servers
	servers=$(uci -q get 'dhcp.@dnsmasq[0].server' 2> /dev/null) || return 1

	case "$servers" in
	*"$CORE_WATCHDOG_DNS_ADDRESS"*) return 0 ;;
	esac
	return 1
}

## --- адрес Clash API ---------------------------------------------------------

#######################################
# Адрес контроллера из конфига активного ядра.
#
# Читаем из конфига, а не из UCI, потому что в UCI его нет вовсе: подкоп
# вычисляет адрес при генерации (get_service_listen_address - это IP интерфейса
# lan, либо 0.0.0.0 при разрешённом доступе с WAN) и кладёт сразу в конфиг.
# Ключ у ядер разный: у clash-rs это поле верхнего уровня, у sing-box -
# experimental.clash_api.
#
# Arguments:
#   path: путь к конфигу (необязательно, по умолчанию core_config_path)
# Outputs:
#   host:port, либо ничего
# Returns:
#   1, если конфига нет или адреса в нём нет
#######################################
core_watchdog_config_api_address() {
	local path="${1:-$(core_config_path)}" filter address

	[ -f "$path" ] || return 1

	if core_is_clash; then
		filter='.["external-controller"] // empty'
	else
		filter='.experimental.clash_api.external_controller // empty'
	fi

	# Конфиг подаётся на вход, а не именем файла: так же, как во всех остальных
	# модулях подкопа. Под Windows, где гоняется часть тестов, слой MSYS не
	# передаёт нативному jq.exe posix-пути, и вариант с именем файла зеленел под
	# dash и краснел под bash.
	#
	# tr -d '\r': тот же нативный jq.exe дописывает возврат каретки, и адрес с
	# невидимым байтом на конце превратился бы в неразрешимое имя.
	address=$(_core_watchdog_jq -r "$filter" < "$path" 2> /dev/null | head -n1 | tr -d '\r')
	[ -n "$address" ] || return 1

	printf '%s' "$address"
}

#######################################
# Привести адрес контроллера к виду, в который можно постучаться. Чистая
# функция.
#
# 0.0.0.0 в конфиге означает «слушаю на всех интерфейсах», а не адрес, по
# которому можно соединиться, - подменяем локалхостом. То же с пустым хостом и
# с [::].
#
# Arguments:
#   address: строка из конфига (host:port, host, [ipv6]:port)
# Outputs:
#   host:port, IPv6-хост в квадратных скобках
#######################################
core_watchdog_normalize_address() {
	local address="$1" host port

	case "$address" in
	\[*\]:*)
		host=${address%]*}
		host=${host#[}
		port=${address##*:}
		;;
	\[*\])
		host=${address#[}
		host=${host%]}
		port=""
		;;
	*:*:*)
		# голый IPv6 без скобок и без порта
		host="$address"
		port=""
		;;
	*:*)
		host=${address%:*}
		port=${address##*:}
		;;
	*)
		host="$address"
		port=""
		;;
	esac

	case "$host" in
	'' | 0.0.0.0 | :: | '*') host="127.0.0.1" ;;
	esac

	case "$port" in
	'' | *[!0-9]*) port="$CORE_WATCHDOG_API_PORT" ;;
	esac

	case "$host" in
	*:*) printf '[%s]:%s' "$host" "$port" ;;
	*) printf '%s:%s' "$host" "$port" ;;
	esac
}

#######################################
# URL для проверки живости API.
# Outputs:
#   http://host:port/path
# Returns:
#   1, если адрес неоткуда взять
#######################################
core_watchdog_api_url() {
	local address="$CORE_WATCHDOG_API_ADDRESS"

	[ -n "$address" ] || address=$(core_watchdog_config_api_address) || return 1
	[ -n "$address" ] || return 1

	printf 'http://%s%s' "$(core_watchdog_normalize_address "$address")" "$CORE_WATCHDOG_API_PATH"
}

## --- тонкие обёртки ----------------------------------------------------------

#######################################
# Жив ли процесс ядра.
# Сначала спрашиваем init-скрипт, потом pidof - тем же порядком, что и
# установщик: procd знает про свой инстанс, но ядро могли запустить руками.
# Arguments:
#   name: имя бинарника
#######################################
_core_watchdog_process_running() {
	local name="$1" service
	service=$(core_service)

	if [ -x "$service" ]; then
		"$service" running > /dev/null 2>&1 && return 0
	fi

	[ -n "$name" ] || return 1
	pidof "$name" > /dev/null 2>&1
}

#######################################
# Достучаться до Clash API.
#
# Успехом считается любой HTTP-ответ, а не код 200. Это не небрежность: при
# заданном yacd_secret_key API отвечает 401 на запрос без заголовка
# Authorization, и 401 доказывает, что ядро живо и обрабатывает запросы, ровно
# так же, как 200. Сторожу этого достаточно, а секрет ему тогда не нужен вовсе.
#
# --noproxy: стучимся на локальный адрес, и http_proxy из окружения здесь может
# только навредить.
#
# Отсутствие curl - не повод объявлять ядро мёртвым: сторож, который
# перезапускает ядро из-за ненайденной программы, вреднее отсутствующего.
#
# Arguments:
#   url
#######################################
_core_watchdog_http_probe() {
	local url="$1"

	command -v curl > /dev/null 2>&1 || return 0

	curl -s -o /dev/null --noproxy '*' --max-time "$CORE_WATCHDOG_API_TIMEOUT" "$url" 2> /dev/null
}

#######################################
# Вернуть dnsmasq на рабочий резолвер.
#
# Зовём podkop, а не переписываем UCI сами. dnsmasq_restore внутри проверяет
# shutdown_correctly: если подкоп остановили штатно, dnsmasq уже возвращён и
# трогать его нельзя. Пока подкоп работает, флаг равен нулю - то есть при живом
# подкопе и мёртвом ядре восстановление отработает, а при остановленном подкопе
# ничего не сделает. Это ровно та семантика, которая нужна.
#######################################
_core_watchdog_dnsmasq_restore() {
	[ -x "$CORE_WATCHDOG_PODKOP_BIN" ] || return 1
	"$CORE_WATCHDOG_PODKOP_BIN" "$CORE_WATCHDOG_DNSMASQ_RESTORE_CMD" > /dev/null 2>&1
}

# Поднять ядро. Через слой ядра, поэтому какое именно ядро активно - не наше
# дело.
_core_watchdog_core_start() {
	core_service_start
}

## --- состояние ---------------------------------------------------------------

#######################################
# Прочитать поле состояния.
#
# Разбор через sed с проверкой на цифры прямо в шаблоне, а не через eval или
# точку: файл лежит в /tmp, и превращать его содержимое в исполняемый код
# незачем. Нет файла, нет поля, мусор в поле - всё это ноль.
#
# Arguments:
#   key: misses | attempts | first_attempt | last_attempt
# Outputs:
#   число
#######################################
core_watchdog_state_get() {
	local key="$1" value

	value=$(sed -n "s/^$key=\([0-9][0-9]*\)\$/\1/p" "$CORE_WATCHDOG_STATE_FILE" 2> /dev/null | head -n1)
	printf '%s' "${value:-0}"
}

#######################################
# Записать состояние целиком.
# Через временный файл и mv: сторож могут прибить посреди записи, и половина
# файла хуже, чем его отсутствие.
# Arguments:
#   misses, attempts, first_attempt, last_attempt
#######################################
core_watchdog_state_set() {
	local dir tmp

	dir=$(dirname "$CORE_WATCHDOG_STATE_FILE")
	[ -d "$dir" ] || mkdir -p "$dir" 2> /dev/null || return 1

	tmp="$CORE_WATCHDOG_STATE_FILE.tmp"
	{
		printf 'misses=%s\n' "${1:-0}"
		printf 'attempts=%s\n' "${2:-0}"
		printf 'first_attempt=%s\n' "${3:-0}"
		printf 'last_attempt=%s\n' "${4:-0}"
	} > "$tmp" 2> /dev/null || return 1

	mv -f "$tmp" "$CORE_WATCHDOG_STATE_FILE" 2> /dev/null
}

core_watchdog_state_reset() {
	core_watchdog_state_set 0 0 0 0
}

## --- чистые решения ----------------------------------------------------------

#######################################
# Пауза перед следующей попыткой. Чистая функция.
# Удваивается с каждой попыткой и упирается в потолок.
# Arguments:
#   attempts: сколько попыток уже сделано
# Outputs:
#   секунды
#######################################
core_watchdog_backoff() {
	local attempts="${1:-0}" delay="$CORE_WATCHDOG_COOLDOWN" i=1

	case "$attempts" in
	'' | *[!0-9]*) attempts=0 ;;
	esac

	while [ "$i" -lt "$attempts" ]; do
		delay=$((delay * 2))
		if [ "$delay" -ge "$CORE_WATCHDOG_COOLDOWN_MAX" ]; then
			delay="$CORE_WATCHDOG_COOLDOWN_MAX"
			break
		fi
		i=$((i + 1))
	done

	printf '%s' "$delay"
}

#######################################
# Истекло ли окно предохранителя. Чистая функция.
#
# Отдельно разбирается случай, когда часы ушли назад: у роутера нет RTC, он
# стартует в 1970 году и прыгает вперёд при первой же синхронизации по NTP.
# Обратный прыжок тоже бывает, и сторож не должен из-за него замолчать навсегда.
#
# Arguments:
#   now, first_attempt
# Returns:
#   0 если окно истекло (или ещё не начиналось)
#######################################
core_watchdog_window_expired() {
	local now="${1:-0}" first="${2:-0}" age

	[ "$first" -gt 0 ] || return 0

	age=$((now - first))
	[ "$age" -lt 0 ] && return 0

	[ "$age" -ge "$CORE_WATCHDOG_WINDOW" ]
}

#######################################
# Приговор по одной проверке. Чистая функция.
#
# Отдельно от decide, потому что отвечает на другой вопрос: decide решает, что
# делать с мёртвым ядром, а verdict решает, считать ли ядро мёртвым вообще.
# Один промах - это ещё не падение (см. CORE_WATCHDOG_MISSES).
#
# Arguments:
#   alive:  1 если проверка прошла
#   misses: сколько проверок подряд провалилось, включая текущую
# Outputs:
#   alive | watch | dead
#######################################
core_watchdog_verdict() {
	local alive="$1" misses="${2:-0}"

	if [ "$alive" = "1" ]; then
		printf 'alive'
		return 0
	fi

	case "$misses" in
	'' | *[!0-9]*) misses=0 ;;
	esac

	if [ "$misses" -ge "$CORE_WATCHDOG_MISSES" ]; then
		printf 'dead'
	else
		printf 'watch'
	fi
}

#######################################
# Что делать. Чистая функция: ничего не запускает, ничего не пишет, всё нужное
# получает аргументами.
#
# Arguments:
#   enabled:  1 если сторож включён
#   dead:     1 если падение подтверждено (см. core_watchdog_verdict)
#   now:      текущее время, секунды эпохи
#   attempts: попыток сделано за текущее окно
#   first:    время первой попытки окна
#   last:     время последней попытки
# Outputs:
#   disabled - сторож выключен
#   ok       - вмешиваться не во что
#   fuse     - попытки исчерпаны, только лог
#   wait     - кулдаун ещё не вышел
#   recover  - восстанавливать
#######################################
core_watchdog_decide() {
	local enabled="$1" dead="$2" now="${3:-0}" attempts="${4:-0}" first="${5:-0}" last="${6:-0}"
	local since

	if [ "$enabled" != "1" ]; then
		printf 'disabled'
		return 0
	fi

	if [ "$dead" != "1" ]; then
		printf 'ok'
		return 0
	fi

	# Окно истекло - прошлые попытки больше не считаются
	if core_watchdog_window_expired "$now" "$first"; then
		attempts=0
	fi

	if [ "$attempts" -ge "$CORE_WATCHDOG_ATTEMPTS" ]; then
		printf 'fuse'
		return 0
	fi

	if [ "$attempts" -gt 0 ]; then
		since=$((now - last))
		# Часы ушли назад - считаем, что пауза выдержана: лучше лишняя
		# попытка, чем сторож, залипший до перезагрузки
		if [ "$since" -ge 0 ] && [ "$since" -lt "$(core_watchdog_backoff "$attempts")" ]; then
			printf 'wait'
			return 0
		fi
	fi

	printf 'recover'
}

## --- живость -----------------------------------------------------------------

#######################################
# Живо ли ядро.
#
# Живым считается только то ядро, у которого И процесс на месте, И Clash API
# отвечает. Одного процесса мало: ядро умеет висеть, не обрабатывая запросы, и
# для пользователя это ничем не отличается от падения - DNS не резолвится,
# трафик не ходит, а pidof доволен.
#
# Если API в конфиге не настроен (или конфига ещё нет), судим по процессу и
# только по нему: объявлять ядро мёртвым из-за того, что нам нечем его
# спросить, нельзя.
#
# Returns:
#   0 если живо
#######################################
core_watchdog_core_alive() {
	local name url

	name=$(basename "$(core_binary)")
	_core_watchdog_process_running "$name" || return 1

	url=$(core_watchdog_api_url 2> /dev/null) || return 0
	[ -n "$url" ] || return 0

	_core_watchdog_http_probe "$url"
}

## --- восстановление ----------------------------------------------------------

#######################################
# Восстановление. Порядок здесь - главное в модуле.
#
#   1) dnsmasq возвращается на рабочий резолвер;
#   2) и только потом поднимается ядро.
#
# Менять местами нельзя. Пока ядро стартует (а оно может и не стартовать вовсе -
# битый конфиг, нет памяти, снесённый бинарник), dnsmasq продолжает пересылать
# все запросы в мёртвый 127.0.0.42, и роутер стоит без DNS - без всего, а не
# только без проксируемого. Шаг с dnsmasq дешёвый, детерминированный и не
# зависит от исхода второго шага, поэтому идёт первым.
#
# Неудача восстановления dnsmasq ядро поднимать не отменяет: поднявшееся ядро
# чинит DNS само.
#
# Returns:
#   0 если ядро после этого живо
#######################################
core_watchdog_recover() {
	local core
	core=$(core_current)

	_core_watchdog_log "Сторож: ядро $core не отвечает, восстанавливаю DNS" "error"

	# --- шаг 1: DNS ---
	if ! core_watchdog_dnsmasq_managed; then
		_core_watchdog_log "Сторож: dont_touch_dhcp включён, dnsmasq не трогаю" "debug"
	elif ! core_watchdog_dnsmasq_hijacked; then
		_core_watchdog_log "Сторож: dnsmasq не смотрит в ядро, восстанавливать нечего" "debug"
	elif _core_watchdog_dnsmasq_restore; then
		_core_watchdog_log "Сторож: dnsmasq возвращён на системный резолвер" "warn"
	else
		_core_watchdog_log "Сторож: не удалось вернуть dnsmasq, роутер может остаться без DNS" "error"
	fi

	# --- шаг 2: ядро ---
	_core_watchdog_log "Сторож: поднимаю $core" "warn"
	_core_watchdog_core_start

	_core_watchdog_sleep "$CORE_WATCHDOG_START_GRACE"

	if core_watchdog_core_alive; then
		# DNS-маршрутизацию обратно на ядро сторож не переводит сам:
		# dnsmasq_configure в подкопе отказывается работать при
		# shutdown_correctly=0, то есть при работающем подкопе. Говорим об этом
		# вслух, иначе пользователь будет гадать, почему проксирование по
		# доменам перестало работать после самопочинки.
		_core_watchdog_log "Сторож: $core поднят. DNS-маршрутизация через ядро выключена, вернуть её: podkop restart" "warn"
		return 0
	fi

	_core_watchdog_log "Сторож: $core не поднялся" "error"
	return 1
}

## --- проход ------------------------------------------------------------------

#######################################
# Одна проверка со всеми последствиями.
#
# Здесь и только здесь состояние читается, обновляется и записывается; решения
# принимают чистые функции выше.
#
# Returns:
#   см. «коды возврата» в шапке файла
#######################################
core_watchdog_tick() {
	local now stored_misses misses attempts first last alive verdict action

	if ! core_watchdog_enabled; then
		# Счётчики, накопленные до выключения, не должны дождаться включения
		if [ -f "$CORE_WATCHDOG_STATE_FILE" ]; then
			rm -f "$CORE_WATCHDOG_STATE_FILE"
		fi
		return 1
	fi

	now=$(_core_watchdog_now)
	stored_misses=$(core_watchdog_state_get misses)
	attempts=$(core_watchdog_state_get attempts)
	first=$(core_watchdog_state_get first_attempt)
	last=$(core_watchdog_state_get last_attempt)

	if core_watchdog_core_alive; then
		alive=1
		misses=0
	else
		alive=0
		misses=$((stored_misses + 1))
	fi

	verdict=$(core_watchdog_verdict "$alive" "$misses")

	# Подозрение: проверка провалилась, но порог промахов не набран. Ничего не
	# трогаем, только запоминаем промах.
	if [ "$verdict" = "watch" ]; then
		core_watchdog_state_set "$misses" "$attempts" "$first" "$last"
		_core_watchdog_log "Сторож: ядро не ответило (промах $misses из $CORE_WATCHDOG_MISSES)" "warn"
		return 2
	fi

	if [ "$verdict" = "dead" ]; then
		action=$(core_watchdog_decide 1 1 "$now" "$attempts" "$first" "$last")
	else
		action=$(core_watchdog_decide 1 0 "$now" "$attempts" "$first" "$last")
	fi

	case "$action" in
	ok)
		# Живое ядро закрывает историю падений: следующее падение начнёт
		# отсчёт заново и получит короткую первую паузу
		if [ "$attempts" -gt 0 ] || [ "$stored_misses" -gt 0 ]; then
			core_watchdog_state_reset
		fi
		return 0
		;;
	fuse)
		_core_watchdog_log "Сторож: попытки исчерпаны, жду конца окна" "debug"
		core_watchdog_state_set "$misses" "$attempts" "$first" "$last"
		return 4
		;;
	wait)
		core_watchdog_state_set "$misses" "$attempts" "$first" "$last"
		return 3
		;;
	esac

	# recover: окно могло истечь - тогда счётчик начинается заново
	if core_watchdog_window_expired "$now" "$first"; then
		attempts=0
		first=0
	fi
	attempts=$((attempts + 1))
	if [ "$attempts" -eq 1 ]; then
		first="$now"
	fi

	# Состояние пишется ДО попытки, а не после. Сторож могут прибить прямо
	# посреди восстановления, и попытка, о которой никто не записал, при
	# следующем запуске повторится немедленно - то есть предохранитель не
	# сработает ровно там, где он нужен.
	#
	# Промахи обнуляем: попытка сделана, дальше считаем с чистого листа.
	core_watchdog_state_set 0 "$attempts" "$first" "$now"

	if [ "$attempts" -ge "$CORE_WATCHDOG_ATTEMPTS" ]; then
		# Единственное громкое сообщение про предохранитель - в момент
		# срабатывания. Дальше он молчит в debug, иначе засорит лог на всё окно.
		_core_watchdog_log "Сторож: $attempts попыток за окно, больше не вмешиваюсь до конца окна" "error"
	fi

	if core_watchdog_recover; then
		return 5
	fi
	return 6
}

#######################################
# Бесконечный цикл проверок.
#
# Интервал и признак включённости перечитываются каждый проход: правка UCI
# должна доходить до сторожа сама, без перезапуска. Выключенный сторож не
# выходит, а продолжает спать - иначе включение опции требовало бы ещё и
# поднять сервис руками.
#######################################
core_watchdog_loop() {
	local ticks=0

	_core_watchdog_log "Сторож ядра запущен" "info"

	while :; do
		core_watchdog_tick
		ticks=$((ticks + 1))

		if [ "$CORE_WATCHDOG_TICKS" -gt 0 ] && [ "$ticks" -ge "$CORE_WATCHDOG_TICKS" ]; then
			break
		fi

		_core_watchdog_sleep "$(core_watchdog_interval)"
	done

	return 0
}
