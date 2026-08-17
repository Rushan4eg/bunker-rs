# Списки правил для clash-rs.
#
# Подкоп кормит sing-box бинарными .srs из релизов itdoginfo/allow-domains.
# clash-rs формат .srs не читает вовсе, поэтому для него берутся те же самые
# списки, но в текстовом виде из main-ветки того же репозитория:
#
#   Russia/inside-raw.lst, Russia/outside-raw.lst, Ukraine/inside-raw.lst
#   Categories/<имя>.lst   - geoblock, block, porn, news, anime, hodca
#   Services/<имя>.lst     - youtube, telegram, discord, meta, ...
#   Subnets/IPv4/<имя>.lst - подсети
#
# Дальше сырой список превращается в payload rule-provider'а. У Clash провайдер
# описывается тремя вещами:
#
#   behavior: domain | ipcidr | classical - что лежит внутри
#   format:   yaml | text                 - как оно записано
#   type:     http | file                 - кто это качает
#
# behavior не угадывается по имени файла, а определяется по содержимому: у
# пользователя в remote_domain_lists может лежать что угодно, а провайдер с
# неверным behavior clash-rs просто не примет.
#
# Тип провайдера здесь file, а не http: скачиванием занимается сам подкоп.
# Так список успевает пройти чистку и конвертацию, а главное - ретраи с
# нарастающей паузой остаются под нашим контролем (см. clash_rs_download_list).
#
# Использование:
#   url=$(clash_rs_list_url telegram domains)
#   json=$(clash_rs_prepare_community_list telegram domains /tmp/clash-rs/rulesets)
#   # json кладётся в конфиг под ключ rule-providers.<имя>
#
# shellcheck shell=ash

## --- параметры --------------------------------------------------------------
# Все через :- чтобы их можно было переопределить снаружи: из podkop, из
# тестов или руками при отладке на роутере.

# Текстовые списки лежат в main-ветке, а не в релизах: в релизах только .srs
CLASH_RS_LISTS_BASE_URL="${CLASH_RS_LISTS_BASE_URL:-https://raw.githubusercontent.com/itdoginfo/allow-domains/main}"

# Ретраи скачивания.
#
# В оригинальном download_to_file три попытки идут подряд с паузой в 2 секунды,
# и это ровно тот случай, когда ретраи бесполезны: raw.githubusercontent.com
# отдаёт 429 Too Many Requests с окном в десятки секунд, и все три попытки
# укладываются в одно и то же окно. Поэтому пауза растёт вдвое с каждой
# попыткой, а на 429 стартовая пауза заведомо больше окна лимита.
#
# Худший случай подобран так, чтобы не превратить запуск подкопа в ожидание:
#   обычная ошибка - 5 + 10 + 20  = 35 секунд на 4 попытки
#   429            - 30 + 60 + 120 = 3.5 минуты на 4 попытки
CLASH_RS_DOWNLOAD_RETRIES="${CLASH_RS_DOWNLOAD_RETRIES:-4}"
CLASH_RS_DOWNLOAD_BASE_DELAY="${CLASH_RS_DOWNLOAD_BASE_DELAY:-5}"
CLASH_RS_DOWNLOAD_RATE_LIMIT_DELAY="${CLASH_RS_DOWNLOAD_RATE_LIMIT_DELAY:-30}"
CLASH_RS_DOWNLOAD_MAX_DELAY="${CLASH_RS_DOWNLOAD_MAX_DELAY:-120}"
CLASH_RS_DOWNLOAD_TIMEOUT="${CLASH_RS_DOWNLOAD_TIMEOUT:-60}"

# Формат payload по умолчанию. yaml понимают и clash-rs, и mihomo; text
# поддержан не везде, поэтому он остаётся выбором вызывающего.
CLASH_RS_DEFAULT_FORMAT="${CLASH_RS_DEFAULT_FORMAT:-yaml}"

## --- служебное --------------------------------------------------------------

