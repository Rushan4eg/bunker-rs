# Две фичи из форков подкопа, живущие целиком в nftables.
#
#   1. Блокировка публичных DoH-резолверов (из netshift, фича №30).
#   2. Действие Bypass для секции (из forkop, фича №26).
#
# Обе ядронезависимы: правила ставятся на уровне nftables и списков адресов,
# а не в конфиге ядра. Поэтому они одинаково работают и на sing-box, и на
# clash-rs, и переживут появление третьего ядра.
#
# Почему nftables, а не route-правило ядра (как у netshift):
#
#   Блокировка на стороне ядра ловит только тот трафик, который в ядро
#   попал. Достаточно завернуть подсети Cloudflare в туннель - и DoH к
#   1.1.1.1 уедет через прокси, то есть мимо DNS роутера. Правило в nft
#   стоит раньше tproxy-метки и ловит трафик до того, как ядро о нём узнает.
#
# Генерация текста правил отделена от применения сознательно: скрипт для
# `nft -f -` собирается чистыми функциями, которые можно прогнать на любой
# машине без роутера и без прав root. Наружу торчит одна тонкая функция
# _podkop_extras_nft_apply, которую тесты подменяют заглушкой.
#
# Скрипт применяется одной транзакцией `nft -f -`, а не пачкой `nft add rule`:
# при ошибке в любой строке не применяется ничего. Полусобранные правила
# опаснее отсутствующих - роутер остаётся с дырой, о которой никто не знает.
#
# Использование:
#   . /usr/lib/podkop/podkop_extras.sh
#   podkop_extras_doh_apply                       # после create_nft_rules
#   podkop_extras_bypass_apply "" main "1.2.3.0/24 2001:db8::/32"
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- параметры ---------------------------------------------------------------
# Всё через :- чтобы переопределялось снаружи: из подкопа, из тестов или
# руками при отладке на роутере.

# Имя таблицы. Пусто - взять NFT_TABLE_NAME из constants.sh, а если и его нет
# (модуль подключили отдельно), то значение по умолчанию.
PODKOP_X_TABLE="${PODKOP_X_TABLE:-}"
PODKOP_X_TABLE_FALLBACK="PodkopTable"

# Цепочки подкопа, в которые вклиниваемся. Свои имена держим отдельно от
# NFT_* из constants.sh, чтобы модуль не ломался при их переименовании.
PODKOP_X_MANGLE_CHAIN="${PODKOP_X_MANGLE_CHAIN:-mangle}"
PODKOP_X_MANGLE_OUTPUT_CHAIN="${PODKOP_X_MANGLE_OUTPUT_CHAIN:-mangle_output}"

# Метки подкопа. Дублируются здесь намеренно: значения из constants.sh
# трогать нельзя, а прибивать модуль к их наличию не хочется.
PODKOP_X_FAKEIP_MARK="${PODKOP_X_FAKEIP_MARK:-0x00100000}"
PODKOP_X_OUTBOUND_MARK="${PODKOP_X_OUTBOUND_MARK:-0x00200000}"

# --- DoH ---
PODKOP_X_DOH_SET_V4="${PODKOP_X_DOH_SET_V4:-podkop_doh_v4}"
PODKOP_X_DOH_SET_V6="${PODKOP_X_DOH_SET_V6:-podkop_doh_v6}"
PODKOP_X_DOH_CHAIN_FORWARD="${PODKOP_X_DOH_CHAIN_FORWARD:-doh_block}"
PODKOP_X_DOH_CHAIN_OUTPUT="${PODKOP_X_DOH_CHAIN_OUTPUT:-doh_block_output}"

# Приоритет цепочек блокировки. Отрицательный, чтобы отработать до фильтра
# fw4 (у него forward на 0): решение о блокировке DoH не должно зависеть от
# того, что пользователь настроил в firewall.
PODKOP_X_DOH_CHAIN_PRIORITY="${PODKOP_X_DOH_CHAIN_PRIORITY:--10}"

# Режется только 443 - и tcp (DoH), и udp (DoH3 поверх QUIC).
#
# Резать все порты до этих адресов, как делает netshift, нельзя: в списке
# лежат 1.1.1.1, 8.8.8.8, 77.88.8.8 - ровно те, что стоят в DNS_RESOLVERS
# самого подкопа и в его настройках по умолчанию. Обычный DNS по udp/53 и
# DoT по tcp/853 остаются рабочими, и включение опции не отрезает роутеру
# резолвер.
PODKOP_X_DOH_PORT="${PODKOP_X_DOH_PORT:-443}"

