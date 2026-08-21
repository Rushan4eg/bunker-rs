#!/bin/sh
# Тесты подписок на серверы для clash-rs.
#
# Сеть здесь не трогается ВОВСЕ, и это не ограничение теста, а суть модуля:
# скачиванием подписки занимается само ядро через proxy-providers, а наш код
# только собирает описание провайдера. Проверять, стало быть, нечего, кроме
# получившегося куска конфига - что и делается.
#
# Настоящие здесь clash_rulesets.sh (ради clash_rs_interval_to_seconds) и
# слой ядра; заглушками закрыто ровно то, чего нет на машине разработчика:
# config_get из /lib/functions.sh и uci, из которого слой ядра читает выбор
# ядра.
#
# Запуск:
#   JQ=$(pwd)/tests/jq.exe PODKOP_TESTS_SHELL=dash dash tests/run.sh subscription
#
# shellcheck shell=sh
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

# Windows: git-bash переписывает аргументы, похожие на пути, когда зовёт
# нативный jq.exe - "/tmp/x" превращается в "C:/Program Files/Git/tmp/x", и
# проверки путей внутри конфига врали бы. run.sh ставит это в окружение до
# старта процесса, здесь только страховка.
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

LIB=$(cd "$(dirname "$0")/../podkop/files/usr/lib" && pwd)

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# Каталог, куда ядро складывало бы скачанные подписки. В тестах он же и
# создаётся модулем - на живом роутере это /tmp/clash-rs/providers.
CLASH_SUB_PROVIDER_DIR="$TMP/providers"

# --- заглушка выбора ядра ---------------------------------------------------
# core.sh читает podkop.settings.core через uci; подменяем его файлом, чтобы
# ядро можно было переключать посреди набора.

UCI_CORE_FILE="$TMP/uci_core"
printf 'clash-rs' >"$UCI_CORE_FILE"

uci() {
	case "$*" in
	*podkop.settings.core*) cat "$UCI_CORE_FILE" ;;
	*) return 1 ;;
	esac
}
set_core() { printf '%s' "$1" >"$UCI_CORE_FILE"; }

# --- заглушка настроек UCI ---------------------------------------------------
# Тот же приём, что в clash_builder_test.sh: значения лежат в переменных
# CFG_<поколение>_<секция>_<опция>, поколение растёт на каждом сценарии, так
# что настройки прошлого сценария недостижимы и чистить их не приходится.
# Имена секций в тестах - только буквы.

CFG_GEN=0

cfg_new() { CFG_GEN=$((CFG_GEN + 1)); }

# cfg_set <секция> <опция> <значение>. Список - значения через пробел, ровно
# так же их отдаёт настоящий config_get для "list" в UCI.
cfg_set() { eval "CFG_${CFG_GEN}_${1}_${2}=\$3"; }

config_get() {
	local __var="$1" __sec="$2" __opt="$3" __def="$4" __val
	eval "__val=\${CFG_${CFG_GEN}_${__sec}_${__opt}:-}"
	[ -n "$__val" ] || __val="$__def"
	eval "$__var=\$__val"
}

# --- модули ------------------------------------------------------------------

. "$LIB/core.sh"
. "$LIB/clash_rulesets.sh"
. "$LIB/clash_subscriptions.sh"

C=$(clash_empty_config)

SUB_A="https://panel.example/api/sub/token-a"
SUB_B="https://second.example/sub?token=b"

# Провайдер по имени: фильтр повторяется в каждой второй проверке
prov() { printf '.["proxy-providers"]["%s"]' "$1"; }

# ============================ имена и пути ==================================

it "имя провайдера собирается из секции и номера"
assert_eq "main-sub2" "$(clash_sub_provider_name main 2)"

it "номер провайдера по умолчанию первый"
assert_eq "main-sub1" "$(clash_sub_provider_name main)"

it "путь провайдера ведёт в каталог подписок"
assert_eq "$TMP/providers/main-sub1.yaml" "$(clash_sub_provider_path main-sub1)"

it "без переопределения каталог берётся у слоя ядра"
assert_eq "/tmp/clash-rs/providers" \
	"$(CLASH_SUB_PROVIDER_DIR="" clash_sub_provider_dir)"

it "имя группы совпадает с именем выхода секции"
assert_eq "main-out" "$(clash_sub_group_name main)"

# ============================ health-check ==================================

it "health_check_json включает проверку"
assert_jq '.enable' "true" "$(clash_sub_health_check_json "" "" "" "")"

