# Фасад конфигурации clash-rs.
#
# Слой между подкопом и менеджером конфига. Наружу торчат функции clash_cf_*:
# они принимают то, что лежит в UCI (ссылку на прокси, домен, адрес DNS), и
# превращают это в объекты схемы clash-rs. Соответствие полей sing-box -> Clash
# описано в docs/mapping.md, здесь оно реализовано.
#
# Главное здесь - разбор ссылок на прокси. Отличие от sing_box_config_facade.sh
# не в разборе, а в том, как собирается результат. У sing-box tls и transport -
# вложенные объекты, и фасад доливал их отдельными вызовами менеджера по тегу
# выхода. У Clash поля прокси плоские: tls, servername, network, ws-opts лежат
# рядом с server и port. Поэтому объект собирается целиком здесь и уходит
# менеджеру одним куском - менеджеру не приходится потом искать прокси по имени,
# чтобы дописать ему поле.
#
# Что фасад берёт у менеджера (clash_config_manager.sh):
#   clash_cm_add_raw_proxy           config name proxy_json
#   clash_cm_set_interface_for_proxy config name interface
#   clash_cm_add_nameserver          config type address port path
#   clash_cm_set_mixed_port          config port
#   clash_cm_add_rule                config type value target
#   clash_cm_add_reject_rule         config type value
#
# Пофункциональные сборщики менеджера (clash_cm_add_vless_proxy и соседи)
# фасад намеренно обходит: разбор ссылки собирает объект целиком, включая
# hysteria2, которого у менеджера нет вовсе, и отдаёт готовое в add_raw_proxy.
#
# Ошибки. Фасад зовут через $( ), поэтому провал разбора нельзя оставлять тихим:
# вызывающий получил бы пустую строку вместо конфига и ничего не понял. Каждая
# нераспознанная ссылка пишется в syslog и в stderr, а функция возвращает 1 и не
# печатает в stdout ничего.
#
# shellcheck shell=ash

PODKOP_LIB="${PODKOP_LIB:-/usr/lib/podkop}"

# Зависимости подключаем, только если их ещё нет в оболочке. На роутере это
# обычный сорсинг, а в тестах модуль можно поднять с заглушками вместо logger и
# менеджера, которого на машине разработчика нет.
if ! command -v log >/dev/null 2>&1; then
	if [ -f "$PODKOP_LIB/logging.sh" ]; then
		. "$PODKOP_LIB/logging.sh"
	else
		log() { :; }
	fi
fi

if ! command -v url_get_query_param >/dev/null 2>&1 && [ -f "$PODKOP_LIB/helpers.sh" ]; then
	. "$PODKOP_LIB/helpers.sh"
fi

if ! command -v clash_cm_add_raw_proxy >/dev/null 2>&1 && [ -f "$PODKOP_LIB/clash_config_manager.sh" ]; then
	. "$PODKOP_LIB/clash_config_manager.sh"
fi

## --- служебное --------------------------------------------------------------

#######################################
# Сообщить о нераспознанной ссылке и провалиться.
# Пишет и в syslog, как весь подкоп, и в stderr: фасад вызывают из $( ), stdout
# там забирает вызывающий, и без stderr пользователь увидел бы только пустой
# конфиг без единого слова о причине.
# Arguments:
#   message: string, текст ошибки
# Outputs:
#   Пишет сообщение в stderr
# Returns:
#   1 всегда
# Example:
#   _clash_fail "неизвестная схема 'vmess'" && return 1
#######################################
_clash_fail() {
	local message="$1"

	log "clash facade: $message" "error"
	printf 'podkop: %s\n' "$message" >&2

	return 1
}

#######################################
# Обрезать пробелы и переводы строк по краям строки.
# Ссылки приезжают из UCI, где после копипасты легко остаётся хвост.
# Arguments:
#   value: string
# Outputs:
#   Обрезанная строка
# Example:
#   url=$(_clash_trim "  vless://... ")
#######################################
_clash_trim() {
	printf '%s' "$1" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

#######################################
# Раскодировать percent-encoding: %2F -> /.
#
# url_decode из helpers.sh намеренно не используется: он заодно превращает '+' в
# пробел (это правило форм, а не URL) и портит пароли shadowsocks вида
# "dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=". Здесь преобразуются только
# полные тройки %XX, а одиночный '%' в пароле остаётся собой.
# Arguments:
#   value: string, значение с percent-encoding
# Outputs:
#   Раскодированная строка
# Example:
#   path=$(_clash_url_decode "%2Fwspath")   # -> /wspath
#######################################
_clash_url_decode() {
	local value escaped

	value="$1"
	[ -n "$value" ] || return 0

	# Восьмеричные escape, а не шестнадцатеричные. \xNN понимают busybox и
	# bash, но не dash - а он стоит /bin/sh в ubuntu и гоняет наш CI. На
	# этом набор молча зеленел под одной оболочкой и краснел под другой,
	# причём падали ровно все проверки percent-encoding. \NNN требует POSIX,
	# его понимают все три.
	#
	# Перевод одним проходом awk: он есть везде, где есть подкоп, а
	# посимвольный цикл на shell стоил бы по процессу на байт.
	escaped=$(printf '%s' "$value" | awk '
		BEGIN {
			h = "0123456789abcdef"
			for (i = 0; i < 16; i++) {
				c = substr(h, i + 1, 1)
				v[c] = i
				v[toupper(c)] = i
			}
		}
		{
			out = ""
			n = length($0)
			i = 1
			while (i <= n) {
				c = substr($0, i, 1)
				if (c == "%" && i + 2 <= n) {
					a = substr($0, i + 1, 1)
					b = substr($0, i + 2, 1)
					if ((a in v) && (b in v)) {
						# Ведущий ноль обязателен. Без него escape
						# слипается со следующей цифрой: "http%2F1.1"
						# даёт "\0571.1", printf читает 571 как одно
						# восьмеричное число и выдаёт "httpy.1".
						# Форма \0 + ровно три цифры однозначна.
						out = out sprintf("\\0%03o", v[a] * 16 + v[b])
						i = i + 3
						continue
					}
				}
				# обратный слэш экранируем, иначе printf %b примет его
				# за начало собственной последовательности
				if (c == "\\") out = out "\\\\"
				else out = out c
				i = i + 1
			}
			printf "%s", out
		}')

	printf '%b' "$escaped"
}

#######################################
# Вернуть якорь ссылки (то, что после первого '#').
# В ссылках на прокси там лежит имя, которое показывает клиент.
# Arguments:
#   url: string
# Outputs:
#   Содержимое якоря, как есть, без раскодирования
# Example:
#   _clash_url_get_fragment "vless://u@h:443#Home"   # -> Home
#######################################
_clash_url_get_fragment() {
	local url="$1"

	case "$url" in
	*'#'*) printf '%s' "${url#*#}" ;;
	*) printf '%s' "" ;;
	esac
}