# Блокировать ли DoH, исходящий от самого роутера (hook output).
#
# По умолчанию выключено, и это осознанно. У подкопа в настройках может
# стоять dns_type=doh с сервером из нашего же списка (LuCI предлагает
# https://1.1.1.1/dns-query) - включённая цепочка на output отрезала бы
# роутеру его собственный резолвер. Браузеров на роутере нет, а угроза от
# DoH - это именно клиенты в LAN, их ловит цепочка на forward.
PODKOP_X_DOH_COVER_ROUTER="${PODKOP_X_DOH_COVER_ROUTER:-0}"

# --- Bypass ---
PODKOP_X_BYPASS_SET_PREFIX="${PODKOP_X_BYPASS_SET_PREFIX:-podkop_bypass_}"

# Длина имени секции внутри имени set'а. Ядро разрешает 256 байт, но короткое
# имя удобнее читать в `nft list table` при разборе полётов.
PODKOP_X_BYPASS_SET_NAME_LIMIT="${PODKOP_X_BYPASS_SET_NAME_LIMIT:-24}"

## --- список DoH-резолверов ----------------------------------------------------
#
# Публичные DoH-провайдеры: адреса, по которым браузер или приложение ходит к
# своему резолверу напрямую, минуя DNS роутера.
#
# Списки держатся плоскими строками, разделитель - пробел или перевод строки.
# Провайдер добавляется одной строкой, удаляется тоже одной - и в v4, и в v6.
#
# Правило пополнения: только стабильные anycast-адреса, объявленные
# провайдером как публичные резолверы. Адреса, полученные разовым резолвом
# доменного имени, сюда не кладём - через полгода по ним будет чужой хост.
#
# Дубли недопустимы: set создаётся с flags interval, и `add element` на
# повторяющийся адрес роняет всю транзакцию.

PODKOP_X_DOH_PROVIDERS="cloudflare google quad9 adguard nextdns mullvad opendns yandex cleanbrowsing dnssb controld dns0 alidns dnspod"

PODKOP_X_DOH_IPV4="1.1.1.1 1.0.0.1 1.1.1.2 1.0.0.2 1.1.1.3 1.0.0.3"                                            # Cloudflare: default, security, family
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 8.8.8.8 8.8.4.4"                                                         # Google Public DNS
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 9.9.9.9 9.9.9.10 9.9.9.11 149.112.112.9 149.112.112.10 149.112.112.11 149.112.112.112" # Quad9
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 94.140.14.14 94.140.15.15 94.140.14.15 94.140.15.16 94.140.14.140 94.140.14.141"       # AdGuard DNS
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 45.90.28.0/24 45.90.30.0/24"                                             # NextDNS (anycast)
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 194.242.2.0/24"                                                          # Mullvad DNS (anycast)
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 208.67.222.222 208.67.220.220 208.67.222.123 208.67.220.123"             # OpenDNS / Cisco Umbrella
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 77.88.8.8 77.88.8.1 77.88.8.88 77.88.8.2 77.88.8.7 77.88.8.3"            # Yandex DNS
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 185.228.168.9 185.228.169.9 185.228.168.10 185.228.169.11 185.228.168.168 185.228.169.168" # CleanBrowsing
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 185.222.222.222 45.11.45.11"                                             # DNS.SB
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 76.76.2.0/24 76.76.10.0/24"                                              # ControlD (anycast)
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 193.110.81.0/24 185.253.5.0/24"                                          # dns0.eu (anycast)
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 223.5.5.5 223.6.6.6"                                                     # AliDNS
PODKOP_X_DOH_IPV4="$PODKOP_X_DOH_IPV4 119.29.29.29"                                                            # DNSPod / doh.pub