it "health_check_json без url подставляет умолчание"
assert_jq '.url' "https://www.gstatic.com/generate_204" \
	"$(clash_sub_health_check_json 1 "" "" "")"

it "health_check_json переводит интервал в секунды"
assert_jq '.interval' "300" "$(clash_sub_health_check_json 1 "" "5m" "")"

it "health_check_json принимает интервал числом"
assert_jq '.interval' "120" "$(clash_sub_health_check_json 1 "" "120" "")"

it "health_check_json без lazy поля не заводит"
assert_jq 'has("lazy")' "false" "$(clash_sub_health_check_json 1 "" "" "")"

it "health_check_json с lazy=1 пишет true"
assert_jq '.lazy' "true" "$(clash_sub_health_check_json 1 "" "" 1)"

it "health_check_json с lazy=0 пишет false"
assert_jq '.lazy' "false" "$(clash_sub_health_check_json 1 "" "" 0)"

it "health_check_json выключается нулём"
assert_json_eq '{"enable":false}' "$(clash_sub_health_check_json 0 "" "" "")"

it "выключенный health-check не тащит за собой url"
assert_jq 'has("url")' "false" "$(clash_sub_health_check_json false "" "" "")"

# ============================ описание провайдера ===========================

it "provider_json собирает http-провайдера"
assert_jq '.type' "http" "$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json кладёт ссылку как есть"
assert_jq '.url' "$SUB_A" "$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json без интервала берёт час"
assert_jq '.interval' "3600" "$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json переводит 12h в секунды"
assert_jq '.interval' "43200" "$(clash_sub_provider_json "$SUB_A" "" 12h "" "" "" "")"

it "provider_json с битым интервалом откатывается на умолчание"
assert_jq '.interval' "3600" "$(clash_sub_provider_json "$SUB_A" "" "полчаса" "" "" "" "")"

it "provider_json без пути поля path не заводит"
assert_jq 'has("path")' "false" "$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json без фильтров их не заводит"
assert_jq '[has("filter"), has("exclude-filter")] | join(",")' "false,false" \
	"$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json без health-check подставляет свой"
assert_jq '.["health-check"].enable' "true" \
	"$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "")"

it "provider_json берёт переданный health-check"
assert_jq '.["health-check"].interval' "60" \
	"$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" '{"enable":true,"interval":60}')"

it "provider_json отказывается от пустой ссылки"
assert_eq "1" "$(clash_sub_provider_json "" "" "" "" "" "" "" >/dev/null 2>&1; echo $?)"

it "provider_json отказывается от health-check, который не JSON"
assert_eq "1" "$(clash_sub_provider_json "$SUB_A" "" "" "" "" "" "не json" >/dev/null 2>&1; echo $?)"

# ============================ proxy-providers в конфиге =====================

it "add_raw_provider заводит раздел proxy-providers"
assert_jq '.["proxy-providers"] | keys | join(",")' "main-sub1" \
	"$(clash_sub_add_raw_provider "$C" main-sub1 '{"type":"http"}')"

it "add_raw_provider дописывает, а не затирает"
assert_jq '.["proxy-providers"] | keys | sort | join(",")' "main-sub1,main-sub2" \
	"$(clash_sub_add_raw_provider \
		"$(clash_sub_add_raw_provider "$C" main-sub1 '{"type":"http"}')" \
		main-sub2 '{"type":"http"}')"

it "add_raw_provider не трогает остальной конфиг"
assert_jq '.rules | length' "0" \
	"$(clash_sub_add_raw_provider "$C" main-sub1 '{"type":"http"}')"

it "add_raw_provider не пускает в конфиг не-JSON"
assert_eq "1" "$(clash_sub_add_raw_provider "$C" main-sub1 'мусор' >/dev/null 2>&1; echo $?)"

it "add_raw_provider не пускает провайдера без имени"
assert_eq "1" "$(clash_sub_add_raw_provider "$C" "" '{"type":"http"}' >/dev/null 2>&1; echo $?)"

# ============================ группы поверх провайдеров =====================

it "add_provider_group собирает url-test"
assert_jq '.["proxy-groups"][0].type' "url-test" \
	"$(clash_sub_add_provider_group "$C" auto urltest '["main-sub1"]' "" "" "" "" "")"

it "add_provider_group собирает select"
assert_jq '.["proxy-groups"][0].type' "select" \
	"$(clash_sub_add_provider_group "$C" main-out selector '["main-sub1"]' "" "" "" "" "")"