#######################################
# Вернуть порт из URL.
# Своя реализация вместо url_get_port из helpers.sh: та написана на bash-синтаксисе
# ([[ ]] и && || как тернарник), а этот модуль должен оставаться POSIX sh.
# Порядок разбора тот же, что у url_get_host, иначе адрес и порт разъехались бы
# на ссылках, где в userinfo есть '/' (shadowsocks с base64-паролем).
# Arguments:
#   url: string
# Outputs:
#   Порт или пустая строка
# Example:
#   _clash_url_get_port "ss://x@127.0.0.1:25144?type=tcp"   # -> 25144
#######################################
_clash_url_get_port() {
	local url="$1"

	url="${url#*://}"
	url="${url#*@}"
	url="${url%%[/?#]*}"

	case "$url" in
	*:*) printf '%s' "${url#*:}" ;;
	*) printf '%s' "" ;;
	esac
}

#######################################
# Вернуть схему URL в нижнем регистре.
# Arguments:
#   url: string
# Outputs:
#   Схема без "://"
# Example:
#   _clash_url_scheme "VLESS://u@h:443"   # -> vless
#######################################
_clash_url_scheme() {
	url_get_scheme "$1" | tr 'A-Z' 'a-z'
}

#######################################
# Вернуть раскодированное значение параметра запроса.
# Arguments:
#   url: string
#   param: string, имя параметра
# Outputs:
#   Значение параметра или пустая строка
# Example:
#   _clash_query "vless://u@h:443?path=%2Fws" "path"   # -> /ws
#######################################
_clash_query() {
	_clash_url_decode "$(url_get_query_param "$1" "$2")"
}

#######################################
# Вернуть флаг "не проверять сертификат".
# Клиенты пишут его двумя именами, встречаются оба.
# Arguments:
#   url: string
# Outputs:
#   Значение allowInsecure либо insecure
# Example:
#   _clash_query_insecure "trojan://p@h:443?allowInsecure=1"   # -> 1
#######################################
_clash_query_insecure() {
	local url="$1"

	local insecure
	insecure=$(_clash_query "$url" "allowInsecure")
	[ -n "$insecure" ] || insecure=$(_clash_query "$url" "insecure")

	printf '%s' "$insecure"
}

#######################################
# Проверить, что строка - номер порта.
# Arguments:
#   value: string
# Returns:
#   0 если это число от 1 до 65535
# Example:
#   _clash_is_port "443" && echo ok
#######################################
_clash_is_port() {
	case "$1" in
	"" | *[!0-9]*) return 1 ;;
	esac

	[ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

#######################################
# Проверить, что строка - порт, диапазон или их перечисление (443,8443-9000).
# Так пишут порты hysteria2 с port hopping.
# Arguments:
#   value: string
# Returns:
#   0 если каждый элемент перечисления - порт или диапазон портов
# Example:
#   _clash_is_port_list "443,8443-9000" && echo ok
#######################################
_clash_is_port_list() {
	local value="$1"

	[ -n "$value" ] || return 1

	local item part
	for item in $(printf '%s' "$value" | tr ',' ' '); do
		case "$item" in
		*-*)
			part="${item%%-*}"
			_clash_is_port "$part" || return 1
			part="${item#*-}"
			_clash_is_port "$part" || return 1
			;;
		*)
			_clash_is_port "$item" || return 1
			;;
		esac
	done

	return 0
}

#######################################
# Превратить строку через запятую в JSON-массив.
# Своя реализация вместо comma_string_to_json_array из helpers.sh: та собирает
# массив подстановкой ${var//,/} (bash) и не экранирует кавычки. Здесь строку
# режет сам jq, поэтому экранирование не наша забота.
# Arguments:
#   value: string, элементы через запятую
# Outputs:
#   JSON-массив строк, для пустого входа - []
# Example:
#   _clash_json_array_from_commas "h2,http/1.1"   # -> ["h2","http/1.1"]
#######################################
_clash_json_array_from_commas() {
	local value="$1"

	if [ -z "$value" ]; then
		printf '%s' "[]"
		return 0
	fi

	printf '%s' "$value" | jq -R -c 'split(",") | map(select(length > 0))'
}