PODKOP_X_DOH_IPV6="2606:4700:4700::1111 2606:4700:4700::1001 2606:4700:4700::1112 2606:4700:4700::1002 2606:4700:4700::1113 2606:4700:4700::1003" # Cloudflare
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2001:4860:4860::8888 2001:4860:4860::8844"                               # Google Public DNS
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2620:fe::fe 2620:fe::9 2620:fe::10 2620:fe::fe:10 2620:fe::11 2620:fe::fe:11"          # Quad9
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a10:50c0::ad1:ff 2a10:50c0::ad2:ff 2a10:50c0::bad1:ff 2a10:50c0::bad2:ff 2a10:50c0::1:ff 2a10:50c0::2:ff" # AdGuard DNS
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a07:a8c0::/32 2a07:a8c1::/32"                                           # NextDNS (anycast)
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a07:e340::2 2a07:e340::3 2a07:e340::4 2a07:e340::5 2a07:e340::6 2a07:e340::9"         # Mullvad DNS
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2620:119:35::35 2620:119:53::53 2620:119:35::123 2620:119:53::123"       # OpenDNS / Cisco Umbrella
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a02:6b8::feed:0ff 2a02:6b8:0:1::feed:0ff 2a02:6b8::feed:bad 2a02:6b8:0:1::feed:bad 2a02:6b8::feed:a11 2a02:6b8:0:1::feed:a11" # Yandex DNS
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a0d:2a00:1:: 2a0d:2a00:2:: 2a0d:2a00:1::1 2a0d:2a00:2::1 2a0d:2a00:1::2 2a0d:2a00:2::2" # CleanBrowsing
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a09:: 2a11::"                                                           # DNS.SB
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2606:1a40::/48 2606:1a40:1::/48"                                         # ControlD (anycast)
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2a0f:fc80::/48 2a0f:fc81::/48"                                           # dns0.eu (anycast)
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2400:3200::1 2400:3200:baba::1"                                          # AliDNS
PODKOP_X_DOH_IPV6="$PODKOP_X_DOH_IPV6 2402:4e00::"                                                             # DNSPod / doh.pub

## --- служебное ---------------------------------------------------------------

# Лог есть только внутри подкопа; в тестах и при ручном запуске модуль должен
# работать молча, а не падать на отсутствующей функции log.
#
# Проверяется именно функция: command -v для функции печатает её имя, а для
# внешней программы - путь. На наличие команды проверять нельзя, в PATH может
# лежать посторонний бинарник с именем log.
_podkop_extras_log() {
	case "$(command -v log 2> /dev/null)" in
	log) log "$1" "${2:-info}" ;;
	esac
	return 0
}

# Имя таблицы: аргумент, потом свой параметр, потом константа подкопа.
_podkop_extras_table() {
	if [ -n "$1" ]; then
		printf '%s' "$1"
		return 0
	fi
	if [ -n "$PODKOP_X_TABLE" ]; then
		printf '%s' "$PODKOP_X_TABLE"
		return 0
	fi
	printf '%s' "${NFT_TABLE_NAME:-$PODKOP_X_TABLE_FALLBACK}"
}

# UCI пишет булевы по-разному в зависимости от того, кто их поставил -
# LuCI, uci set или руки.
_podkop_extras_is_true() {
	case "$1" in
	1 | on | true | yes | enabled) return 0 ;;
	*) return 1 ;;
	esac
}

# Единственное место, где модуль трогает роутер.
#
# Тесты подменяют эту функцию и складывают скрипт в файл - так вся генерация
# проверяется без nft и без root.
_podkop_extras_nft_apply() {
	printf '%s\n' "$1" | nft -f -
}

# То же, но построчно и с проглатыванием ошибок - для снятия правил.
#
# Одной транзакцией снимать нельзя: `delete chain` на несуществующей цепочке
# роняет весь скрипт, и тогда не снимется ничего. А снятие должно доводиться
# до конца из любого состояния, включая наполовину применённое.
_podkop_extras_nft_apply_lenient() {
	local line
	printf '%s\n' "$1" | while IFS= read -r line; do
		[ -n "$line" ] || continue
		printf '%s\n' "$line" | nft -f - > /dev/null 2>&1 || true
	done
	return 0
}

#######################################
# Приводит произвольную строку к идентификатору, годному для имени nft-set.
#
# UCI и сам не пускает в имя секции ничего кроме [A-Za-z0-9_], но конфиг
# правят руками, и имя секции доезжает до строки, которую скармливают nft.
# Санитайзер здесь не для красоты: без него секция с именем
# `main; flush ruleset` превращается в команду.
#
# Arguments:
#   $1 - произвольная строка
# Outputs:
#   [A-Za-z0-9_], не длиннее PODKOP_X_BYPASS_SET_NAME_LIMIT, никогда не пусто
#######################################
podkop_extras_nft_ident() {
	local cleaned
	cleaned=$(printf '%s' "$1" | tr -c 'A-Za-z0-9_' '_' | cut -c "1-$PODKOP_X_BYPASS_SET_NAME_LIMIT")

	[ -n "$cleaned" ] || cleaned="unnamed"
	printf '%s' "$cleaned"
}