it "add_provider_group ссылается на провайдера через use"
assert_jq '.["proxy-groups"][0].use | join(",")' "main-sub1,main-sub2" \
	"$(clash_sub_add_provider_group "$C" auto urltest '["main-sub1","main-sub2"]' "" "" "" "" "")"

it "add_provider_group без поимённых участников не пишет proxies"
assert_jq '.["proxy-groups"][0] | has("proxies")' "false" \
	"$(clash_sub_add_provider_group "$C" auto urltest '["main-sub1"]' "" "" "" "" "")"

it "add_provider_group пишет поимённых участников, если они есть"
assert_jq '.["proxy-groups"][0].proxies | join(",")' "main-urltest-out" \
	"$(clash_sub_add_provider_group "$C" main-out select '["main-sub1"]' '["main-urltest-out"]' "" "" "" "")"

it "add_provider_group переносит url, интервал и допуск"
assert_jq '.["proxy-groups"][0] | [.url, (.interval|tostring), (.tolerance|tostring)] | join(",")' \
	"http://cp.example/204,300,50" \
	"$(clash_sub_add_provider_group "$C" auto urltest '["main-sub1"]' "" "http://cp.example/204" 300 50 "")"

it "add_provider_group без необязательных полей их не заводит"
assert_jq '.["proxy-groups"][0] | [has("url"), has("interval"), has("tolerance"), has("lazy")] | join(",")' \
	"false,false,false,false" \
	"$(clash_sub_add_provider_group "$C" auto urltest '["main-sub1"]' "" "" "" "" "")"

it "add_provider_group отказывается от неизвестного типа"
assert_eq "1" "$(clash_sub_add_provider_group "$C" auto fallback '["main-sub1"]' "" "" "" "" "" >/dev/null 2>&1; echo $?)"

it "add_provider_group отказывается от use, который не массив"
assert_eq "1" "$(clash_sub_add_provider_group "$C" auto urltest '{"a":1}' "" "" "" "" "" >/dev/null 2>&1; echo $?)"

# ============================ ссылки секции =================================

cfg_new
cfg_set main subscription_url "$SUB_A"

it "одна ссылка читается из секции"
assert_eq "$SUB_A" "$(clash_sub_section_urls main)"

cfg_new
cfg_set main subscription_url "$SUB_A $SUB_B"

it "несколько ссылок отдаются построчно"
assert_eq "$SUB_A
$SUB_B" "$(clash_sub_section_urls main)"

cfg_new
cfg_set main subscription_url "$SUB_A $SUB_A"

it "точный дубликат ссылки выбрасывается"
assert_eq "$SUB_A" "$(clash_sub_section_urls main)"

cfg_new
cfg_set main subscription_url "vless://uuid@host:443 $SUB_A"

it "нессылка пропускается, годная остаётся"
assert_eq "$SUB_A" "$(clash_sub_section_urls main)"

cfg_new
cfg_set main subscription_url "просто-токен"

it "секция без годных ссылок возвращает ошибку"
assert_eq "1" "$(clash_sub_section_urls main >/dev/null 2>&1; echo $?)"

cfg_new

it "секция без опции подписки возвращает ошибку"
assert_eq "1" "$(clash_sub_section_urls main >/dev/null 2>&1; echo $?)"

# ============================ тип секции ====================================

cfg_new
cfg_set main proxy_config_type "subscription"

it "секция с proxy_config_type=subscription опознаётся"
assert_eq "0" "$(clash_sub_section_is_subscription main; echo $?)"

cfg_new
cfg_set main proxy_config_type "url"

it "обычная секция подписочной не считается"
assert_eq "1" "$(clash_sub_section_is_subscription main; echo $?)"

# ============================ одна подписка в секции ========================

cfg_new
cfg_set main subscription_url "$SUB_A"
OUT=$(clash_sub_configure_section "$C" main)

it "одна подписка даёт одного провайдера"
assert_jq '.["proxy-providers"] | keys | join(",")' "main-sub1" "$OUT"

it "провайдер подписки скачивается ядром по http"
assert_jq "$(prov main-sub1).type" "http" "$OUT"

it "ссылка подписки попадает в конфиг без изменений"
assert_jq "$(prov main-sub1).url" "$SUB_A" "$OUT"

it "у провайдера есть путь для скачанного"
assert_jq "$(prov main-sub1).path" "$TMP/providers/main-sub1.yaml" "$OUT"

it "каталог для скачанного создан заранее"
assert_eq "есть" "$([ -d "$TMP/providers" ] && echo есть)"