#######################################
# Проверить, что строка похожа на userinfo shadowsocks: method:password либо
# method:key:key для шифров 2022.
# Своя реализация вместо is_shadowsocks_userinfo_format из helpers.sh: та
# написана на bash-регулярках ([[ =~ ]]).
# Arguments:
#   value: string
# Returns:
#   0 если формат подходит
# Example:
#   _clash_is_ss_userinfo "aes-256-gcm:secret" && echo ok
#######################################
_clash_is_ss_userinfo() {
	local value="$1"

	case "$value" in
	# пусто, нет двоеточия, либо пустая половина
	"" | *:) return 1 ;;
	:*) return 1 ;;
	*:*) ;;
	*) return 1 ;;
	esac

	# больше трёх частей - это уже не method:password[:key]
	case "${value#*:}" in
	*:*:*) return 1 ;;
	esac

	return 0
}

#######################################
# Раскодировать base64, прощая ссылке url-safe алфавит и потерянное выравнивание.
# Ровно так base64 в ссылках и пишут: '+' и '/' заменены на '-' и '_', хвостовые
# '=' отброшены.
# Arguments:
#   value: string
# Outputs:
#   Раскодированная строка, либо пусто если это не base64
# Example:
#   _clash_base64_decode "YWJj"   # -> abc
#######################################
_clash_base64_decode() {
	local value="$1"

	# '-' в конце набора tr читается как обычный символ, а не как диапазон
	value=$(printf '%s' "$value" | tr '_-' '/+')

	case $((${#value} % 4)) in
	2) value="$value==" ;;
	3) value="$value=" ;;
	esac

	printf '%s' "$value" | base64 -d 2>/dev/null
}

## --- сборка объектов прокси -------------------------------------------------

#######################################
# Собрать объект прокси VLESS.
# Имена полей взяты из docs/mapping.md: server_port -> port,
# packet_encoding -> packet-encoding.
# Arguments:
#   name: string, имя прокси в конфиге Clash
#   server: string, адрес сервера
#   port: integer, порт сервера
#   uuid: string, идентификатор пользователя
#   flow: string, поток, например xtls-rprx-vision (необязательно)
#   packet_encoding: string, упаковка UDP-пакетов (необязательно)
#   udp_over_tcp: string, "1" если включён UDP over TCP (необязательно)
# Outputs:
#   JSON-объект прокси
# Example:
#   _clash_build_vless_proxy "main-out" "example.com" 443 "$uuid" "xtls-rprx-vision"
#######################################
_clash_build_vless_proxy() {
	local name="$1"
	local server="$2"
	local port="$3"
	local uuid="$4"
	local flow="$5"
	local packet_encoding="$6"
	local udp_over_tcp="$7"

	jq -n -c \
		--arg name "$name" \
		--arg server "$server" \
		--arg port "$port" \
		--arg uuid "$uuid" \
		--arg flow "$flow" \
		--arg packet_encoding "$packet_encoding" \
		--arg udp_over_tcp "$udp_over_tcp" \
		'{
			name: $name,
			type: "vless",
			server: $server,
			port: ($port | tonumber),
			uuid: $uuid,
			udp: true
		}
		+ (if $flow != "" then {flow: $flow} else {} end)
		+ (if $packet_encoding != "" then {"packet-encoding": $packet_encoding} else {} end)
		+ (if $udp_over_tcp == "1" then {"udp-over-tcp": true} else {} end)'
}

#######################################
# Собрать объект прокси Shadowsocks.
# method из ссылки в Clash называется cipher.
# Arguments:
#   name: string, имя прокси в конфиге Clash
#   server: string, адрес сервера
#   port: integer, порт сервера
#   cipher: string, шифр
#   password: string, пароль
#   udp_over_tcp: string, "1" если включён UDP over TCP (необязательно)
# Outputs:
#   JSON-объект прокси
# Example:
#   _clash_build_shadowsocks_proxy "main-out" "127.0.0.1" 8388 "aes-256-gcm" "secret"
#######################################
_clash_build_shadowsocks_proxy() {
	local name="$1"
	local server="$2"
	local port="$3"
	local cipher="$4"
	local password="$5"
	local udp_over_tcp="$6"

	jq -n -c \
		--arg name "$name" \
		--arg server "$server" \
		--arg port "$port" \
		--arg cipher "$cipher" \
		--arg password "$password" \
		--arg udp_over_tcp "$udp_over_tcp" \
		'{
			name: $name,
			type: "ss",
			server: $server,
			port: ($port | tonumber),
			cipher: $cipher,
			password: $password,
			udp: true
		}
		+ (if $udp_over_tcp == "1" then {"udp-over-tcp": true} else {} end)'
}

#######################################
# Собрать объект прокси Trojan.
# Arguments:
#   name: string, имя прокси в конфиге Clash
#   server: string, адрес сервера
#   port: integer, порт сервера
#   password: string, пароль
# Outputs:
#   JSON-объект прокси
# Example:
#   _clash_build_trojan_proxy "main-out" "example.com" 443 "secret"
#######################################
_clash_build_trojan_proxy() {
	local name="$1"
	local server="$2"
	local port="$3"
	local password="$4"

	jq -n -c \
		--arg name "$name" \
		--arg server "$server" \
		--arg port "$port" \
		--arg password "$password" \
		'{
			name: $name,
			type: "trojan",
			server: $server,
			port: ($port | tonumber),
			password: $password,
			udp: true
		}'
}