# Элемент похож на IPv4-адрес или подсеть? Проверка грубая и намеренно такая:
# её задача - не пустить в скрипт nft ничего, кроме цифр, точек и слеша.
_podkop_extras_is_v4_element() {
	case "$1" in
	"" | *[!0-9./]*) return 1 ;;
	esac
	case "$1" in
	*.*) return 0 ;;
	esac
	return 1
}

# То же для IPv6: только hex, двоеточия, точки (v4-mapped) и слеш.
_podkop_extras_is_v6_element() {
	case "$1" in
	"" | *[!0-9A-Fa-f:./]*) return 1 ;;
	esac
	case "$1" in
	*:*) return 0 ;;
	esac
	return 1
}

# Склеивает элементы в тело `{ ... }` для nft.
# Arguments:
#   $1 - v4 | v6, семейство
#   $2 - строка элементов через пробел, запятую или перевод строки
_podkop_extras_join_elements() {
	local family="$1" raw="$2" item out=""

	raw=$(printf '%s' "$raw" | tr ',' ' ')
	for item in $raw; do
		case "$family" in
		v6) _podkop_extras_is_v6_element "$item" || continue ;;
		*) _podkop_extras_is_v4_element "$item" || continue ;;
		esac

		if [ -z "$out" ]; then
			out="$item"
		else
			out="$out, $item"
		fi
	done

	printf '%s' "$out"
}

# Нормализует обозначение семейства: v4/ipv4/4/inet -> v4, всё остальное -> v6
_podkop_extras_family() {
	case "$1" in
	v6 | ipv6 | 6 | inet6) printf 'v6' ;;
	*) printf 'v4' ;;
	esac
}

## =============================================================================
## ФИЧА 1: блокировка DNS-over-HTTPS
## =============================================================================
#
# Браузер с включённым DoH резолвит имена сам, по HTTPS, у своего провайдера.
# Для подкопа это худший из возможных сценариев: маршрутизация построена на
# FakeIP, то есть на том, что DNS-ответы проходят через роутер. Если ответы
# идут мимо, роутер видит только реальные адреса, ни одно доменное правило не
# срабатывает, а пользователь при этом уверен, что сидит через туннель.
#
# Лечится двумя правилами на каждое семейство адресов:
#
#   1. В цепочке mangle (prerouting) - `return` до того, как поставится
#      tproxy-метка. Иначе трафик к 1.1.1.1:443 уедет в ядро (подсети
#      Cloudflare лежат в community-списке cloudflare) и до forward не
#      доберётся вовсе.
#   2. В своей цепочке на hook forward - `reject`. Именно reject, а не drop:
#      на явный отказ браузер откатывается к системному DNS за миллисекунды,
#      а на молчание висит секундами и раздражает пользователя ровно тем, за
#      что он потом ругает подкоп.

# Опция UCI podkop.settings.block_doh, по умолчанию выключено.
podkop_extras_doh_enabled() {
	local value
	value=$(uci -q get podkop.settings.block_doh 2> /dev/null)

	_podkop_extras_is_true "$value"
}

#######################################
# Адреса DoH-резолверов по одному в строке.
# Arguments:
#   $1 - v4 (по умолчанию) | v6
#######################################
podkop_extras_doh_addresses() {
	local item

	if [ "$(_podkop_extras_family "$1")" = "v6" ]; then
		for item in $PODKOP_X_DOH_IPV6; do printf '%s\n' "$item"; done
	else
		for item in $PODKOP_X_DOH_IPV4; do printf '%s\n' "$item"; done
	fi
}

# Те же адреса, но одной строкой через запятую - как их ждёт nft.
podkop_extras_doh_elements() {
	local family
	family=$(_podkop_extras_family "$1")

	if [ "$family" = "v6" ]; then
		_podkop_extras_join_elements v6 "$PODKOP_X_DOH_IPV6"
	else
		_podkop_extras_join_elements v4 "$PODKOP_X_DOH_IPV4"
	fi
}