# Логи есть только внутри подкопа; в тестах и при ручном запуске модуль должен
# работать молча, а не падать на отсутствующей функции log.
#
# Проверяется именно функция: command -v для функции печатает её имя, а для
# внешней программы - путь. Просто на наличие команды проверять нельзя, на
# машине разработчика в PATH может лежать посторонний бинарник с именем log.
_clash_rs_log() {
	case "$(command -v log 2> /dev/null)" in
	log) log "$1" "${2:-info}" ;;
	esac
	return 0
}

# jq на роутере системный, в тестах подсовывается через JQ=
_clash_rs_jq() {
	"${JQ:-jq}" "$@"
}

# Обёртки вокруг задержки: тесты подменяют их, чтобы не спать по-настоящему
_clash_rs_sleep() {
	sleep "$1"
}

# Джиттер, чтобы десяток роутеров не долбился в лимит синхронно
_clash_rs_jitter() {
	echo $((($$ + ${1:-0}) % 5))
}

## --- разбор списков ---------------------------------------------------------
#
# Разбор строк живёт в awk, а не в цикле while read: в Russia/inside-raw.lst
# под сотню тысяч строк, и на каждую строку запускать grep или sed на роутере
# нельзя - это минуты работы вместо секунды.

# Общие функции awk, подключаются ко всем программам ниже
_CLASH_RS_AWK_LIB='
# Убирает CR, комментарии (#, ;, //) и пробелы по краям
function _clean(s) {
	sub(/\r$/, "", s)
	sub(/#.*/, "", s)
	sub(/;.*/, "", s)
	sub(/\/\/.*/, "", s)
	sub(/^[ \t]+/, "", s)
	sub(/[ \t]+$/, "", s)
	return s
}

# Строка уже в формате classical: DOMAIN-SUFFIX,example.com
function _is_classical(s) {
	return (s ~ /^[A-Z][A-Z0-9-]*,/)
}

# Возвращает v4, v6 или пустую строку. Маска необязательна
function _ip_kind(s,   body, mask, parts, n, i) {
	body = s
	mask = ""
	if (index(s, "/") > 0) {
		mask = substr(s, index(s, "/") + 1)
		body = substr(s, 1, index(s, "/") - 1)
		if (mask == "" || mask ~ /[^0-9]/) return ""
	}
	if (body ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
		n = split(body, parts, ".")
		if (n != 4) return ""
		for (i = 1; i <= 4; i++) {
			if (length(parts[i]) > 3 || parts[i] + 0 > 255) return ""
		}
		if (mask != "" && mask + 0 > 32) return ""
		return "v4"
	}
	if (index(body, ":") > 0 && body ~ /^[0-9A-Fa-f:]+$/) {
		if (mask != "" && mask + 0 > 128) return ""
		return "v6"
	}
	return ""
}

# Домен, возможно с ведущей точкой или маской: .ua, +.example.com, *.example.com
function _is_domain(s) {
	s = _domain_body(s)
	if (s == "") return 0
	# последняя метка не может быть числом: так отсекается битый адрес вроде
	# 999.1.1.1, который иначе прошёл бы как домен и испортил бы behavior
	if (s ~ /(^|\.)[0-9]+$/) return 0
	return (s ~ /^[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]*[a-z0-9_])?)*$/)
}

# Домен без ведущих точек и масок, в нижнем регистре
function _domain_body(s) {
	s = tolower(s)
	sub(/^\+\./, "", s)
	sub(/^\*\./, "", s)
	sub(/^\./, "", s)
	return s
}

# Голый адрес превращается в /32 или /128: behavior ipcidr требует маску
function _cidr_norm(s, kind) {
	if (index(s, "/") > 0) return s
	if (kind == "v4") return s "/32"
	return s "/128"
}