#######################################
# Собрать объект прокси SOCKS5.
# Arguments:
#   name: string, имя прокси в конфиге Clash
#   server: string, адрес сервера
#   port: integer, порт сервера
#   username: string, логин (необязательно)
#   password: string, пароль (необязательно)
#   udp_over_tcp: string, "1" если включён UDP over TCP (необязательно)
# Outputs:
#   JSON-объект прокси
# Example:
#   _clash_build_socks_proxy "main-out" "127.0.0.1" 1080 "user" "pass"
#######################################
_clash_build_socks_proxy() {
	local name="$1"
	local server="$2"
	local port="$3"
	local username="$4"
	local password="$5"
	local udp_over_tcp="$6"

	jq -n -c \
		--arg name "$name" \
		--arg server "$server" \
		--arg port "$port" \
		--arg username "$username" \
		--arg password "$password" \
		--arg udp_over_tcp "$udp_over_tcp" \
		'{
			name: $name,
			type: "socks5",
			server: $server,
			port: ($port | tonumber),
			udp: true
		}
		+ (if $username != "" then {username: $username} else {} end)
		+ (if $password != "" then {password: $password} else {} end)
		+ (if $udp_over_tcp == "1" then {"udp-over-tcp": true} else {} end)'
}

#######################################
# Собрать объект прокси Hysteria2.
# Пропускную способность Clash ждёт строкой с единицей измерения, поэтому
# upmbps=50 превращается в "50 Mbps". Перечисление портов (port hopping)
# уезжает в ports, а в port остаётся первый порт списка - без него ядру не за
# что зацепиться.
# Arguments:
#   name: string, имя прокси в конфиге Clash
#   server: string, адрес сервера
#   port: string, порт, диапазон или перечисление
#   password: string, пароль
#   obfs: string, тип обфускации (необязательно)
#   obfs_password: string, пароль обфускации (необязательно)
#   up_mbps: integer, ширина канала вверх (необязательно)
#   down_mbps: integer, ширина канала вниз (необязательно)
# Outputs:
#   JSON-объект прокси
# Example:
#   _clash_build_hysteria2_proxy "main-out" "example.com" 443 "secret" "salamander" "obfspass"
#######################################
_clash_build_hysteria2_proxy() {
	local name="$1"
	local server="$2"
	local port="$3"
	local password="$4"
	local obfs="$5"
	local obfs_password="$6"
	local up_mbps="$7"
	local down_mbps="$8"

	# регулярки в jq на роутере может не быть, поэтому перечисление портов
	# распознаём в оболочке, как это сделано в менеджере sing-box
	local is_multi_port="false"
	local first_port="$port"
	case "$port" in
	*,* | *-*)
		is_multi_port="true"
		first_port=$(printf '%s' "$port" | sed 's/[,-].*//')
		;;
	esac

	jq -n -c \
		--arg name "$name" \
		--arg server "$server" \
		--arg port "$port" \
		--arg first_port "$first_port" \
		--arg password "$password" \
		--arg obfs "$obfs" \
		--arg obfs_password "$obfs_password" \
		--arg up_mbps "$up_mbps" \
		--arg down_mbps "$down_mbps" \
		--argjson is_multi_port "$is_multi_port" \
		'{
			name: $name,
			type: "hysteria2",
			server: $server,
			port: ($first_port | tonumber),
			password: $password
		}
		+ (if $is_multi_port then {ports: $port} else {} end)
		+ (if $obfs != "" then {obfs: $obfs} else {} end)
		+ (if $obfs != "" and $obfs_password != "" then {"obfs-password": $obfs_password} else {} end)
		+ (if $up_mbps != "" then {up: ($up_mbps + " Mbps")} else {} end)
		+ (if $down_mbps != "" then {down: ($down_mbps + " Mbps")} else {} end)'
}

