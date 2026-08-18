#!/bin/sh
# Тесты сборщика конфигурации clash-rs.
#
# Проверяется не отдельная функция, а конфиг целиком: собрать его из настроек
# UCI - это и есть работа модуля, а сломаться там можно только в стыках между
# слоями. Поэтому менеджер, фасад, списки и переключатель наборов здесь
# настоящие, а заглушками закрыто ровно то, чего нет на машине разработчика:
#
#   - config_get и соседи из /lib/functions.sh (openwrt)
#   - функции самого /usr/bin/podkop, которые сборщик зовёт наружу
#   - nft, скачивание списков, проверка конфига ядром
#
# Порядок правил проверяется отдельно и подробно: у Clash выигрывает первое
# совпавшее правило, а значит порядок - это и есть маршрутизация. Один и тот
# же набор списков, разложенный в другом порядке, даёт другой роутер.
#
# Запуск:
#   JQ=$(pwd)/tests/jq.exe PODKOP_TESTS_SHELL=dash dash tests/run.sh builder
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

# Windows: git-bash переписывает аргументы, похожие на пути, когда зовёт
# нативный jq.exe - "/dns-query" превращается в "C:/Program Files/Git/dns-query".
# run.sh ставит это в окружение до старта процесса, здесь только страховка.
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

LIB=$(cd "$(dirname "$0")/../podkop/files/usr/lib" && pwd)
FIXTURES=$(cd "$(dirname "$0")/fixtures" && pwd)
PODKOP_LIB="$LIB"
export PODKOP_LIB

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

CALLS="$TMP/calls.log"
: >"$CALLS"

CONFIG_OUT="$TMP/clash-config.json"

# Модуль зовёт jq по имени, как и на роутере
jq() { "$JQ" "$@"; }

# --- заглушка настроек UCI ---------------------------------------------------
# Значения лежат в переменных CFG_<поколение>_<секция>_<опция>. Поколение
# растёт на каждом сценарии: так значения прошлого сценария недостижимы, а
# чистить их поимённо не приходится. Имена секций в тестах - только буквы.

CFG_GEN=0
CFG_SECTIONS=""

cfg_new() {
	CFG_GEN=$((CFG_GEN + 1))
	CFG_SECTIONS=""
}

# cfg_section <имя> - объявить секцию. Порядок объявления значим: config_foreach
# обходит секции ровно в нём, и от него зависит порядок правил.
cfg_section() { CFG_SECTIONS="${CFG_SECTIONS}${CFG_SECTIONS:+ }$1"; }

# cfg_set <секция> <опция> <значение>. Список - значения через пробел.
cfg_set() { eval "CFG_${CFG_GEN}_${1}_${2}=\$3"; }

config_get() {
	local __var="$1" __sec="$2" __opt="$3" __def="$4" __val
	eval "__val=\${CFG_${CFG_GEN}_${__sec}_${__opt}:-}"
	[ -n "$__val" ] || __val="$__def"
	eval "$__var=\$__val"
}

config_get_bool() {
	local __var="$1" __val
	config_get "$__var" "$2" "$3" "$4"
	eval "__val=\$$__var"
	case "$__val" in
	1 | on | true | yes | enabled) __val=1 ;;
	0 | off | false | no | disabled) __val=0 ;;
	*) __val="${4:-0}" ;;
	esac
	eval "$__var=\$__val"
}