# Разбирает строку в глобальные ENTRY_KIND (v4|v6|domain), ENTRY_VALUE и
# ENTRY_CTYPE (тип правила, если строка уже была в формате classical).
# Возвращает 0, если строку в payload тащить не надо
function _classify(line,   pos, ctype, value, kind) {
	ENTRY_KIND = ""
	ENTRY_VALUE = ""
	ENTRY_CTYPE = ""
	if (_is_classical(line)) {
		pos = index(line, ",")
		ctype = substr(line, 1, pos - 1)
		value = substr(line, pos + 1)
		# в payload у правила не бывает цели: PROXY из DOMAIN,x,PROXY лишний
		if (index(value, ",") > 0) value = substr(value, 1, index(value, ",") - 1)
		sub(/^[ \t]+/, "", value)
		sub(/[ \t]+$/, "", value)
		ENTRY_CTYPE = ctype
		kind = _ip_kind(value)
		if (kind != "") {
			ENTRY_KIND = kind
			ENTRY_VALUE = value
			return 1
		}
		if (_is_domain(value)) {
			ENTRY_KIND = "domain"
			ENTRY_VALUE = value
			return 1
		}
		return 0
	}
	kind = _ip_kind(line)
	if (kind != "") {
		ENTRY_KIND = kind
		ENTRY_VALUE = line
		return 1
	}
	if (_is_domain(line)) {
		ENTRY_KIND = "domain"
		ENTRY_VALUE = line
		return 1
	}
	return 0
}
'

#######################################
# Чистит сырой список: CRLF, комментарии, пробелы по краям, пустые строки.
# Строки не проверяются на осмысленность - это работа behavior и payload.
# Дубликаты сознательно не схлопываются: на списке в сотню тысяч строк это
# лишние мегабайты в памяти роутера, а itdoginfo и так отдаёт уникальные.
# Arguments:
#   src: путь к сырому файлу
# Outputs:
#   очищенные строки
#######################################
clash_rs_clean_list() {
	local src="$1"

	[ -f "$src" ] || return 1

	awk "$_CLASH_RS_AWK_LIB"'
	{
		line = _clean($0)
		if (line == "") next
		print line
	}
	' "$src"
}

# Определение behavior по потоку на stdin
_clash_rs_detect_stream() {
	awk "$_CLASH_RS_AWK_LIB"'
	{
		line = _clean($0)
		if (line == "") next
		if (_is_classical(line)) { classical++; next }
		if (_ip_kind(line) != "") { ip++; next }
		if (_is_domain(line)) { domain++; next }
		junk++
	}
	END {
		# classical - единственный behavior, который держит и то и другое
		if (classical > 0) { print "classical"; exit 0 }
		if (ip > 0 && domain > 0) { print "classical"; exit 0 }
		if (ip > 0) { print "ipcidr"; exit 0 }
		if (domain > 0) { print "domain"; exit 0 }
		exit 1
	}
	'
}

#######################################
# Определяет behavior провайдера по содержимому списка.
#   только подсети         -> ipcidr
#   только домены          -> domain
#   вперемешку либо готовые правила вида DOMAIN-SUFFIX,x -> classical
# Arguments:
#   src: путь к списку (сырому, чистка внутри)
# Outputs:
#   domain | ipcidr | classical
# Returns:
#   1, если полезных строк в списке нет
#######################################
clash_rs_detect_behavior() {
	local src="$1"

	[ -f "$src" ] || return 1

	_clash_rs_detect_stream < "$src"
}