#######################################
# Долить в объект прокси поля защиты соединения: TLS и Reality.
# Соответствие полей из docs/mapping.md: tls.server_name -> servername (у trojan
# и hysteria2 то же самое называется sni), tls.reality.public_key ->
# reality-opts.public-key, tls.reality.short_id -> reality-opts.short-id,
# tls.utls.fingerprint -> client-fingerprint.
# Arguments:
#   proxy: string (JSON), объект прокси
#   url: string, ссылка на прокси без якоря
# Outputs:
#   Объект прокси с добавленными полями
# Returns:
#   1 если в ссылке незнакомый security или reality без ключа
# Example:
#   proxy=$(_clash_add_proxy_security "$proxy" "$url") || return 1
#######################################
_clash_add_proxy_security() {
	local proxy="$1"
	local url="$2"

	local scheme security target
	scheme=$(_clash_url_scheme "$url")
	security=$(_clash_query "$url" "security")
	target="$scheme://$(url_get_host "$url")"

	# у hysteria2 TLS не выключается, и параметра security в ссылке нет
	case "$scheme" in
	hysteria2 | hy2) [ -n "$security" ] || security="tls" ;;
	esac

	case "$security" in
	"" | none)
		printf '%s' "$proxy"
		return 0
		;;
	tls | reality) ;;
	*)
		_clash_fail "не разобрать ссылку $target: неизвестная защита '$security', бывает tls, reality или none"
		return 1
		;;
	esac

	local sni insecure alpn fingerprint public_key short_id
	sni=$(_clash_query "$url" "sni")
	insecure=$(_clash_query_insecure "$url")
	alpn=$(_clash_json_array_from_commas "$(_clash_query "$url" "alpn")")
	fingerprint=$(_clash_query "$url" "fp")
	public_key=$(_clash_query "$url" "pbk")
	short_id=$(_clash_query "$url" "sid")

	# отпечаток браузера подделывает uTLS, которого у hysteria2 нет
	case "$scheme" in
	hysteria2 | hy2) fingerprint="" ;;
	esac

	if [ "$security" = "reality" ] && [ -z "$public_key" ]; then
		_clash_fail "не разобрать ссылку $target: security=reality без публичного ключа (pbk)"
		return 1
	fi

	printf '%s' "$proxy" | jq -c \
		--arg security "$security" \
		--arg sni "$sni" \
		--arg insecure "$insecure" \
		--argjson alpn "$alpn" \
		--arg fingerprint "$fingerprint" \
		--arg public_key "$public_key" \
		--arg short_id "$short_id" \
		'
		# поле с именем сервера у Clash зовётся по-разному: у vless servername,
		# у trojan и hysteria2 sni
		. + (if .type == "vless" then {tls: true} else {} end)
		+ (if $sni == "" then {}
			elif .type == "vless" then {servername: $sni}
			else {sni: $sni} end)
		+ (if $insecure == "1" or $insecure == "true" then {"skip-cert-verify": true} else {} end)
		+ (if ($alpn | length) > 0 then {alpn: $alpn} else {} end)
		+ (if $fingerprint != "" then {"client-fingerprint": $fingerprint} else {} end)
		+ (if $security == "reality" then {
			"reality-opts": (
				{"public-key": $public_key}
				+ (if $short_id != "" then {"short-id": $short_id} else {} end)
			)
		} else {} end)'
}

#######################################
# Долить в объект прокси транспорт: network и опции под него.
# Clash понимает ws, grpc и h2. Остальное (kcp, httpupgrade, xhttp) в схеме
# clash-rs не выражается, поэтому такая ссылка честно отвергается: тихо
# выброшенный транспорт дал бы прокси, который подключается и не работает.
# Arguments:
#   proxy: string (JSON), объект прокси
#   url: string, ссылка на прокси без якоря
# Outputs:
#   Объект прокси с добавленными полями
# Returns:
#   1 если транспорт неизвестен или не поддерживается
# Example:
#   proxy=$(_clash_add_proxy_transport "$proxy" "$url") || return 1
#######################################
_clash_add_proxy_transport() {
	local proxy="$1"
	local url="$2"

	local transport
	transport=$(_clash_query "$url" "type")

	local path host service_name early_data early_data_header
	case "$transport" in
	"" | tcp | raw | none)
		printf '%s' "$proxy"
		;;
	ws)
		path=$(_clash_query "$url" "path")
		host=$(_clash_query "$url" "host")
		early_data=$(_clash_query "$url" "ed")
		early_data_header=$(_clash_query "$url" "eh")

		printf '%s' "$proxy" | jq -c \
			--arg path "$path" \
			--arg host "$host" \
			--arg early_data "$early_data" \
			--arg early_data_header "$early_data_header" \
			'(
				(if $path != "" then {path: $path} else {} end)
				+ (if $host != "" then {headers: {Host: $host}} else {} end)
				+ (if $early_data != "" then {"max-early-data": ($early_data | tonumber)} else {} end)
				+ (if $early_data_header != "" then {"early-data-header-name": $early_data_header} else {} end)
			) as $opts
			| . + {network: "ws"}
			+ (if ($opts | length) > 0 then {"ws-opts": $opts} else {} end)'
		;;
	grpc)
		service_name=$(_clash_query "$url" "serviceName")

		printf '%s' "$proxy" | jq -c \
			--arg service_name "$service_name" \
			'. + {network: "grpc"}
			+ (if $service_name != "" then {"grpc-opts": {"grpc-service-name": $service_name}} else {} end)'
		;;
	h2 | http)
		path=$(_clash_query "$url" "path")
		host=$(_clash_query "$url" "host")

		printf '%s' "$proxy" | jq -c \
			--arg path "$path" \
			--arg host "$host" \
			'(
				(if $path != "" then {path: $path} else {} end)
				+ (if $host != "" then {host: ($host | split(","))} else {} end)
			) as $opts
			| . + {network: "h2"}
			+ (if ($opts | length) > 0 then {"h2-opts": $opts} else {} end)'
		;;
	*)
		_clash_fail "не разобрать ссылку $(_clash_url_scheme "$url")://$(url_get_host "$url"): транспорт '$transport' clash-rs не поддерживает, бывают ws, grpc и h2"
		return 1
		;;
	esac
}

## --- разбор ссылок ----------------------------------------------------------