it "интервал обновления по умолчанию час в секундах"
assert_jq "$(prov main-sub1).interval" "3600" "$OUT"

it "health-check у провайдера есть и включён"
assert_jq "$(prov main-sub1)[\"health-check\"].enable" "true" "$OUT"

it "health-check знает, чем и как часто мерять"
assert_jq "$(prov main-sub1)[\"health-check\"] | [.url, (.interval|tostring)] | join(\",\")" \
	"https://www.gstatic.com/generate_204,300" "$OUT"


it "фильтров без настройки в конфиге нет"
assert_jq "$(prov main-sub1) | [has(\"filter\"), has(\"exclude-filter\")] | join(\",\")" \
	"false,false" "$OUT"

it "конфиг остаётся валидным JSON"
assert_valid_json "$OUT"

it "подписка не добавляет ничего в proxies"
assert_jq '.proxies | length' "0" "$OUT"

# ============================ группа поверх подписки ========================

it "по умолчанию заводятся две группы"
assert_jq '.["proxy-groups"] | length' "2" "$OUT"

it "первая группа - url-test с авто-выбором быстрейшего"
assert_jq '.["proxy-groups"][0] | [.name, .type] | join(",")' "main-urltest-out,url-test" "$OUT"

it "url-test-группа ссылается на провайдера подписки"
assert_jq '.["proxy-groups"][0].use | join(",")' "main-sub1" "$OUT"

it "url-test-группа получает url, интервал и допуск"
assert_jq '.["proxy-groups"][0] | [.url, (.interval|tostring), (.tolerance|tostring)] | join(",")' \
	"https://www.gstatic.com/generate_204,300,50" "$OUT"

it "вторая группа названа по секции - на неё смотрят правила"
assert_jq '.["proxy-groups"][1] | [.name, .type] | join(",")' "main-out,select" "$OUT"

it "select-группа тоже ссылается на провайдера"
assert_jq '.["proxy-groups"][1].use | join(",")' "main-sub1" "$OUT"

it "select-группа держит url-test отдельным участником"
assert_jq '.["proxy-groups"][1].proxies | join(",")' "main-urltest-out" "$OUT"

# ============================ несколько подписок в секции ===================

cfg_new
cfg_set main subscription_url "$SUB_A $SUB_B"
OUT=$(clash_sub_configure_section "$C" main)

it "две ссылки дают двух провайдеров"
assert_jq '.["proxy-providers"] | keys | sort | join(",")' "main-sub1,main-sub2" "$OUT"

it "у второго провайдера своя ссылка"
assert_jq "$(prov main-sub2).url" "$SUB_B" "$OUT"

it "у второго провайдера свой файл"
assert_jq "$(prov main-sub2).path" "$TMP/providers/main-sub2.yaml" "$OUT"

it "группа собирает серверы обеих подписок"
assert_jq '.["proxy-groups"][0].use | join(",")' "main-sub1,main-sub2" "$OUT"

it "select-группа тоже видит обе подписки"
assert_jq '.["proxy-groups"][1].use | join(",")' "main-sub1,main-sub2" "$OUT"

it "групп по-прежнему две, а не по одной на подписку"
assert_jq '.["proxy-groups"] | length' "2" "$OUT"

cfg_new
cfg_set main subscription_url "$SUB_A $SUB_A"
OUT=$(clash_sub_configure_section "$C" main)

it "дубликат ссылки не превращается во второго провайдера"
assert_jq '.["proxy-providers"] | length' "1" "$OUT"

# ============================ интервалы =====================================

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_update_interval "12h"
cfg_set main subscription_check_interval "30m"
OUT=$(clash_sub_configure_section "$C" main)

it "12h обновления превращаются в 43200 секунд"
assert_jq "$(prov main-sub1).interval" "43200" "$OUT"

it "30m проверки превращаются в 1800 секунд"
assert_jq "$(prov main-sub1)[\"health-check\"].interval" "1800" "$OUT"

it "та же цифра уезжает и в интервал группы"
assert_jq '.["proxy-groups"][0].interval' "1800" "$OUT"

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_update_interval "раз в сутки"
OUT=$(clash_sub_configure_section "$C" main)

it "неразобранный интервал не роняет сборку, а откатывается на час"
assert_jq "$(prov main-sub1).interval" "3600" "$OUT"

# ============================ фильтры =======================================

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_filter "Netherlands"
cfg_set main subscription_exclude_filter "(?i)expired|traffic"
OUT=$(clash_sub_configure_section "$C" main)