# Сборка payload по потоку на stdin
_clash_rs_build_stream() {
	local behavior="$1" format="${2:-$CLASH_RS_DEFAULT_FORMAT}"

	awk -v behavior="$behavior" -v format="$format" "$_CLASH_RS_AWK_LIB"'
	BEGIN {
		q = "\047"
		if (format != "text" && format != "yaml") { bad = 2; exit }
		if (behavior != "domain" && behavior != "ipcidr" && behavior != "classical") { bad = 3; exit }
		if (format == "yaml") print "payload:"
	}
	{
		line = _clean($0)
		if (line == "") next
		if (!_classify(line)) { dropped++; next }

		entry = ""
		if (behavior == "ipcidr") {
			if (ENTRY_KIND == "domain") { dropped++; next }
			entry = _cidr_norm(ENTRY_VALUE, ENTRY_KIND)
		} else if (behavior == "domain") {
			if (ENTRY_KIND != "domain") { dropped++; next }
			body = _domain_body(ENTRY_VALUE)
			if (body == "") { dropped++; next }
			if (ENTRY_CTYPE == "DOMAIN") {
				# точное совпадение так точным и остаётся
				entry = body
			} else if (ENTRY_CTYPE != "" && ENTRY_CTYPE != "DOMAIN-SUFFIX") {
				# DOMAIN-KEYWORD и подобное в behavior domain не выражается
				dropped++
				next
			} else if (substr(ENTRY_VALUE, 1, 2) == "*.") {
				entry = "*." body
			} else {
				# sing-box матчил domain_suffix, у Clash тот же смысл даёт +.
				entry = "+." body
			}
		} else {
			if (ENTRY_CTYPE != "") {
				# строка уже была правилом: тип сохраняем, значение чистим
				if (ENTRY_KIND == "domain") entry = ENTRY_CTYPE "," _domain_body(ENTRY_VALUE)
				else entry = ENTRY_CTYPE "," _cidr_norm(ENTRY_VALUE, ENTRY_KIND)
			} else if (ENTRY_KIND == "domain") {
				body = _domain_body(ENTRY_VALUE)
				if (body == "") { dropped++; next }
				entry = "DOMAIN-SUFFIX," body
			} else if (ENTRY_KIND == "v6") {
				entry = "IP-CIDR6," _cidr_norm(ENTRY_VALUE, ENTRY_KIND)
			} else {
				entry = "IP-CIDR," _cidr_norm(ENTRY_VALUE, ENTRY_KIND)
			}
		}

		count++
		if (format == "yaml") print "  - " q entry q
		else print entry
	}
	END {
		if (bad) exit bad
		if (count == 0) exit 1
	}
	'
}

#######################################
# Собирает payload провайдера из сырого списка.
# Строки, не подходящие под behavior, отбрасываются: в провайдере с
# behavior ipcidr домену взяться неоткуда, clash-rs на нём споткнётся.
# Arguments:
#   src: путь к сырому списку
#   behavior: domain | ipcidr | classical
#   format: yaml | text (по умолчанию yaml)
# Outputs:
#   готовый payload
# Returns:
#   1 если подходящих строк не нашлось, 2/3 при неверных format/behavior
#######################################
clash_rs_build_payload() {
	local src="$1" behavior="$2" format="${3:-$CLASH_RS_DEFAULT_FORMAT}"

	[ -f "$src" ] || return 1

	_clash_rs_build_stream "$behavior" "$format" < "$src"
}

#######################################
# Сырой список -> файл payload. Behavior определяется сам, если не задан.
# Arguments:
#   src: сырой список
#   dst: куда положить payload
#   format: yaml | text (по умолчанию yaml)
#   behavior: необязательно, иначе определяется по содержимому
# Outputs:
#   выбранный behavior - его надо положить в описание провайдера
#######################################
clash_rs_convert_list() {
	local src="$1" dst="$2" format="${3:-$CLASH_RS_DEFAULT_FORMAT}" behavior="$4"
	local cleaned rc

	[ -f "$src" ] || return 1

	cleaned="$(mktemp)" || return 1
	clash_rs_clean_list "$src" > "$cleaned"

	if [ ! -s "$cleaned" ]; then
		_clash_rs_log "Список $src пуст после чистки" "warn"
		rm -f "$cleaned"
		return 1
	fi

	if [ -z "$behavior" ]; then
		behavior="$(_clash_rs_detect_stream < "$cleaned")"
		if [ -z "$behavior" ]; then
			_clash_rs_log "Не удалось определить behavior для $src" "error"
			rm -f "$cleaned"
			return 1
		fi
	fi

	_clash_rs_build_stream "$behavior" "$format" < "$cleaned" > "$dst"
	rc=$?
	rm -f "$cleaned"

	if [ "$rc" -ne 0 ]; then
		_clash_rs_log "Не удалось собрать payload для $src (behavior $behavior)" "error"
		rm -f "$dst"
		return 1
	fi

	printf '%s\n' "$behavior"
}