#######################################
# Разобрать ссылку на прокси в объект прокси Clash.
#
# Понимает vless://, ss://, trojan://, socks5://, hysteria2:// и hy2://.
# Имя прокси берётся из аргумента; если его нет - из якоря ссылки; если пуст и
# он - из схемы. Имя важно: именно по нему на прокси ссылаются правила и группы.
#
# Arguments:
#   url: string, ссылка на прокси
#   name: string, имя прокси в конфиге Clash (необязательно)
#   udp_over_tcp: string, "1" если в секции включён UDP over TCP (необязательно)
# Outputs:
#   JSON-объект прокси в stdout; при ошибке stdout пуст, причина в stderr
# Returns:
#   1 если ссылку разобрать не удалось
# Example:
#   proxy=$(clash_cf_parse_proxy_url "vless://uuid@example.com:443?security=reality&pbk=key" "main-out")
#######################################
clash_cf_parse_proxy_url() {
	local url="$1"
	local name="$2"
	local udp_over_tcp="$3"

	url=$(_clash_trim "$url")
	if [ -z "$url" ]; then
		_clash_fail "пустая ссылка на прокси"
		return 1
	fi

	case "$url" in
	*://*) ;;
	*)
		_clash_fail "не разобрать ссылку '$url': нет схемы вида 'vless://'"
		return 1
		;;
	esac

	local scheme fragment
	scheme=$(_clash_url_scheme "$url")
	fragment=$(_clash_url_decode "$(_clash_url_get_fragment "$url")")
	url=$(url_strip_fragment "$url")

	[ -n "$name" ] || name="$fragment"
	[ -n "$name" ] || name="$scheme-out"

	local host port proxy
	host=$(url_get_host "$url")
	port=$(_clash_url_get_port "$url")

	if [ -z "$host" ]; then
		_clash_fail "не разобрать ссылку $scheme://: не видно адреса сервера"
		return 1
	fi

	case "$scheme" in
	vless)
		if ! _clash_is_port "$port"; then
			_clash_fail "не разобрать ссылку vless://$host: порт '$port' не похож на порт"
			return 1
		fi

		local uuid flow packet_encoding
		uuid=$(_clash_url_decode "$(url_get_userinfo "$url")")
		if [ -z "$uuid" ]; then
			_clash_fail "не разобрать ссылку vless://$host:$port: нет uuid перед '@'"
			return 1
		fi
		flow=$(_clash_query "$url" "flow")
		packet_encoding=$(_clash_query "$url" "packetEncoding")

		proxy=$(_clash_build_vless_proxy "$name" "$host" "$port" "$uuid" "$flow" "$packet_encoding" \
			"$udp_over_tcp") || return 1
		proxy=$(_clash_add_proxy_security "$proxy" "$url") || return 1
		proxy=$(_clash_add_proxy_transport "$proxy" "$url") || return 1
		;;
	ss)
		if ! _clash_is_port "$port"; then
			_clash_fail "не разобрать ссылку ss://$host: порт '$port' не похож на порт"
			return 1
		fi

		local userinfo cipher password
		userinfo=$(url_get_userinfo "$url")
		if [ -z "$userinfo" ]; then
			_clash_fail "не разобрать ссылку ss://$host:$port: нет шифра и пароля перед '@'"
			return 1
		fi

		# userinfo бывает в двух видах: открытым текстом method:password и
		# base64 от него же
		if _clash_is_ss_userinfo "$userinfo"; then
			cipher=$(_clash_url_decode "${userinfo%%:*}")
			password=$(_clash_url_decode "${userinfo#*:}")
		else
			userinfo=$(_clash_base64_decode "$(_clash_url_decode "$userinfo")")
			if ! _clash_is_ss_userinfo "$userinfo"; then
				_clash_fail "не разобрать ссылку ss://$host:$port: часть перед '@' не похожа ни на method:password, ни на base64 от него"
				return 1
			fi
			cipher="${userinfo%%:*}"
			password="${userinfo#*:}"
		fi

		proxy=$(_clash_build_shadowsocks_proxy "$name" "$host" "$port" "$cipher" "$password" \
			"$udp_over_tcp") || return 1
		;;
	trojan)
		if ! _clash_is_port "$port"; then
			_clash_fail "не разобрать ссылку trojan://$host: порт '$port' не похож на порт"
			return 1
		fi

		local trojan_password
		trojan_password=$(_clash_url_decode "$(url_get_userinfo "$url")")
		if [ -z "$trojan_password" ]; then
			_clash_fail "не разобрать ссылку trojan://$host:$port: нет пароля перед '@'"
			return 1
		fi

		proxy=$(_clash_build_trojan_proxy "$name" "$host" "$port" "$trojan_password") || return 1
		proxy=$(_clash_add_proxy_security "$proxy" "$url") || return 1
		proxy=$(_clash_add_proxy_transport "$proxy" "$url") || return 1
		;;
	socks | socks5)
		if ! _clash_is_port "$port"; then
			_clash_fail "не разобрать ссылку socks5://$host: порт '$port' не похож на порт"
			return 1
		fi

		local socks_userinfo username socks_password
		socks_userinfo=$(url_get_userinfo "$url")
		username=""
		socks_password=""
		if [ -n "$socks_userinfo" ]; then
			username=$(_clash_url_decode "${socks_userinfo%%:*}")
			case "$socks_userinfo" in
			*:*) socks_password=$(_clash_url_decode "${socks_userinfo#*:}") ;;
			esac
		fi

		proxy=$(_clash_build_socks_proxy "$name" "$host" "$port" "$username" "$socks_password" \
			"$udp_over_tcp") || return 1
		;;
	socks4 | socks4a)
		_clash_fail "не разобрать ссылку $scheme://$host: clash-rs умеет только socks5"
		return 1
		;;
	hysteria2 | hy2)
		if ! _clash_is_port_list "$port"; then
			_clash_fail "не разобрать ссылку $scheme://$host: порт '$port' не похож на порт или их перечисление"
			return 1
		fi

		local hy_password obfs obfs_password up_mbps down_mbps
		hy_password=$(_clash_url_decode "$(url_get_userinfo "$url")")
		if [ -z "$hy_password" ]; then
			_clash_fail "не разобрать ссылку $scheme://$host:$port: нет пароля перед '@'"
			return 1
		fi
		obfs=$(_clash_query "$url" "obfs")
		obfs_password=$(_clash_query "$url" "obfs-password")
		up_mbps=$(_clash_query "$url" "upmbps")
		down_mbps=$(_clash_query "$url" "downmbps")

		proxy=$(_clash_build_hysteria2_proxy "$name" "$host" "$port" "$hy_password" "$obfs" \
			"$obfs_password" "$up_mbps" "$down_mbps") || return 1
		proxy=$(_clash_add_proxy_security "$proxy" "$url") || return 1
		;;
	*)
		_clash_fail "не разобрать ссылку: схему '$scheme' подкоп на clash-rs не поддерживает"
		return 1
		;;
	esac

	if [ -z "$proxy" ]; then
		_clash_fail "не разобрать ссылку $scheme://$host:$port: объект прокси собрать не удалось"
		return 1
	fi

	printf '%s' "$proxy"
}