it "фильтр в proxy-group не попадает - такого поля у clash-rs нет"
assert_jq '.["proxy-groups"] | map(has("filter")) | join(",")' "false,false" "$OUT"

# ============================ User-Agent ====================================

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_user_agent "v2rayN/7.0.0"
OUT=$(clash_sub_configure_section "$C" main)


# ============================ тип группы ====================================

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_group_type "selector"
OUT=$(clash_sub_configure_section "$C" main)

it "тип selector даёт одну группу"
assert_jq '.["proxy-groups"] | length' "1" "$OUT"

it "эта группа - select с именем секции"
assert_jq '.["proxy-groups"][0] | [.name, .type] | join(",")' "main-out,select" "$OUT"

it "select-группа ссылается на провайдера"
assert_jq '.["proxy-groups"][0].use | join(",")' "main-sub1" "$OUT"

it "у select-группы нет допуска url-test"
assert_jq '.["proxy-groups"][0] | has("tolerance")' "false" "$OUT"

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_group_type "самый-быстрый"

it "неизвестный тип группы - ошибка, а не тихая сборка"
assert_eq "1" "$(clash_sub_configure_section "$C" main >/dev/null 2>&1; echo $?)"

it "при неизвестном типе группы конфиг возвращается прежним"
assert_json_eq "$C" "$(clash_sub_configure_section "$C" main 2>/dev/null)"

# Провайдеры к этому моменту уже собраны, и соблазн отдать конфиг "как есть"
# велик. Отдавать нельзя: ядро исправно качало бы подписку, на которую никто
# не ссылается, и в дашборде это выглядело бы рабочей секцией.
it "провайдеры не остаются в конфиге, если группу собрать не вышло"
assert_jq 'has("proxy-providers")' "false" "$(clash_sub_configure_section "$C" main 2>/dev/null)"

# ============================ прочие настройки ==============================

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_health_check "0"
OUT=$(clash_sub_configure_section "$C" main)

it "health-check выключается настройкой"
assert_jq "$(prov main-sub1)[\"health-check\"].enable" "false" "$OUT"

cfg_new
cfg_set main subscription_url "$SUB_A"
cfg_set main subscription_test_url "http://cp.cloudflare.com/generate_204"
cfg_set main subscription_tolerance "150"
cfg_set main subscription_lazy "1"
OUT=$(clash_sub_configure_section "$C" main)

it "свой адрес проверки доезжает до health-check"
assert_jq "$(prov main-sub1)[\"health-check\"].url" "http://cp.cloudflare.com/generate_204" "$OUT"

it "он же становится адресом замера у группы"
assert_jq '.["proxy-groups"][0].url' "http://cp.cloudflare.com/generate_204" "$OUT"

it "свой допуск доезжает до url-test-группы"
assert_jq '.["proxy-groups"][0].tolerance' "150" "$OUT"

it "lazy доезжает и до провайдера, и до группы"
assert_jq "[$(prov main-sub1)[\"health-check\"].lazy, .[\"proxy-groups\"][0].lazy] | join(\",\")" \
	"true,true" "$OUT"

# ============================ пустая ссылка =================================

cfg_new
cfg_set main subscription_url ""
OUT=$(clash_sub_configure_section "$C" main 2>/dev/null)

it "пустая ссылка не создаёт провайдера"
assert_jq 'has("proxy-providers")' "false" "$OUT"

it "пустая ссылка не создаёт и группы"
assert_jq '.["proxy-groups"] | length' "0" "$OUT"

it "конфиг при пустой ссылке возвращается нетронутым"
assert_json_eq "$C" "$OUT"

it "пустая ссылка - ошибка: секция без выхода не должна собраться молча"
assert_eq "1" "$(clash_sub_configure_section "$C" main >/dev/null 2>&1; echo $?)"

cfg_new
cfg_set main subscription_url "   "

it "ссылка из одних пробелов тоже ничего не создаёт"
assert_jq 'has("proxy-providers")' "false" "$(clash_sub_configure_section "$C" main 2>/dev/null)"

cfg_new
cfg_set main subscription_url "не-ссылка"

it "мусор вместо ссылки провайдера не создаёт"
assert_jq 'has("proxy-providers")' "false" "$(clash_sub_configure_section "$C" main 2>/dev/null)"

# ============================ активен sing-box ==============================

set_core "sing-box"

cfg_new
cfg_set main subscription_url "$SUB_A"
OUT=$(clash_sub_configure_section "$C" main)