config_foreach() {
	local __func="$1"
	shift
	[ $# -gt 0 ] && shift # тип секции: у подкопа он всегда "section"

	local __section
	for __section in $CFG_SECTIONS; do
		"$__func" "$__section" "$@"
	done
}

config_list_foreach() {
	local __sec="$1" __opt="$2" __func="$3"
	shift 3

	local __items __item
	eval "__items=\${CFG_${CFG_GEN}_${__sec}_${__opt}:-}"
	for __item in $__items; do
		"$__func" "$__item" "$@"
	done
}

# --- заглушки окружения роутера ---------------------------------------------

log() { :; }

# helpers.sh написан на bash-синтаксисе ([[ ]]), под dash эти функции молча
# возвращают ошибку. Подменяем те две, которыми пользуется сборщик.
file_exists() { [ -f "$1" ]; }

parse_domain_or_subnet_string_to_commas_string() {
	local out="" item
	for item in $(printf '%s' "$1" | tr ',' ' '); do
		out="${out}${out:+,}$item"
	done
	printf '%s' "$out"
}

# nft: сборщик обязан позвать их ровно там же, где апстрим
nft_list_all_traffic_from_ip() { printf 'nft_source_ip %s\n' "$1" >>"$CALLS"; }
nft_add_set_elements() { printf 'nft_set_elements %s\n' "$3" >>"$CALLS"; }
nft_add_set_elements_from_file_chunked() { printf 'nft_set_file %s\n' "$1" >>"$CALLS"; }

# функции самого /usr/bin/podkop: повторены дословно, чтобы порядок обхода
# секций совпадал с настоящим
_determine_first_outbound_section() {
	local section="$1"
	local connection_type
	config_get connection_type "$section" "connection_type"
	if [ "$connection_type" = "proxy" ] || [ "$connection_type" = "vpn" ]; then
		[ -z "$first_section" ] && first_section="$1"
	fi
	return 0
}

get_first_outbound_section() {
	local first_section=""
	config_foreach _determine_first_outbound_section "section"
	printf '%s' "$first_section"
}

section_has_enabled_lists() {
	local section="$1"
	local community_lists user_domain_list_type user_subnet_list_type local_domain_lists local_subnet_lists \
		remote_domain_lists remote_subnet_lists

	config_get community_lists "$section" "community_lists"
	config_get user_domain_list_type "$section" "user_domain_list_type" "disabled"
	config_get user_subnet_list_type "$section" "user_subnet_list_type" "disabled"
	config_get local_domain_lists "$section" "local_domain_lists"
	config_get local_subnet_lists "$section" "local_subnet_lists"
	config_get remote_domain_lists "$section" "remote_domain_lists"
	config_get remote_subnet_lists "$section" "remote_subnet_lists"

	[ -n "$community_lists" ] ||
		[ "$user_domain_list_type" != "disabled" ] ||
		[ "$user_subnet_list_type" != "disabled" ] ||
		[ -n "$local_domain_lists" ] ||
		[ -n "$local_subnet_lists" ] ||
		[ -n "$remote_domain_lists" ] ||
		[ -n "$remote_subnet_lists" ]
}

get_service_listen_address() { printf '%s' "192.168.1.1"; }
get_service_proxy_address() { printf '%s' ""; }

# uci нужен только слою ядра: он читает из него выбранное ядро
uci() {
	case "$*" in
	*podkop.settings.core*) printf '%s' "clash-rs" ;;
	*) return 1 ;;
	esac
}

# --- модули под тестом -------------------------------------------------------

. "$LIB/constants.sh"
. "$LIB/helpers.sh"
. "$LIB/clash_config_manager.sh"
. "$LIB/clash_config_facade.sh"
. "$LIB/core.sh"
. "$LIB/clash_rulesets.sh"
. "$LIB/ruleset_dispatch.sh"
. "$LIB/clash_config_builder.sh"

# helpers.sh перекрывает наши заглушки, поэтому ставим их заново
file_exists() { [ -f "$1" ]; }
parse_domain_or_subnet_string_to_commas_string() {
	local out="" item
	for item in $(printf '%s' "$1" | tr ',' ' '); do
		out="${out}${out:+,}$item"
	done
	printf '%s' "$out"
}

# пути и проверка конфига - в песочницу, ядра на машине разработчика нет
core_config_path() { printf '%s' "$CONFIG_OUT"; }
core_check_config() {
	printf 'core_check %s\n' "$1" >>"$CALLS"
	return "${CORE_CHECK_RC:-0}"
}
ruleset_folder() { printf '%s' "$TMP/rulesets"; }