#######################################
# Разобрать ссылку на прокси и дописать полученный прокси в конфиг.
# Имя прокси - тег секции, как и у выходов sing-box: по нему секцию потом
# находят правила и группы.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   section: string, имя секции подкопа
#   url: string, ссылка на прокси
#   udp_over_tcp: string, "1" если в секции включён UDP over TCP (необязательно)
# Outputs:
#   Обновлённая конфигурация в stdout; при ошибке stdout пуст, причина в stderr
# Returns:
#   1 если ссылку разобрать не удалось
# Example:
#   config=$(clash_cf_add_proxy_outbound "$config" "main" "$proxy_string" "$udp_over_tcp") || exit 1
#######################################
clash_cf_add_proxy_outbound() {
	local config="$1"
	local section="$2"
	local url="$3"
	local udp_over_tcp="$4"

	local name=""
	[ -z "$section" ] || name=$(get_outbound_tag_by_section "$section")

	local proxy
	proxy=$(clash_cf_parse_proxy_url "$url" "$name" "$udp_over_tcp") || return 1

	# Имя могло взяться из якоря ссылки, поэтому читаем его из собранного
	# объекта. Через _clash_trim обязательно: подстановка $( ) снимает с
	# вывода только перевод строки, а возврат каретки оставляет. Имя с
	# невидимым \r на конце потом не находится по этому же имени - именно так
	# отваливалась привязка интерфейса, и понять это по конфигу невозможно.
	name=$(_clash_trim "$(printf '%s' "$proxy" | jq -r '.name')")

	clash_cm_add_raw_proxy "$config" "$name" "$proxy"
}

#######################################
# Дописать в конфиг готовый объект прокси, как его написал пользователь.
# Проверяем только то, что это вообще объект JSON: остальное на совести автора,
# ровно как у sing_box_cf_add_json_outbound.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   section: string, имя секции подкопа
#   json_proxy: string (JSON), объект прокси
# Outputs:
#   Обновлённая конфигурация в stdout
# Returns:
#   1 если это не объект JSON
# Example:
#   config=$(clash_cf_add_json_outbound "$config" "main" '{"type":"ss","server":"127.0.0.1"}')
#######################################
clash_cf_add_json_outbound() {
	local config="$1"
	local section="$2"
	local json_proxy="$3"

	if ! printf '%s' "$json_proxy" | jq -e 'type == "object"' >/dev/null 2>&1; then
		_clash_fail "секция '$section': это не объект прокси JSON"
		return 1
	fi

	local name
	name=$(get_outbound_tag_by_section "$section")

	clash_cm_add_raw_proxy "$config" "$name" "$json_proxy"
}

#######################################
# Привязать прокси секции к сетевому интерфейсу.
# У Clash нет отдельного выхода с привязкой к интерфейсу, как direct у sing-box:
# интерфейс - это поле interface-name у самого прокси (см. docs/mapping.md).
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   section: string, имя секции подкопа
#   interface_name: string, имя интерфейса
# Outputs:
#   Обновлённая конфигурация в stdout
# Example:
#   config=$(clash_cf_set_proxy_interface "$config" "main" "awg0")
#######################################
clash_cf_set_proxy_interface() {
	local config="$1"
	local section="$2"
	local interface_name="$3"

	local name
	name=$(get_outbound_tag_by_section "$section")

	clash_cm_set_interface_for_proxy "$config" "$name" "$interface_name"
}

## --- всё остальное ----------------------------------------------------------