#######################################
# Наборы адресов DoH-резолверов.
#
# flush перед наполнением обязателен: список меняется от версии к версии, и
# без него в set накапливались бы адреса, выкинутые из константы.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_sets() {
	local table v4 v6
	table=$(_podkop_extras_table "$1")
	v4=$(podkop_extras_doh_elements v4)
	v6=$(podkop_extras_doh_elements v6)

	printf 'add table inet %s\n' "$table"
	printf 'add set inet %s %s { type ipv4_addr; flags interval; auto-merge; }\n' "$table" "$PODKOP_X_DOH_SET_V4"
	printf 'add set inet %s %s { type ipv6_addr; flags interval; auto-merge; }\n' "$table" "$PODKOP_X_DOH_SET_V6"
	printf 'flush set inet %s %s\n' "$table" "$PODKOP_X_DOH_SET_V4"
	printf 'flush set inet %s %s\n' "$table" "$PODKOP_X_DOH_SET_V6"

	[ -n "$v4" ] && printf 'add element inet %s %s { %s }\n' "$table" "$PODKOP_X_DOH_SET_V4" "$v4"
	[ -n "$v6" ] && printf 'add element inet %s %s { %s }\n' "$table" "$PODKOP_X_DOH_SET_V6" "$v6"

	return 0
}

# Правила отказа в одной цепочке: tcp/443 и udp/443, оба семейства.
#
# tcp закрывается RST'ом, udp - ICMP port unreachable (умолчание reject в
# семействе inet). Для QUIC этого достаточно: соединение падает сразу, и
# браузер уходит на обычный DNS.
_podkop_extras_doh_gen_reject_rules() {
	local table="$1" chain="$2"

	printf 'add rule inet %s %s ip daddr @%s tcp dport %s counter reject with tcp reset\n' \
		"$table" "$chain" "$PODKOP_X_DOH_SET_V4" "$PODKOP_X_DOH_PORT"
	printf 'add rule inet %s %s ip daddr @%s udp dport %s counter reject\n' \
		"$table" "$chain" "$PODKOP_X_DOH_SET_V4" "$PODKOP_X_DOH_PORT"
	printf 'add rule inet %s %s ip6 daddr @%s tcp dport %s counter reject with tcp reset\n' \
		"$table" "$chain" "$PODKOP_X_DOH_SET_V6" "$PODKOP_X_DOH_PORT"
	printf 'add rule inet %s %s ip6 daddr @%s udp dport %s counter reject\n' \
		"$table" "$chain" "$PODKOP_X_DOH_SET_V6" "$PODKOP_X_DOH_PORT"
}

#######################################
# Цепочка блокировки на hook forward - трафик клиентов из LAN.
#
# reject разрешён только в цепочках input/forward/output, поэтому своя
# цепочка, а не правило в mangle: та висит на prerouting.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_forward_chain() {
	local table
	table=$(_podkop_extras_table "$1")

	printf 'add chain inet %s %s { type filter hook forward priority %s; policy accept; }\n' \
		"$table" "$PODKOP_X_DOH_CHAIN_FORWARD" "$PODKOP_X_DOH_CHAIN_PRIORITY"
	printf 'flush chain inet %s %s\n' "$table" "$PODKOP_X_DOH_CHAIN_FORWARD"

	_podkop_extras_doh_gen_reject_rules "$table" "$PODKOP_X_DOH_CHAIN_FORWARD"
}

#######################################
# Цепочка блокировки на hook output - DoH самого роутера.
#
# Первым правилом пропускается трафик, помеченный меткой ядра: ядро ходит к
# своему upstream-DNS само, и если этот DNS из нашего списка, блокировать его
# нельзя - роутер останется без резолвера.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_output_chain() {
	local table
	table=$(_podkop_extras_table "$1")

	printf 'add chain inet %s %s { type filter hook output priority %s; policy accept; }\n' \
		"$table" "$PODKOP_X_DOH_CHAIN_OUTPUT" "$PODKOP_X_DOH_CHAIN_PRIORITY"
	printf 'flush chain inet %s %s\n' "$table" "$PODKOP_X_DOH_CHAIN_OUTPUT"
	printf 'add rule inet %s %s meta mark and %s == %s counter return\n' \
		"$table" "$PODKOP_X_DOH_CHAIN_OUTPUT" "$PODKOP_X_OUTBOUND_MARK" "$PODKOP_X_OUTBOUND_MARK"

	_podkop_extras_doh_gen_reject_rules "$table" "$PODKOP_X_DOH_CHAIN_OUTPUT"
}