# скачивание подменяем: тест не должен ходить в сеть. Payload собирается из
# фикстуры настоящим конвертером, чтобы behavior определялся как на роутере.
clash_rs_prepare_remote_list() {
	local url="$1" dst="$2" format="$3"
	printf 'download %s\n' "$url" >>"$CALLS"
	clash_rs_convert_list "$REMOTE_LIST_FIXTURE" "$dst" "$format"
}
REMOTE_LIST_FIXTURE="$FIXTURES/subnets.lst"

# --- служебное ---------------------------------------------------------------

VLESS_URL="vless://fe0f0941-09a9-4e46-bc69-e00190d7bb9c@127.0.0.1:10156?type=tcp&security=reality&pbk=key&sni=google.com&flow=xtls-rprx-vision"
VLESS_URL2="vless://fe0f0941-09a9-4e46-bc69-e00190d7bb9c@127.0.0.2:10157?type=tcp&security=none"

# Собрать конфиг и вернуть то, что легло на диск.
build() {
	rm -f "$CONFIG_OUT"
	: >"$CALLS"
	clash_init_config
	cat "$CONFIG_OUT" 2>/dev/null
}

calls() { cat "$CALLS"; }

# assert_rule_before <правило> <правило> <конфиг>
# Проверяет, что первое правило стоит выше второго: у Clash это и означает
# "сработает первое".
assert_rule_before() {
	local got
	got=$(printf '%s' "$3" | "$JQ" -r --arg a "$1" --arg b "$2" '
		(.rules | index($a)) as $ia
		| (.rules | index($b)) as $ib
		| if $ia == null then "нет правила: " + $a
		  elif $ib == null then "нет правила: " + $b
		  elif $ia < $ib then "да"
		  else "порядок обратный: " + ($ia | tostring) + " >= " + ($ib | tostring)
		  end')
	assert_eq "да" "$(_strip_cr "$got")"
}

# assert_has_rule <правило> <конфиг>
assert_has_rule() {
	local got
	got=$(printf '%s' "$2" | "$JQ" -r --arg a "$1" '.rules | index($a) != null')
	if [ "$(_strip_cr "$got")" = "true" ]; then
		_pass "$CURRENT_TEST"
	else
		_fail "$CURRENT_TEST" "нет правила: $1" \
			"правила:    $(printf '%s' "$2" | "$JQ" -c '.rules' | tr -d '\r')"
	fi
}

# ============================================================================
# Сценарий: полный конфиг из четырёх секций
#
# Порядок секций в UCI: blocked, main, excl, vpnsec. Он значим дважды - и для
# порядка правил, и для того, какая секция считается первой выходной.
# ============================================================================

cfg_new
cfg_set settings log_level "warn"
cfg_set settings dns_type "doh"
cfg_set settings dns_server "https://dns.google/dns-query"
cfg_set settings bootstrap_dns_server "77.88.8.8"
cfg_set settings update_interval "1d"
cfg_set settings enable_yacd "1"
cfg_set settings yacd_secret_key "s3cret"
cfg_set settings routing_excluded_ips "192.168.1.3"

cfg_section blocked
cfg_set blocked connection_type "block"
cfg_set blocked community_lists "porn"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"
cfg_set main community_lists "russia_inside"
cfg_set main user_domain_list_type "dynamic"
cfg_set main user_domains "example.com"
cfg_set main fully_routed_ips "192.168.1.2"

cfg_section excl
cfg_set excl connection_type "exclusion"
cfg_set excl user_subnet_list_type "dynamic"
cfg_set excl user_subnets "1.1.1.1"

cfg_section vpnsec
cfg_set vpnsec connection_type "vpn"
cfg_set vpnsec interface "awg0"
cfg_set vpnsec community_lists "telegram"

FULL=$(build)

# ---------------------------- конфиг целиком --------------------------------

it "полный конфиг разбирается как JSON"
assert_valid_json "$FULL"

it "конфиг записан по пути, который дал слой ядра"
assert_eq "да" "$([ -s "$CONFIG_OUT" ] && echo да || echo нет)"

it "перед записью конфиг проверен ядром"
assert_contains "core_check" "$(calls)"

# ---------------------------- лог -------------------------------------------

it "warn подкопа превращается в warning clash-rs"
assert_jq '.["log-level"]' "warning" "$FULL"

# ---------------------------- инбаунды --------------------------------------

it "tproxy слушает тот же порт, что и у sing-box"
assert_jq '.["tproxy-port"]' "1602" "$FULL"

it "адрес инбаундов - все интерфейсы: bind-address у Clash один на всех"
assert_jq '.["bind-address"]' "*" "$FULL"

it "без mixed-прокси порт не заводится"
assert_jq 'has("mixed-port")' "false" "$FULL"

# ---------------------------- прокси ----------------------------------------

it "у секции proxy появился прокси с именем секции"
assert_jq '.proxies[] | select(.name == "main-out") | .type' "vless" "$FULL"

it "секция vpn превращается в direct-прокси с привязкой к интерфейсу"
assert_jq '.proxies[] | select(.name == "vpnsec-out") | [.type, .["interface-name"]] | join(" ")' \
	"direct awg0" "$FULL"

it "секция block прокси не создаёт"
assert_jq '[.proxies[].name] | index("blocked-out") == null' "true" "$FULL"

it "секция exclusion прокси не создаёт"
assert_jq '[.proxies[].name] | index("excl-out") == null' "true" "$FULL"

it "прокси ровно два: block и exclusion в proxies не попадают"
assert_jq '.proxies | length' "2" "$FULL"

it "групп без selector и urltest не появляется"
assert_jq '.["proxy-groups"] | length' "0" "$FULL"

# ---------------------------- DNS -------------------------------------------

it "встроенный DNS включён"
assert_jq '.dns.enable' "true" "$FULL"

it "DNS слушает там же, где у sing-box стоял отдельный инбаунд"
assert_jq '.dns.listen' "127.0.0.42:53" "$FULL"

it "включён режим fake-ip"
assert_jq '.dns["enhanced-mode"]' "fake-ip" "$FULL"

it "диапазон fake-ip тот же, что подкоп отдавал sing-box"
assert_jq '.dns["fake-ip-range"]' "198.18.0.0/15" "$FULL"

it "DoH-сервер из настроек уехал в nameserver со схемой"
assert_jq '.dns.nameserver[0]' "https://dns.google/dns-query" "$FULL"

it "bootstrap уехал в default-nameserver, а не в общий список"
assert_jq '.dns["default-nameserver"][0]' "77.88.8.8" "$FULL"

it "локальные имена не получают поддельный адрес"
assert_jq '.dns["fake-ip-filter"] | index("+.lan") != null' "true" "$FULL"

# ---------------------------- Clash API и profile ---------------------------

it "external-controller поднят на адресе LAN и штатном порту"
assert_jq '.["external-controller"]' "192.168.1.1:9090" "$FULL"

it "секрет из настроек попал в конфиг"
assert_jq '.secret' "s3cret" "$FULL"

it "при включённом YACD объявлен каталог веб-интерфейса"
assert_jq '.["external-ui"]' "ui" "$FULL"

it "profile помнит выбор в группах"
assert_jq '.profile["store-selected"]' "true" "$FULL"

it "profile помнит выданные fake-ip"
assert_jq '.profile["store-fake-ip"]' "true" "$FULL"

# ---------------------------- правила: состав -------------------------------

it "режим маршрутизации - по правилам"
assert_jq '.mode' "rule" "$FULL"

it "канарейка Firefox отвергается"
assert_has_rule "DOMAIN-SUFFIX,use-application-dns.net,REJECT" "$FULL"

it "проверка внешнего адреса идёт в первую выходную секцию"
assert_has_rule "DOMAIN,ip.podkop.fyi,main-out" "$FULL"

it "список block-секции ведёт в REJECT"
assert_has_rule "RULE-SET,community-porn-provider,REJECT" "$FULL"

it "список exclusion-секции ведёт напрямую"
assert_has_rule "IP-CIDR,1.1.1.1/32,DIRECT,no-resolve" "$FULL"

it "исключённый адрес устройства уходит напрямую"
assert_has_rule "SRC-IP-CIDR,192.168.1.3/32,DIRECT" "$FULL"

it "адрес устройства целиком заворачивается в секцию"
assert_has_rule "SRC-IP-CIDR,192.168.1.2/32,main-out" "$FULL"

it "список сообщества секции ведёт в её прокси"
assert_has_rule "RULE-SET,community-russia_inside-provider,main-out" "$FULL"

it "домен пользователя ловится по суффиксу"
assert_has_rule "DOMAIN-SUFFIX,example.com,main-out" "$FULL"

it "список секции vpn ведёт в её прокси"
assert_has_rule "RULE-SET,community-telegram-provider,vpnsec-out" "$FULL"

it "у набора сообщества заведён провайдер правил"
assert_jq '.["rule-providers"]["community-russia_inside-provider"].type' "file" "$FULL"

# Список готовим мы, а не отдаём ядру ссылку: у Clash голый домен в
# behavior=domain это точное совпадение, а sing-box матчил суффиксом.
# prepare дописывает "+." - иначе "www.4pda.to" молча выпал бы из туннеля.
it "провайдер сообщества файловый, список подготовлен нами"
assert_jq '.["rule-providers"]["community-russia_inside-provider"] | has("path")' \
	"true" "$FULL"

it "провайдер сообщества не ходит в сеть сам"
assert_jq '.["rule-providers"]["community-russia_inside-provider"] | has("url")' \
	"false" "$FULL"

# Про интервал обновления проверки нет намеренно. Сюда его кладёт
# ruleset_add_community из ruleset_dispatch.sh, и кладёт не в то поле:
# у clash_cm_add_http_rule_provider седьмой аргумент - interval, а шестой -
# path, вызов же передаёт секунды шестым. В конфиге из-за этого получается
# path: "86400" и ни одного interval. Чинить это надо в переключателе
# наборов, а не здесь, поэтому тест не пишем - он закрепил бы либо чужой
# баг, либо чужое будущее исправление.

# ---------------------------- правила: порядок ------------------------------

it "финальный MATCH стоит последним"
assert_jq '.rules[-1]' "MATCH,DIRECT" "$FULL"

it "MATCH в правилах ровно один"
assert_jq '[.rules[] | select(startswith("MATCH,"))] | length' "1" "$FULL"

it "служебные правила подкопа идут раньше списков секций"
assert_rule_before "DOMAIN-SUFFIX,use-application-dns.net,REJECT" \
	"RULE-SET,community-russia_inside-provider,main-out" "$FULL"

it "блокировки проверяются раньше списков прокси-секции"
assert_rule_before "RULE-SET,community-porn-provider,REJECT" \
	"RULE-SET,community-russia_inside-provider,main-out" "$FULL"

it "исключения проверяются раньше списков прокси-секции, хоть секция и объявлена ниже"
assert_rule_before "IP-CIDR,1.1.1.1/32,DIRECT,no-resolve" \
	"RULE-SET,community-russia_inside-provider,main-out" "$FULL"

it "блокировки проверяются раньше исключений - как и в route.rules у sing-box"
assert_rule_before "RULE-SET,community-porn-provider,REJECT" \
	"IP-CIDR,1.1.1.1/32,DIRECT,no-resolve" "$FULL"

it "правила по адресу устройства идут после общих исключений"
assert_rule_before "IP-CIDR,1.1.1.1/32,DIRECT,no-resolve" \
	"SRC-IP-CIDR,192.168.1.2/32,main-out" "$FULL"

it "адрес устройства проверяется раньше списков секции"
assert_rule_before "SRC-IP-CIDR,192.168.1.2/32,main-out" \
	"RULE-SET,community-russia_inside-provider,main-out" "$FULL"

it "секции разбираются в порядке объявления в UCI: main раньше vpnsec"
assert_rule_before "RULE-SET,community-russia_inside-provider,main-out" \
	"RULE-SET,community-telegram-provider,vpnsec-out" "$FULL"

it "внутри секции списки идут в порядке апстрима: сообщество раньше доменов пользователя"
assert_rule_before "RULE-SET,community-russia_inside-provider,main-out" \
	"DOMAIN-SUFFIX,example.com,main-out" "$FULL"

# ---------------------------- побочные вызовы -------------------------------

it "адрес устройства заодно уехал в nft"
assert_contains "nft_source_ip 192.168.1.2" "$(calls)"

it "подсеть пользователя заодно уехала в nft"
assert_contains "nft_set_elements 1.1.1.1" "$(calls)"

# ============================================================================
# Сценарий: глобальный режим
#
# В форке netshift эта фича была сломана так: при global_proxy=1 функция
# построения правил выходила по return 0, правило секции не создавалось, и
# весь трафик проваливался в route.final напрямую. Здесь проверяется ровно
# обратное - правило строится, а глобальность выражается только целью MATCH.
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"
cfg_set main community_lists "russia_inside"
cfg_set main user_domain_list_type "dynamic"
cfg_set main user_domains "example.com"
cfg_set main global_proxy "1"

GLOBAL=$(build)

it "глобальный конфиг разбирается как JSON"
assert_valid_json "$GLOBAL"

it "неопознанный трафик уходит в глобальную секцию, а не напрямую"
assert_jq '.rules[-1]' "MATCH,main-out" "$GLOBAL"

it "MATCH,DIRECT при глобальном режиме не остаётся"
assert_jq '[.rules[] | select(. == "MATCH,DIRECT")] | length' "0" "$GLOBAL"

it "правило по списку секции при global_proxy СТРОИТСЯ, а не пропускается"
assert_has_rule "RULE-SET,community-russia_inside-provider,main-out" "$GLOBAL"

it "правило по доменам пользователя при global_proxy тоже строится"
assert_has_rule "DOMAIN-SUFFIX,example.com,main-out" "$GLOBAL"

it "провайдер набора при global_proxy тоже заводится"
assert_jq '.["rule-providers"] | has("community-russia_inside-provider")' "true" "$GLOBAL"

it "MATCH по-прежнему последний"
assert_jq '.rules | last | startswith("MATCH,")' "true" "$GLOBAL"

# --- глобальным можно пометить только секцию с выходом ----------------------

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section blocked
cfg_set blocked connection_type "block"
cfg_set blocked community_lists "porn"
cfg_set blocked global_proxy "1"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"

GLOBAL_BLOCK=$(build)

it "block-секция глобальной не становится: заворачивать трафик некуда"
assert_jq '.rules[-1]' "MATCH,DIRECT" "$GLOBAL_BLOCK"

it "и правила такой секции при этом на месте"
assert_has_rule "RULE-SET,community-porn-provider,REJECT" "$GLOBAL_BLOCK"

# --- две глобальные секции: выигрывает первая -------------------------------

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section first
cfg_set first connection_type "proxy"
cfg_set first proxy_config_type "url"
cfg_set first proxy_string "$VLESS_URL"
cfg_set first global_proxy "1"

cfg_section second
cfg_set second connection_type "proxy"
cfg_set second proxy_config_type "url"
cfg_set second proxy_string "$VLESS_URL2"
cfg_set second global_proxy "1"

GLOBAL_TWO=$(build)

it "глобальной становится первая по порядку секция"
assert_jq '.rules[-1]' "MATCH,first-out" "$GLOBAL_TWO"

it "вторая при этом остаётся обычной секцией со своим прокси"
assert_jq '.proxies[] | select(.name == "second-out") | .type' "vless" "$GLOBAL_TWO"

# ============================================================================
# Сценарий: пустая секция
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section empty

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"
cfg_set main community_lists "russia_inside"

EMPTY=$(build)

it "секция без единой настройки не роняет сборку"
assert_valid_json "$EMPTY"

it "пустая секция не создаёт прокси"
assert_jq '.proxies | length' "1" "$EMPTY"

it "соседняя секция при этом собирается целиком"
assert_has_rule "RULE-SET,community-russia_inside-provider,main-out" "$EMPTY"

it "финальное правило на месте"
assert_jq '.rules[-1]' "MATCH,DIRECT" "$EMPTY"

# --- секция с выходом, но без списков ---------------------------------------

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"

NOLISTS=$(build)

it "секция без списков даёт прокси, но не даёт правил маршрутизации"
assert_jq '[.rules[] | select(endswith(",main-out"))] | length' "1" "$NOLISTS"

it "и это правило - проверка внешнего адреса, а не список"
assert_has_rule "DOMAIN,ip.podkop.fyi,main-out" "$NOLISTS"

# --- секция с действием bypass ----------------------------------------------
# Действие из podkop_extras.sh: трафик не получает tproxy-метку и в ядро не
# заходит. В конфиге ядра о такой секции не должно быть ни строчки, но и
# ронять сборку незнакомым типом она не должна.

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section direct
cfg_set direct connection_type "bypass"
cfg_set direct community_lists "porn"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"

BYPASS=$(build)

it "секция bypass не обрывает сборку незнакомым типом"
assert_valid_json "$BYPASS"

it "секция bypass не создаёт прокси"
assert_jq '.proxies | length' "1" "$BYPASS"

it "секция bypass не создаёт правил: её трафик до ядра не доходит"
assert_jq '[.rules[] | select(contains("porn"))] | length' "0" "$BYPASS"

# ============================================================================
# Сценарий: группы selector и urltest
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section sel
cfg_set sel connection_type "proxy"
cfg_set sel proxy_config_type "selector"
cfg_set sel selector_proxy_links "$VLESS_URL $VLESS_URL2"

cfg_section ut
cfg_set ut connection_type "proxy"
cfg_set ut proxy_config_type "urltest"
cfg_set ut urltest_proxy_links "$VLESS_URL $VLESS_URL2"
cfg_set ut urltest_check_interval "3m"

# GROUPS - специальная переменная bash (список gid), присвоить её нельзя:
# под bash тест молча получал бы число вместо конфига. Имя намеренно другое.
GRP=$(build)

it "конфиг с группами валиден"
assert_valid_json "$GRP"

it "участники selector названы как у sing-box"
assert_jq '[.proxies[].name] | join(" ")' "sel-1-out sel-2-out ut-1-out ut-2-out" "$GRP"

it "группа selector названа именем секции - на него ссылаются правила"
assert_jq '.["proxy-groups"][] | select(.name == "sel-out") | .type' "select" "$GRP"

it "в группу selector вошли оба участника"
assert_jq '.["proxy-groups"][] | select(.name == "sel-out") | .proxies | join(" ")' \
	"sel-1-out sel-2-out" "$GRP"

it "у urltest заводится группа замера задержки"
assert_jq '.["proxy-groups"][] | select(.name == "ut-urltest-out") | .type' "url-test" "$GRP"

it "интервал проверки переведён из 3m в секунды"
assert_jq '.["proxy-groups"][] | select(.name == "ut-urltest-out") | .interval' "180" "$GRP"

it "поверх urltest стоит select, чтобы выбор можно было переключить руками"
assert_jq '.["proxy-groups"][] | select(.name == "ut-out") | [.type, (.proxies | join(" "))] | join(": ")' \
	"select: ut-1-out ut-2-out ut-urltest-out" "$GRP"

# ============================================================================
# Сценарий: списки из файла и по ссылке
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section lists
cfg_set lists connection_type "proxy"
cfg_set lists proxy_config_type "url"
cfg_set lists proxy_string "$VLESS_URL"
cfg_set lists local_domain_lists "$FIXTURES/domains.lst"
cfg_set lists remote_subnet_lists "https://example.invalid/subnets.lst"

LISTS=$(build)

it "конфиг со списками из файлов валиден"
assert_valid_json "$LISTS"

it "локальный список объявлен провайдером из файла"
assert_jq '.["rule-providers"]["lists-domains-local-domains-provider"].type' "file" "$LISTS"

it "behavior локального списка определён по содержимому, а не по имени файла"
assert_jq '.["rule-providers"]["lists-domains-local-domains-provider"].behavior' "domain" "$LISTS"

it "на локальный список ссылается правило"
assert_has_rule "RULE-SET,lists-domains-local-domains-provider,lists-out" "$LISTS"

it "у набора с доменами флага no-resolve нет: резолвить там нечего"
assert_jq '[.rules[] | select(startswith("RULE-SET,lists-domains-local"))] | .[0] | endswith("no-resolve")' \
	"false" "$LISTS"

it "payload локального списка лёг на диск"
assert_eq "да" "$([ -s "$TMP/rulesets/lists-domains-local-domains-provider.lst" ] && echo да || echo нет)"

it "удалённый список скачан подкопом, а не ядром"
assert_contains "download https://example.invalid/subnets.lst" "$(calls)"

it "удалённый список тоже объявлен провайдером из файла"
assert_jq '.["rule-providers"]["lists-subnets-remote-subnets-provider"].type' "file" "$LISTS"

it "behavior удалённого списка с подсетями - ipcidr"
assert_jq '.["rule-providers"]["lists-subnets-remote-subnets-provider"].behavior' "ipcidr" "$LISTS"

it "у набора с подсетями флаг no-resolve стоит"
assert_has_rule "RULE-SET,lists-subnets-remote-subnets-provider,lists-out,no-resolve" "$LISTS"

# --- .srs по ссылке ---------------------------------------------------------

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section lists
cfg_set lists connection_type "proxy"
cfg_set lists proxy_config_type "url"
cfg_set lists proxy_string "$VLESS_URL"
cfg_set lists remote_domain_lists "https://example.invalid/domains.srs"

SRS=$(build)

it "ссылка на .srs не роняет сборку"
assert_valid_json "$SRS"

it ".srs не скачивается: clash-rs его не читает"
assert_not_contains "download" "$(calls)"

it "провайдера для .srs не появляется"
assert_jq '.["rule-providers"] | length' "0" "$SRS"

it "и правила со ссылкой на несуществующий набор - тоже"
assert_jq '[.rules[] | select(startswith("RULE-SET,"))] | length' "0" "$SRS"

# ============================================================================
# Сценарий: mixed-инбаунд
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"
cfg_set main mixed_proxy_enabled "1"
cfg_set main mixed_proxy_port "2080"

MIXED=$(build)

it "mixed-порт секции поднят"
assert_jq '.["mixed-port"]' "2080" "$MIXED"

# --- два претендента на единственный порт -----------------------------------

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"
cfg_set settings download_lists_via_proxy "1"
cfg_set settings download_lists_via_proxy_section "main"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"
cfg_set main mixed_proxy_enabled "1"
cfg_set main mixed_proxy_port "2080"

MIXED_TWO=$(build)

it "служебный mixed-инбаунд забирает единственный порт: без него не скачать списки"
assert_jq '.["mixed-port"]' "4534" "$MIXED_TWO"

# ============================================================================
# Сценарий: отказы
# ============================================================================

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "телепортация"

it "незнакомый тип подключения обрывает сборку, а не собирает полконфига"
(build) >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "vmess://кто-это"

it "неразбираемая ссылка обрывает сборку, а не оставляет пустой конфиг"
(build) >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

cfg_new
cfg_set settings dns_type "udp"
cfg_set settings dns_server "77.88.8.8"

cfg_section main
cfg_set main connection_type "proxy"
cfg_set main proxy_config_type "url"
cfg_set main proxy_string "$VLESS_URL"

it "конфиг, забракованный ядром, не подменяет рабочий"
rm -f "$CONFIG_OUT"
CORE_CHECK_RC=1
(build) >/dev/null 2>&1
CORE_CHECK_RC=0
assert_eq "нет" "$([ -f "$CONFIG_OUT" ] && echo да || echo нет)"

finish