## --- скачивание -------------------------------------------------------------

#######################################
# Пауза перед очередной попыткой: base * 2^(attempt-1), но не больше max.
# Вынесено отдельно, потому что это единственная часть ретраев, которую
# имеет смысл проверять тестом.
# Arguments:
#   attempt: номер попытки, начиная с 1
#   base: стартовая пауза в секундах
#   max: потолок
#######################################
_clash_rs_backoff_delay() {
	local attempt="${1:-1}" base="${2:-5}" max="${3:-300}"
	local delay="$base" i=1

	while [ "$i" -lt "$attempt" ]; do
		delay=$((delay * 2))
		i=$((i + 1))
	done

	[ "$delay" -gt "$max" ] && delay="$max"
	echo "$delay"
}

#######################################
# Одна попытка скачивания.
# Returns:
#   0 - успех
#   2 - 429 Too Many Requests, лимит на стороне сервера
#   1 - любая другая ошибка
#######################################
_clash_rs_fetch() {
	local url="$1" dst="$2" proxy="$3"
	local code rc errfile

	if command -v curl > /dev/null 2>&1; then
		if [ -n "$proxy" ]; then
			code="$(curl -sS -L --max-time "$CLASH_RS_DOWNLOAD_TIMEOUT" -x "http://$proxy" \
				-o "$dst" -w '%{http_code}' "$url" 2> /dev/null)"
		else
			code="$(curl -sS -L --max-time "$CLASH_RS_DOWNLOAD_TIMEOUT" \
				-o "$dst" -w '%{http_code}' "$url" 2> /dev/null)"
		fi
		rc=$?
		[ "$rc" -ne 0 ] && return 1
		case "$code" in
		2??) return 0 ;;
		429) return 2 ;;
		*) return 1 ;;
		esac
	fi

	# busybox wget кода возврата HTTP не отдаёт, поэтому 429 ищется в тексте
	# ошибки: и busybox, и GNU wget пишут номер статуса в stderr
	errfile="$(mktemp)" || return 1
	if [ -n "$proxy" ]; then
		http_proxy="http://$proxy" https_proxy="http://$proxy" \
			wget -T "$CLASH_RS_DOWNLOAD_TIMEOUT" -O "$dst" "$url" 2> "$errfile"
	else
		wget -T "$CLASH_RS_DOWNLOAD_TIMEOUT" -O "$dst" "$url" 2> "$errfile"
	fi
	rc=$?

	if [ "$rc" -eq 0 ]; then
		rm -f "$errfile"
		return 0
	fi
	if grep -q '429' "$errfile"; then
		rm -f "$errfile"
		return 2
	fi
	rm -f "$errfile"
	return 1
}