#######################################
# Правила «не заворачивать DoH в ядро».
#
# insert, а не add: правило должно стоять раньше тех, что ставят метку, иначе
# трафик уже уедет в tproxy. Ставится в обе цепочки подкопа - и для трафика
# клиентов (mangle), и для трафика самого роутера (mangle_output).
#
# Требует, чтобы цепочки подкопа уже существовали: вызывать после
# create_nft_rules.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_skip_rules() {
	local table chain
	table=$(_podkop_extras_table "$1")

	for chain in "$PODKOP_X_MANGLE_CHAIN" "$PODKOP_X_MANGLE_OUTPUT_CHAIN"; do
		printf 'insert rule inet %s %s ip daddr @%s tcp dport %s counter return\n' \
			"$table" "$chain" "$PODKOP_X_DOH_SET_V4" "$PODKOP_X_DOH_PORT"
		printf 'insert rule inet %s %s ip daddr @%s udp dport %s counter return\n' \
			"$table" "$chain" "$PODKOP_X_DOH_SET_V4" "$PODKOP_X_DOH_PORT"
		printf 'insert rule inet %s %s ip6 daddr @%s tcp dport %s counter return\n' \
			"$table" "$chain" "$PODKOP_X_DOH_SET_V6" "$PODKOP_X_DOH_PORT"
		printf 'insert rule inet %s %s ip6 daddr @%s udp dport %s counter return\n' \
			"$table" "$chain" "$PODKOP_X_DOH_SET_V6" "$PODKOP_X_DOH_PORT"
	done
}

#######################################
# Весь скрипт блокировки DoH целиком.
#
# Функция чистая: опцию UCI не читает и nft не зовёт. Выключенность проверяет
# podkop_extras_doh_apply - так генерацию можно прогнать в тестах, не выдумывая
# состояние конфига.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_rules() {
	local table
	table=$(_podkop_extras_table "$1")

	podkop_extras_doh_gen_sets "$table"
	podkop_extras_doh_gen_forward_chain "$table"

	if _podkop_extras_is_true "$PODKOP_X_DOH_COVER_ROUTER"; then
		podkop_extras_doh_gen_output_chain "$table"
	fi

	podkop_extras_doh_gen_skip_rules "$table"
}

#######################################
# Скрипт снятия блокировки.
#
# Наборы адресов только чистятся, но не удаляются: на них ссылаются правила в
# цепочках подкопа, а удалить set, на который есть ссылка, ядро не даст.
# Пустой set не совпадает ни с чем, так что осиротевшее правило безвредно.
# Arguments:
#   $1 - имя таблицы (необязательно)
#######################################
podkop_extras_doh_gen_teardown() {
	local table chain
	table=$(_podkop_extras_table "$1")

	for chain in "$PODKOP_X_DOH_CHAIN_FORWARD" "$PODKOP_X_DOH_CHAIN_OUTPUT"; do
		printf 'flush chain inet %s %s\n' "$table" "$chain"
		printf 'delete chain inet %s %s\n' "$table" "$chain"
	done

	printf 'flush set inet %s %s\n' "$table" "$PODKOP_X_DOH_SET_V4"
	printf 'flush set inet %s %s\n' "$table" "$PODKOP_X_DOH_SET_V6"
}

#######################################
# Применить блокировку DoH, если она включена в конфиге.
# Arguments:
#   $1 - имя таблицы (необязательно)
# Returns:
#   0 если правила поставлены или фича выключена, 1 если nft не принял скрипт
#######################################
podkop_extras_doh_apply() {
	local table script
	table=$(_podkop_extras_table "$1")

	if ! podkop_extras_doh_enabled; then
		_podkop_extras_log "DoH blocking is disabled, skipping" "debug"
		return 0
	fi

	script=$(podkop_extras_doh_gen_rules "$table")
	if [ -z "$script" ]; then
		_podkop_extras_log "DoH blocking produced no rules, nothing to apply" "warn"
		return 0
	fi

	if _podkop_extras_nft_apply "$script"; then
		_podkop_extras_log "DoH blocking rules applied" "info"
		return 0
	fi

	_podkop_extras_log "Failed to apply DoH blocking rules" "error"
	return 1
}