#######################################
# Добавить DNS-сервер.
# У Clash нет типизированных серверов, как у sing-box: тип уезжает схемой в
# саму строку адреса (см. docs/mapping.md), собирает её менеджер. Здесь только
# перевод названий типов подкопа в схемы Clash и разбор адреса на части.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   type: string, udp, dot или doh
#   server: string, адрес сервера, с портом и путём или без
# Outputs:
#   Обновлённая конфигурация в stdout
# Returns:
#   1 если тип неизвестен
# Example:
#   config=$(clash_cf_add_dns_server "$config" "doh" "https://dns.google/dns-query")
#######################################
clash_cf_add_dns_server() {
	local config="$1"
	local type="$2"
	local server="$3"

	local transport
	case "$type" in
	udp) transport="udp" ;;
	dot) transport="tls" ;;
	doh) transport="https" ;;
	*)
		_clash_fail "неизвестный тип DNS-сервера: $type"
		return 1
		;;
	esac

	local address port path
	address=$(url_get_host "$server")
	port=$(_clash_url_get_port "$server")
	path=""
	if [ "$type" = "doh" ]; then
		path=$(url_get_path "$server")
		[ -n "$path" ] || path="/dns-query"
	fi

	clash_cm_add_nameserver "$config" "$transport" "$address" "$port" "$path"
}

#######################################
# Поднять смешанный инбаунд и отправить его трафик в нужный прокси.
# Половина смысла теряется по дороге: у Clash порты инбаундов скалярные и без
# тегов, поэтому правила вида "трафик из этого инбаунда - туда-то" не
# выражаются (см. раздел "Пробелы" в docs/mapping.md). Поднимаем порт и честно
# пишем в лог, что маршрут по инбаунду не задан.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   listen_port: integer, порт mixed-инбаунда
#   proxy: string, имя прокси, куда должен идти трафик
# Outputs:
#   Обновлённая конфигурация в stdout
# Example:
#   config=$(clash_cf_add_mixed_inbound_and_route_rule "$config" 2080 "main-out")
#######################################
clash_cf_add_mixed_inbound_and_route_rule() {
	local config="$1"
	local listen_port="$2"
	local proxy="$3"

	log "clash facade: mixed-port $listen_port поднят, но правила по инбаунду в clash-rs нет: трафик в '$proxy' придётся разделять по SRC-IP-CIDR" "warn"

	clash_cm_set_mixed_port "$config" "$listen_port"
}

#######################################
# Отправить домен в заданный прокси.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   domain: string, домен
#   proxy: string, имя прокси или встроенное DIRECT / REJECT
# Outputs:
#   Обновлённая конфигурация в stdout
# Example:
#   config=$(clash_cf_proxy_domain "$config" "ipinfo.io" "main-out")
#######################################
clash_cf_proxy_domain() {
	local config="$1"
	local domain="$2"
	local proxy="$3"

	clash_cm_add_rule "$config" "DOMAIN" "$domain" "$proxy"
}

#######################################
# Вернуть тип правила Clash по имени ключа правила sing-box.
# Правила sing-box - объекты с ключами, правила Clash - строки, первое поле
# которых как раз и есть бывший ключ.
# Arguments:
#   key: string, ключ правила sing-box
# Outputs:
#   Тип правила Clash
# Returns:
#   1 если у ключа нет соответствия
# Example:
#   _clash_rule_type_from_key "domain_suffix"   # -> DOMAIN-SUFFIX
#######################################
_clash_rule_type_from_key() {
	local key="$1"

	case "$key" in
	domain) printf '%s' "DOMAIN" ;;
	domain_suffix) printf '%s' "DOMAIN-SUFFIX" ;;
	domain_keyword) printf '%s' "DOMAIN-KEYWORD" ;;
	domain_regex) printf '%s' "DOMAIN-REGEX" ;;
	ip_cidr) printf '%s' "IP-CIDR" ;;
	source_ip_cidr) printf '%s' "SRC-IP-CIDR" ;;
	port) printf '%s' "DST-PORT" ;;
	source_port) printf '%s' "SRC-PORT" ;;
	network) printf '%s' "NETWORK" ;;
	process_name) printf '%s' "PROCESS-NAME" ;;
	rule_set) printf '%s' "RULE-SET" ;;
	*) return 1 ;;
	esac
}

#######################################
# Запретить трафик по одному признаку.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   key: string, ключ правила sing-box, например domain_suffix
#   value: string, значение признака
# Outputs:
#   Обновлённая конфигурация в stdout
# Returns:
#   1 если признак в правилах Clash не выражается
# Example:
#   config=$(clash_cf_add_single_key_reject_rule "$config" "domain_suffix" "example.com")
#######################################
clash_cf_add_single_key_reject_rule() {
	local config="$1"
	local key="$2"
	local value="$3"

	local rule_type
	rule_type=$(_clash_rule_type_from_key "$key")
	if [ -z "$rule_type" ]; then
		# признак protocol=quic сюда и приходит: у Clash запрет QUIC делается
		# правилом по порту, а не по протоколу
		_clash_fail "признак '$key' в правилах clash-rs не выражается"
		return 1
	fi

	clash_cm_add_reject_rule "$config" "$rule_type" "$value"
}

#######################################
# Подменить порт назначения у домена.
# Эквивалента в clash-rs нет вовсе (см. раздел "Пробелы" в docs/mapping.md):
# правила Clash умеют выбирать выход, но не переписывать адрес назначения.
# Конфиг возвращается нетронутым, чтобы вызывающий не собирал битые правила.
# Arguments:
#   config: string (JSON), конфигурация clash-rs
#   domain: string, домен
#   port: integer, порт
# Outputs:
#   Конфигурация без изменений
# Example:
#   config=$(clash_cf_override_domain_port "$config" "example.com" 8443)
#######################################
clash_cf_override_domain_port() {
	local config="$1"
	local domain="$2"
	local port="$3"

	log "clash facade: подмена порта ($domain -> $port) в clash-rs не выражается, правило пропущено" "warn"

	printf '%s' "$config"
}