#######################################
# Скачивает список с ретраями и нарастающей паузой.
# Arguments:
#   url: откуда
#   dst: куда
#   proxy: адрес http-прокси (необязательно)
#   retries: число попыток (по умолчанию CLASH_RS_DOWNLOAD_RETRIES)
# Returns:
#   0 если файл скачан и не пуст
#######################################
clash_rs_download_list() {
	local url="$1" dst="$2" proxy="$3" retries="${4:-$CLASH_RS_DOWNLOAD_RETRIES}"
	local attempt=1 rc base delay

	while :; do
		_clash_rs_fetch "$url" "$dst" "$proxy"
		rc=$?

		if [ "$rc" -eq 0 ] && [ -s "$dst" ]; then
			return 0
		fi
		rm -f "$dst"

		[ "$attempt" -ge "$retries" ] && break

		if [ "$rc" -eq 2 ]; then
			# 429 живёт десятками секунд: ретрай через пару секунд попадёт
			# в то же окно лимита и только продлит его
			base="$CLASH_RS_DOWNLOAD_RATE_LIMIT_DELAY"
			_clash_rs_log "429 Too Many Requests от $url" "warn"
		else
			base="$CLASH_RS_DOWNLOAD_BASE_DELAY"
		fi

		delay="$(_clash_rs_backoff_delay "$attempt" "$base" "$CLASH_RS_DOWNLOAD_MAX_DELAY")"
		delay=$((delay + $(_clash_rs_jitter "$attempt")))
		_clash_rs_log "Попытка $attempt/$retries скачать $url не удалась, пауза ${delay}s" "warn"
		_clash_rs_sleep "$delay"

		attempt=$((attempt + 1))
	done

	_clash_rs_log "Не удалось скачать $url за $retries попыток" "error"
	return 1
}

## --- адреса списков itdoginfo ----------------------------------------------

#######################################
# URL текстового списка по имени сервиса подкопа.
# Имена совпадают с COMMUNITY_SERVICES из constants.sh; раскладка по каталогам
# у itdoginfo своя, поэтому карта здесь, а не в имени файла.
# Arguments:
#   service: например telegram, russia_inside, geoblock
#   kind: domains | subnets | subnets6 (по умолчанию domains)
# Returns:
#   1, если такого списка у itdoginfo нет
#######################################
clash_rs_list_url() {
	local service="$1" kind="${2:-domains}" path=""

	case "$kind" in
	domains)
		case "$service" in
		russia_inside) path="Russia/inside-raw.lst" ;;
		russia_outside) path="Russia/outside-raw.lst" ;;
		ukraine_inside) path="Ukraine/inside-raw.lst" ;;
		geoblock | block | porn | news | anime | hodca)
			path="Categories/$service.lst"
			;;
		youtube | hdrezka | tiktok | google_ai | google_play | google_meet | discord | meta | twitter | cloudflare | cloudfront | digitalocean | hetzner | ovh | telegram | roblox)
			path="Services/$service.lst"
			;;
		esac
		;;
	subnets | subnets4)
		case "$service" in
		cloudflare | cloudfront | digitalocean | discord | google_meet | hetzner | meta | ovh | roblox | telegram | twitter)
			path="Subnets/IPv4/$service.lst"
			;;
		esac
		;;
	subnets6)
		case "$service" in
		cloudflare | cloudfront | digitalocean | discord | google_meet | hetzner | meta | ovh | telegram | twitter)
			path="Subnets/IPv6/$service.lst"
			;;
		esac
		;;
	esac

	if [ -z "$path" ]; then
		_clash_rs_log "У itdoginfo нет списка '$service' типа '$kind'" "error"
		return 1
	fi

	printf '%s/%s\n' "$CLASH_RS_LISTS_BASE_URL" "$path"
}

## --- описание провайдеров ---------------------------------------------------

#######################################
# Имя ключа в rule-providers. Ровно как get_ruleset_tag у sing-box, только
# постфикс другой: в конфиге Clash это ключ карты, а не тег правила.
#######################################
clash_rs_provider_name() {
	local section="$1" name="$2" type="$3"

	if [ -n "$type" ]; then
		echo "$section-$name-$type-provider"
	else
		echo "$section-$name-provider"
	fi
}

#######################################
# Описание провайдера, который читает готовый файл с диска.
# Путь должен быть абсолютным: относительный clash-rs считает от своего
# рабочего каталога, а он не совпадает с каталогом конфига.
# Arguments:
#   behavior, format, path
#######################################
clash_rs_file_provider_json() {
	local behavior="$1" format="${2:-$CLASH_RS_DEFAULT_FORMAT}" path="$3"

	# shellcheck disable=SC2016  # $behavior и прочее - переменные jq, не шелла
	_clash_rs_jq -n \
		--arg behavior "$behavior" \
		--arg format "$format" \
		--arg path "$path" \
		'{type: "file", behavior: $behavior, format: $format, path: $path}'
}