# Снять блокировку. Ошибки проглатываются: снятие должно доводиться до конца
# из любого состояния.
podkop_extras_doh_clear() {
	local table
	table=$(_podkop_extras_table "$1")

	_podkop_extras_nft_apply_lenient "$(podkop_extras_doh_gen_teardown "$table")"
}

## =============================================================================
## ФИЧА 2: действие Bypass для секции
## =============================================================================
#
# У секции сейчас четыре типа: proxy, vpn, block, exclusion. Все четыре
# заворачивают трафик в ядро - разница только в том, что ядро с ним делает
# дальше (шлёт в туннель, отбивает reject'ом или выпускает через direct-out).
#
# Bypass - пятый тип, и он единственный, который решает вопрос до ядра:
# трафик секции просто не получает tproxy-метку и уходит обычным маршрутом.
#
# Отличие от exclusion, ради которого всё и затевалось:
#
#   exclusion: клиент -> mangle (метка) -> tproxy -> ядро -> direct-out -> WAN
#   bypass:    клиент -> mangle (return) -> WAN
#
# Практическая разница на слабом роутере заметная: трафик не проходит через
# пользовательское пространство дважды. Плюс он не зависит от зрелости ядра -
# на нашей ветке с clash-rs это отдельная ценность.
#
# Ограничение, о котором надо помнить: правило работает по адресу назначения.
# Домены в bypass-секции сами по себе не заработают - клиент получит на них
# FakeIP-адрес и уедет в ядро по правилу на диапазон FakeIP. Для доменов
# секции нужен resolve_real_ip_for_routing=1, тогда реальные адреса осядут в
# наборе и bypass отработает.

#######################################
# Вердикт nftables для действия секции.
#
# Ровно то же разделение, что у forkop в section_priority_action: bypass -
# единственное действие, которое НЕ ставит метку. Функция чистая и вынесена
# отдельно именно чтобы разница между bypass и остальными была одной строкой,
# которую видно в тесте.
# Arguments:
#   $1 - действие секции
# Outputs:
#   хвост правила nft
# Returns:
#   1 для неизвестного действия, ничего не печатая
#######################################
podkop_extras_section_verdict() {
	case "$1" in
	bypass) printf 'counter return' ;;
	proxy | vpn | block | exclusion) printf 'meta mark set %s counter' "$PODKOP_X_FAKEIP_MARK" ;;
	*) return 1 ;;
	esac
}

# Заходит ли трафик такой секции в ядро.
podkop_extras_action_enters_core() {
	case "$1" in
	bypass) return 1 ;;
	proxy | vpn | block | exclusion) return 0 ;;
	*) return 1 ;;
	esac
}

# Имя набора адресов для bypass-секции.
# Arguments:
#   $1 - имя секции
#   $2 - v4 (по умолчанию) | v6
podkop_extras_bypass_set_name() {
	printf '%s%s_%s' \
		"$PODKOP_X_BYPASS_SET_PREFIX" \
		"$(podkop_extras_nft_ident "$1")" \
		"$(_podkop_extras_family "$2")"
}

# Тип секции из конфига. Пусто, если секции нет или тип не задан.
podkop_extras_section_action() {
	local section="$1"

	[ -n "$section" ] || return 1
	uci -q get "podkop.$section.connection_type" 2> /dev/null
}

# Секции с действием bypass, по одной в строке.
podkop_extras_bypass_sections() {
	uci -q show podkop 2> /dev/null | grep "\.connection_type='bypass'" | cut -d'.' -f2
}

#######################################
# Наборы адресов bypass-секции.
# Arguments:
#   $1 - имя таблицы (необязательно)
#   $2 - имя секции
#######################################
podkop_extras_bypass_gen_sets() {
	local table section
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	printf 'add table inet %s\n' "$table"
	printf 'add set inet %s %s { type ipv4_addr; flags interval; auto-merge; }\n' \
		"$table" "$(podkop_extras_bypass_set_name "$section" v4)"
	printf 'add set inet %s %s { type ipv6_addr; flags interval; auto-merge; }\n' \
		"$table" "$(podkop_extras_bypass_set_name "$section" v6)"
}