it "при sing-box конфиг возвращается ровно таким, каким пришёл"
assert_json_eq "$C" "$OUT"

it "при sing-box раздел proxy-providers не заводится"
assert_jq 'has("proxy-providers")' "false" "$OUT"

it "при sing-box групп не прибавляется"
assert_jq '.["proxy-groups"] | length' "0" "$OUT"

it "при sing-box это не ошибка, а штатное бездействие"
assert_eq "0" "$(clash_sub_configure_section "$C" main >/dev/null 2>&1; echo $?)"

it "при sing-box каталог подписок не создаётся"
assert_eq "нет" "$(rm -rf "$TMP/providers"; clash_sub_configure_section "$C" main >/dev/null 2>&1; [ -d "$TMP/providers" ] || echo нет)"

set_core "clash-rs"

it "после возврата на clash-rs подписка снова собирается"
assert_jq '.["proxy-providers"] | length' "1" "$(clash_sub_configure_section "$C" main)"

# ============================ распознавание формата =========================
#
# Тело подписки мы не разбираем - только называем, что это, чтобы сказать
# человеку внятное вместо "группа пустая".

FMT="$TMP/body"

it "Clash-YAML опознаётся по ключу proxies"
printf 'port: 7890\nproxies:\n  - {name: a, type: vless}\n' >"$FMT.yaml"
assert_eq "clash" "$(clash_sub_detect_format "$FMT.yaml")"

it "список ссылок опознаётся как uri-list"
printf 'vless://uuid@host:443?type=tcp#NL\ntrojan://pass@host:443#DE\n' >"$FMT.uri"
assert_eq "uri-list" "$(clash_sub_detect_format "$FMT.uri")"

it "base64-блоб опознаётся как base64"
printf 'dmxlc3M6Ly91dWlkQGhvc3Q6NDQzP3R5cGU9dGNwI05MCg==\n' >"$FMT.b64"
assert_eq "base64" "$(clash_sub_detect_format "$FMT.b64")"

it "Xray-JSON опознаётся как json"
printf '{"outbounds":[{"protocol":"vless"}]}\n' >"$FMT.json"
assert_eq "json" "$(clash_sub_detect_format "$FMT.json")"

it "невнятное тело так и называется"
printf '<html><body>403 Forbidden</body></html>\n' >"$FMT.html"
assert_eq "unknown" "$(clash_sub_detect_format "$FMT.html")"

it "у несуществующего файла формата нет"
assert_eq "1" "$(clash_sub_detect_format "$FMT.нет" >/dev/null 2>&1; echo $?)"

it "Clash-YAML проверку проходит"
assert_eq "0" "$(clash_sub_check_provider_file main-sub1 "$FMT.yaml" >/dev/null 2>&1; echo $?)"

it "base64 проверку не проходит - это и есть повод сказать про User-Agent"
assert_eq "1" "$(clash_sub_check_provider_file main-sub1 "$FMT.b64" >/dev/null 2>&1; echo $?)"

it "пустой файл проверку не проходит"
: >"$FMT.empty"
assert_eq "1" "$(clash_sub_check_provider_file main-sub1 "$FMT.empty" >/dev/null 2>&1; echo $?)"

# ============================ чего в конфиге быть не должно =================
#
# clash-rs 0.10.8 знает у http-провайдера ровно четыре поля: url, interval,
# path и health-check (OutboundHttpProvider в clash-lib/src/config/internal/
# proxy.rs). Ни user-agent, ни filter, ни exclude-filter там нет, хотя в
# mihomo они есть. deny_unknown_fields у структуры не стоит, поэтому лишние
# ключи ядро молча проглотит - и это хуже ошибки: пользователь задал фильтр,
# ошибки не увидел, а серверы приехали все до одного.

PROV=$(clash_sub_provider_json "https://panel.example/sub" "/tmp/p.yaml" "1h" 	"" "" "" "$(clash_sub_health_check_json)")

it "user-agent не пишется: ядро зашивает свой и переопределить его нечем"
assert_jq 'has("user-agent")' "false" "$PROV"

it "filter не пишется: фильтрации на уровне конфига у clash-rs нет"
assert_jq 'has("filter")' "false" "$PROV"

it "exclude-filter не пишется по той же причине"
assert_jq 'has("exclude-filter")' "false" "$PROV"

it "у провайдера ровно те поля, которые ядро понимает"
assert_jq 'keys | sort | join(",")' "health-check,interval,path,type,url" "$PROV"

finish