#######################################
# Описание провайдера, который clash-rs качает сам.
# Годится там, где behavior известен заранее (подсети itdoginfo - всегда
# ipcidr), но ретраи при 429 остаются на совести ядра.
# Arguments:
#   behavior, format, url, path, interval (1d/12h/3600, по умолчанию 1d)
#######################################
clash_rs_http_provider_json() {
	local behavior="$1" format="${2:-$CLASH_RS_DEFAULT_FORMAT}" url="$3" path="$4" interval="${5:-1d}"
	local seconds

	seconds="$(clash_rs_interval_to_seconds "$interval")" || return 1

	# shellcheck disable=SC2016  # $behavior и прочее - переменные jq, не шелла
	_clash_rs_jq -n \
		--arg behavior "$behavior" \
		--arg format "$format" \
		--arg url "$url" \
		--arg path "$path" \
		--argjson interval "$seconds" \
		'{type: "http", behavior: $behavior, format: $format, url: $url, path: $path, interval: $interval}'
}

#######################################
# Интервал подкопа (1d, 12h, 30m) в секунды: у Clash interval - число.
#######################################
clash_rs_interval_to_seconds() {
	local raw="${1:-1d}" num unit

	num="${raw%[smhdSMHD]}"
	unit="${raw#"$num"}"

	case "$num" in
	'' | *[!0-9]*) return 1 ;;
	esac

	case "$unit" in
	'' | s | S) echo "$num" ;;
	m | M) echo $((num * 60)) ;;
	h | H) echo $((num * 3600)) ;;
	d | D) echo $((num * 86400)) ;;
	*) return 1 ;;
	esac
}

## --- сборка целиком ---------------------------------------------------------

#######################################
# Скачать список по URL и разложить его в готовый payload.
# Arguments:
#   url: адрес списка
#   dst: файл payload
#   format: yaml | text
#   proxy: http-прокси для скачивания (необязательно)
# Outputs:
#   определённый behavior
#######################################
clash_rs_prepare_remote_list() {
	local url="$1" dst="$2" format="${3:-$CLASH_RS_DEFAULT_FORMAT}" proxy="$4"
	local raw behavior

	raw="$(mktemp)" || return 1

	if ! clash_rs_download_list "$url" "$raw" "$proxy"; then
		rm -f "$raw"
		return 1
	fi

	behavior="$(clash_rs_convert_list "$raw" "$dst" "$format")"
	if [ -z "$behavior" ]; then
		rm -f "$raw"
		return 1
	fi
	rm -f "$raw"

	printf '%s\n' "$behavior"
}

#######################################
# Готовит провайдер для списка сообщества (бывший .srs).
# Кладёт payload в <dir>/<service>-<kind>.lst и печатает описание провайдера.
# Arguments:
#   service: telegram, russia_inside, ...
#   kind: domains | subnets | subnets6
#   dir: каталог для payload
#   format: yaml | text
#   proxy: http-прокси (необязательно)
# Outputs:
#   JSON описания провайдера для rule-providers
#######################################
clash_rs_prepare_community_list() {
	local service="$1" kind="${2:-domains}" dir="$3"
	local format="${4:-$CLASH_RS_DEFAULT_FORMAT}" proxy="$5"
	local url dst behavior

	url="$(clash_rs_list_url "$service" "$kind")" || return 1

	mkdir -p "$dir" || return 1
	dst="$dir/$service-$kind.lst"

	behavior="$(clash_rs_prepare_remote_list "$url" "$dst" "$format" "$proxy")"
	if [ -z "$behavior" ]; then
		_clash_rs_log "Список $service ($kind) подготовить не удалось" "error"
		return 1
	fi

	clash_rs_file_provider_json "$behavior" "$format" "$dst"
}