#######################################
# Правила «не заворачивать в ядро» для bypass-секции.
#
# insert, потому что правило обязано стоять раньше правил, ставящих метку:
# в цепочке подкопа они идут первыми и сработали бы раньше нашего.
#
# Обе цепочки: mangle ловит трафик клиентов, mangle_output - трафик самого
# роутера. Без второй bypass был бы половинчатым.
# Arguments:
#   $1 - имя таблицы (необязательно)
#   $2 - имя секции
#######################################
podkop_extras_bypass_gen_rules() {
	local table section set4 set6 verdict chain
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	set4=$(podkop_extras_bypass_set_name "$section" v4)
	set6=$(podkop_extras_bypass_set_name "$section" v6)
	verdict=$(podkop_extras_section_verdict bypass)

	for chain in "$PODKOP_X_MANGLE_CHAIN" "$PODKOP_X_MANGLE_OUTPUT_CHAIN"; do
		printf 'insert rule inet %s %s ip daddr @%s %s\n' "$table" "$chain" "$set4" "$verdict"
		printf 'insert rule inet %s %s ip6 daddr @%s %s\n' "$table" "$chain" "$set6" "$verdict"
	done
}

#######################################
# Наполнение наборов bypass-секции.
#
# Элементы раскладываются по семействам сами, по наличию двоеточия. Всё, что
# не похоже на адрес или подсеть, молча выбрасывается: список приходит из
# пользовательского конфига, и одна кривая строка не должна ронять транзакцию,
# уносящую с собой все остальные правила.
# Arguments:
#   $1 - имя таблицы (необязательно)
#   $2 - имя секции
#   $3.. - адреса и подсети через пробел, запятую или перевод строки
#######################################
podkop_extras_bypass_gen_elements() {
	local table section items v4 v6
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	shift 2
	items="$*"

	v4=$(_podkop_extras_join_elements v4 "$items")
	v6=$(_podkop_extras_join_elements v6 "$items")

	[ -n "$v4" ] && printf 'add element inet %s %s { %s }\n' \
		"$table" "$(podkop_extras_bypass_set_name "$section" v4)" "$v4"
	[ -n "$v6" ] && printf 'add element inet %s %s { %s }\n' \
		"$table" "$(podkop_extras_bypass_set_name "$section" v6)" "$v6"

	return 0
}

#######################################
# Весь скрипт bypass-секции: наборы, наполнение, правила.
# Arguments:
#   $1 - имя таблицы (необязательно)
#   $2 - имя секции
#   $3.. - адреса и подсети (необязательно)
#######################################
podkop_extras_bypass_gen() {
	local table section
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	shift 2
	podkop_extras_bypass_gen_sets "$table" "$section"
	podkop_extras_bypass_gen_elements "$table" "$section" "$@"
	podkop_extras_bypass_gen_rules "$table" "$section"
}

#######################################
# Применить bypass для секции.
#
# Тип секции проверяется здесь, а не в генераторе: генерация остаётся чистой,
# а решение «эта секция вообще bypass?» принимается один раз и по конфигу.
# Arguments:
#   $1 - имя таблицы (необязательно)
#   $2 - имя секции
#   $3.. - адреса и подсети (необязательно)
# Returns:
#   0 если правила поставлены или секция не bypass, 1 если nft не принял скрипт
#######################################
podkop_extras_bypass_apply() {
	local table section action script
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	action=$(podkop_extras_section_action "$section")
	if [ "$action" != "bypass" ]; then
		_podkop_extras_log "Section '$section' is not bypass, skipping nft bypass rules" "debug"
		return 0
	fi

	shift 2
	script=$(podkop_extras_bypass_gen "$table" "$section" "$@")
	[ -n "$script" ] || return 0

	if _podkop_extras_nft_apply "$script"; then
		_podkop_extras_log "Bypass rules applied for section '$section'" "info"
		return 0
	fi

	_podkop_extras_log "Failed to apply bypass rules for section '$section'" "error"
	return 1
}

# Очистить наборы bypass-секции. Сами наборы не удаляем по той же причине,
# что и в DoH: на них ссылаются правила в цепочках подкопа.
podkop_extras_bypass_clear() {
	local table section
	table=$(_podkop_extras_table "$1")
	section="$2"

	[ -n "$section" ] || return 1

	_podkop_extras_nft_apply_lenient "$(
		printf 'flush set inet %s %s\n' "$table" "$(podkop_extras_bypass_set_name "$section" v4)"
		printf 'flush set inet %s %s\n' "$table" "$(podkop_extras_bypass_set_name "$section" v6)"
	)"
}
