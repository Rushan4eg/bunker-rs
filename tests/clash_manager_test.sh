#!/bin/sh
# Тесты clash_config_manager.sh.
#
# На каждую функцию как минимум два случая: обычный и пограничный — пустой
# необязательный аргумент, спецсимволы в значении, повторный вызов (он должен
# дописывать, а не затирать). Отдельно проверяется порядок правил: в Clash он
# значим, выигрывает первое совпавшее.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

# Windows: git-bash переписывает аргументы, похожие на пути, когда зовёт
# нативный jq.exe — "/path" превращается в "C:/Program Files/Git/path".
# На роутере такого нет, и проверки путей из-за этого врали бы.
MSYS_NO_PATHCONV=1
MSYS2_ARG_CONV_EXCL='*'
export MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL

# Модуль зовёт jq по имени, как и на роутере. В тестах подменяем его
# портативным бинарником из JQ: функция перекрывает поиск по PATH.
jq() { "$JQ" "$@"; }

. "$(dirname "$0")/../podkop/files/usr/lib/clash_config_manager.sh"

C=$(clash_empty_config)
TMP="${TMPDIR:-/tmp}/clash_cm_test.$$"

# --- clash_cm_configure_log -------------------------------------------------

it "configure_log ставит указанный уровень"
assert_jq '.["log-level"]' "debug" "$(clash_cm_configure_log "$C" false debug)"

it "configure_log при disabled=true даёт silent, а не уровень"
assert_jq '.["log-level"]' "silent" "$(clash_cm_configure_log "$C" true debug)"

it "configure_log без уровня подставляет info"
assert_jq '.["log-level"]' "info" "$(clash_cm_configure_log "$C" "" "")"

# --- clash_cm_configure_route -----------------------------------------------

it "configure_route ставит режим"
assert_jq '.mode' "global" "$(clash_cm_configure_route "$C" global)"

it "configure_route без режима подставляет rule"
assert_jq '.mode' "rule" "$(clash_cm_configure_route "$C" "")"

it "configure_route заводит rules[] в пустом объекте"
assert_jq '.rules | type' "array" "$(clash_cm_configure_route '{}' rule)"

it "configure_route не затирает уже добавленные правила"
assert_jq '.rules | join(",")' "MATCH,DIRECT" \
	"$(clash_cm_configure_route "$(clash_cm_add_match_rule "$C" DIRECT)" rule)"

# --- clash_cm_configure_clash_api -------------------------------------------

it "configure_clash_api ставит адрес контроллера"
assert_jq '.["external-controller"]' "0.0.0.0:9090" \
	"$(clash_cm_configure_clash_api "$C" "0.0.0.0:9090" "" "")"

it "configure_clash_api ставит ui и секрет"
assert_jq '[.["external-ui"], .secret] | join(",")' "/www/ui,s3cret" \
	"$(clash_cm_configure_clash_api "$C" "0.0.0.0:9090" "/www/ui" "s3cret")"

it "configure_clash_api без ui и секрета не заводит эти ключи"
assert_jq '[has("external-ui"), has("secret")] | join(",")' "false,false" \
	"$(clash_cm_configure_clash_api "$C" "0.0.0.0:9090" "" "")"

it "configure_clash_api с пустым адресом убирает контроллер"
assert_jq 'has("external-controller")' "false" \
	"$(clash_cm_configure_clash_api "$(clash_cm_configure_clash_api "$C" "0.0.0.0:9090" "" "")" "" "" "")"

# --- clash_cm_configure_profile ---------------------------------------------

it "configure_profile включает хранение выбора и fake-ip"
assert_jq '.profile | [.["store-selected"], .["store-fake-ip"]] | join(",")' "true,true" \
	"$(clash_cm_configure_profile "$C" true true)"

it "configure_profile с пустыми аргументами даёт false"
assert_jq '.profile | [.["store-selected"], .["store-fake-ip"]] | join(",")' "false,false" \
	"$(clash_cm_configure_profile "$C" "" "")"

# --- clash_cm_configure_dns -------------------------------------------------

it "configure_dns включает резолвер и задаёт слушателя"
assert_jq '.dns | [(.enable | tostring), .listen] | join(",")' "true,127.0.0.42:53" \
	"$(clash_cm_configure_dns "$C" true "127.0.0.42:53" false)"

it "configure_dns без адреса не заводит listen"
assert_jq '.dns | has("listen")' "false" "$(clash_cm_configure_dns "$C" true "" "")"

it "configure_dns заводит пустой nameserver"
assert_jq '.dns.nameserver | length' "0" "$(clash_cm_configure_dns "$C" true "" "")"

it "configure_dns не затирает уже настроенный fake-ip"
assert_jq '.dns["fake-ip-range"]' "198.18.0.0/15" \
	"$(clash_cm_configure_dns "$(clash_cm_enable_fakeip "$C" "")" true "" "")"

it "configure_dns не затирает уже добавленные серверы"
assert_jq '.dns.nameserver | join(",")' "8.8.8.8" \
	"$(clash_cm_configure_dns "$(clash_cm_add_nameserver "$C" udp 8.8.8.8 "" "")" true "" "")"

# --- clash_cm_add_nameserver ------------------------------------------------

it "add_nameserver для udp пишет адрес с портом без схемы"
assert_jq '.dns.nameserver[0]' "8.8.8.8:53" "$(clash_cm_add_nameserver "$C" udp 8.8.8.8 53 "")"

it "add_nameserver без типа считает сервер обычным udp"
assert_jq '.dns.nameserver[0]' "8.8.8.8" "$(clash_cm_add_nameserver "$C" "" 8.8.8.8 "" "")"

it "add_nameserver для tls добавляет схему"
assert_jq '.dns.nameserver[0]' "tls://1.1.1.1:853" "$(clash_cm_add_nameserver "$C" tls 1.1.1.1 853 "")"

it "add_nameserver для https добавляет схему и путь"
assert_jq '.dns.nameserver[0]' "https://1.1.1.1/dns-query" \
	"$(clash_cm_add_nameserver "$C" https 1.1.1.1 "" /dns-query)"

it "add_nameserver дописывает слеш к пути без него"
assert_jq '.dns.nameserver[0]' "https://dns.google:443/dns-query" \
	"$(clash_cm_add_nameserver "$C" https dns.google 443 dns-query)"

it "add_nameserver оборачивает IPv6-адрес в скобки"
assert_jq '.dns.nameserver[0]' "[2001:4860:4860::8888]:53" \
	"$(clash_cm_add_nameserver "$C" udp "2001:4860:4860::8888" 53 "")"

it "add_nameserver не дублирует скобки у готового IPv6"
assert_jq '.dns.nameserver[0]' "[2001:4860:4860::8888]:53" \
	"$(clash_cm_add_nameserver "$C" udp "[2001:4860:4860::8888]" 53 "")"

it "add_nameserver вторым вызовом дописывает сервер, а не затирает"
assert_jq '.dns.nameserver | join(" ")' "8.8.8.8 tls://1.1.1.1" \
	"$(clash_cm_add_nameserver "$(clash_cm_add_nameserver "$C" udp 8.8.8.8 "" "")" tls 1.1.1.1 "" "")"

# --- clash_cm_enable_fakeip -------------------------------------------------

it "enable_fakeip включает режим fake-ip"
assert_jq '.dns["enhanced-mode"]' "fake-ip" "$(clash_cm_enable_fakeip "$C" "198.18.0.0/15")"

it "enable_fakeip ставит указанный диапазон"
assert_jq '.dns["fake-ip-range"]' "10.0.0.0/8" "$(clash_cm_enable_fakeip "$C" "10.0.0.0/8")"

it "enable_fakeip без диапазона берёт значение по умолчанию"
assert_jq '.dns["fake-ip-range"]' "198.18.0.0/15" "$(clash_cm_enable_fakeip "$C" "")"

it "enable_fakeip заводит пустой список исключений"
assert_jq '.dns["fake-ip-filter"] | length' "0" "$(clash_cm_enable_fakeip "$C" "")"

it "enable_fakeip не сбрасывает уже добавленные исключения"
assert_jq '.dns["fake-ip-filter"] | join(",")' "+.lan" \
	"$(clash_cm_enable_fakeip "$(clash_cm_add_fakeip_filter "$C" "+.lan")" "")"

# --- clash_cm_add_fakeip_filter ---------------------------------------------

it "add_fakeip_filter добавляет шаблон"
assert_jq '.dns["fake-ip-filter"] | join(",")' "+.lan" "$(clash_cm_add_fakeip_filter "$C" "+.lan")"

it "add_fakeip_filter с пустым шаблоном ничего не меняет"
assert_jq '.dns' "null" "$(clash_cm_add_fakeip_filter "$C" "")"

it "add_fakeip_filter сохраняет порядок при повторном вызове"
assert_jq '.dns["fake-ip-filter"] | join(",")' "+.lan,router.local" \
	"$(clash_cm_add_fakeip_filter "$(clash_cm_add_fakeip_filter "$C" "+.lan")" "router.local")"

# --- clash_cm_add_nameserver_policy -----------------------------------------

it "add_nameserver_policy кладёт сервер строкой"
assert_jq '.dns["nameserver-policy"]["+.example.com"]' "tls://1.1.1.1" \
	"$(clash_cm_add_nameserver_policy "$C" "+.example.com" "tls://1.1.1.1")"

it "add_nameserver_policy принимает JSON-массив серверов"
assert_jq '.dns["nameserver-policy"]["+.lan"] | join(",")' "192.168.1.1,8.8.8.8" \
	"$(clash_cm_add_nameserver_policy "$C" "+.lan" '["192.168.1.1","8.8.8.8"]')"

it "add_nameserver_policy вторым доменом не затирает первый"
assert_jq '.dns["nameserver-policy"] | keys | join(",")' "+.example.com,+.lan" \
	"$(clash_cm_add_nameserver_policy "$(clash_cm_add_nameserver_policy "$C" "+.lan" "192.168.1.1")" "+.example.com" "8.8.8.8")"

it "add_nameserver_policy по тому же домену перезаписывает сервер"
assert_jq '.dns["nameserver-policy"]["+.lan"]' "8.8.8.8" \
	"$(clash_cm_add_nameserver_policy "$(clash_cm_add_nameserver_policy "$C" "+.lan" "192.168.1.1")" "+.lan" "8.8.8.8")"

# --- clash_cm_set_tproxy_port -----------------------------------------------

it "set_tproxy_port ставит порт числом, а не строкой"
assert_jq '[.["tproxy-port"] | tostring, type] | join(",")' "6969,number" \
	"$(clash_cm_set_tproxy_port "$C" 6969)"

it "set_tproxy_port с пустым портом убирает ключ"
assert_jq 'has("tproxy-port")' "false" "$(clash_cm_set_tproxy_port "$(clash_cm_set_tproxy_port "$C" 6969)" "")"

it "set_tproxy_port повторным вызовом меняет порт"
assert_jq '.["tproxy-port"]' "7894" "$(clash_cm_set_tproxy_port "$(clash_cm_set_tproxy_port "$C" 6969)" 7894)"

# --- clash_cm_set_mixed_port ------------------------------------------------

it "set_mixed_port ставит порт числом"
assert_jq '[.["mixed-port"] | tostring, type] | join(",")' "2080,number" \
	"$(clash_cm_set_mixed_port "$C" 2080)"

it "set_mixed_port с пустым портом убирает ключ"
assert_jq 'has("mixed-port")' "false" "$(clash_cm_set_mixed_port "$(clash_cm_set_mixed_port "$C" 2080)" "")"

it "set_mixed_port не трогает tproxy-port"
assert_jq '.["tproxy-port"]' "6969" "$(clash_cm_set_mixed_port "$(clash_cm_set_tproxy_port "$C" 6969)" 2080)"

# --- clash_cm_set_bind_address ----------------------------------------------

it "set_bind_address ставит адрес"
assert_jq '.["bind-address"]' "192.168.1.1" "$(clash_cm_set_bind_address "$C" 192.168.1.1)"

it "set_bind_address принимает звёздочку как есть"
assert_jq '.["bind-address"]' "*" "$(clash_cm_set_bind_address "$C" "*")"

it "set_bind_address с пустым адресом убирает ключ"
assert_jq 'has("bind-address")' "false" "$(clash_cm_set_bind_address "$(clash_cm_set_bind_address "$C" "*")" "")"

# --- clash_cm_add_vless_proxy -----------------------------------------------

it "add_vless_proxy кладёт прокси с портом числом"
assert_json_eq '{"name":"vless-out","type":"vless","server":"example.com","port":443,"uuid":"bf000d23"}' \
	"$(clash_cm_add_vless_proxy "$C" vless-out example.com 443 bf000d23 "" "" "" | "$JQ" -c '.proxies[0]')"

it "add_vless_proxy переносит flow, packet-encoding и udp"
assert_jq '.proxies[0] | [.flow, .["packet-encoding"], (.udp | tostring)] | join(",")' "xtls-rprx-vision,xudp,true" \
	"$(clash_cm_add_vless_proxy "$C" vless-out example.com 443 bf000d23 xtls-rprx-vision xudp true)"

it "add_vless_proxy без необязательных полей их не заводит"
assert_jq '.proxies[0] | [has("flow"), has("packet-encoding"), has("udp")] | join(",")' "false,false,false" \
	"$(clash_cm_add_vless_proxy "$C" vless-out example.com 443 bf000d23 "" "" "")"

it "add_vless_proxy вторым вызовом дописывает прокси, а не затирает"
assert_jq '[.proxies[].name] | join(",")' "first,second" \
	"$(clash_cm_add_vless_proxy "$(clash_cm_add_vless_proxy "$C" first a.com 443 uuid1 "" "" "")" second b.com 443 uuid2 "" "" "")"

# --- clash_cm_add_shadowsocks_proxy -----------------------------------------

it "add_shadowsocks_proxy пишет cipher вместо method"
assert_json_eq '{"name":"ss-out","type":"ss","server":"127.0.0.1","port":443,"cipher":"aes-128-gcm","password":"pass"}' \
	"$(clash_cm_add_shadowsocks_proxy "$C" ss-out 127.0.0.1 443 aes-128-gcm pass "" "" "" | "$JQ" -c '.proxies[0]')"

it "add_shadowsocks_proxy переносит плагин и его настройки объектом"
assert_jq '.proxies[0] | [.plugin, .["plugin-opts"].mode] | join(",")' "obfs,websocket" \
	"$(clash_cm_add_shadowsocks_proxy "$C" ss-out 127.0.0.1 443 aes-128-gcm pass true obfs '{"mode":"websocket"}')"

it "add_shadowsocks_proxy не портит пароль со спецсимволами"
assert_jq '.proxies[0].password' 'p@$s"w=+/ord' \
	"$(clash_cm_add_shadowsocks_proxy "$C" ss-out 127.0.0.1 443 aes-128-gcm 'p@$s"w=+/ord' "" "" "")"

it "пароль со спецсимволами переживает цепочку преобразований"
assert_jq '.proxies[0].password' 'p@$s"w=+/ord' \
	"$(clash_cm_add_rule "$(clash_cm_set_interface_for_proxy "$(clash_cm_add_shadowsocks_proxy "$C" ss-out 127.0.0.1 443 aes-128-gcm 'p@$s"w=+/ord' "" "" "")" ss-out awg0)" DOMAIN a.com main "")"

# --- clash_cm_add_trojan_proxy ----------------------------------------------

it "add_trojan_proxy кладёт прокси с sni"
assert_json_eq '{"name":"trojan-out","type":"trojan","server":"example.com","port":443,"password":"secret","sni":"example.com","udp":true}' \
	"$(clash_cm_add_trojan_proxy "$C" trojan-out example.com 443 secret example.com true | "$JQ" -c '.proxies[0]')"

it "add_trojan_proxy без sni и udp их не заводит"
assert_jq '.proxies[0] | [has("sni"), has("udp")] | join(",")' "false,false" \
	"$(clash_cm_add_trojan_proxy "$C" trojan-out example.com 443 secret "" "")"

# --- clash_cm_add_socks_proxy -----------------------------------------------

it "add_socks_proxy кладёт прокси типа socks5 с учёткой"
assert_json_eq '{"name":"socks-out","type":"socks5","server":"192.168.1.10","port":1080,"username":"user","password":"pass"}' \
	"$(clash_cm_add_socks_proxy "$C" socks-out 192.168.1.10 1080 user pass "" | "$JQ" -c '.proxies[0]')"

it "add_socks_proxy без учётки не заводит username и password"
assert_jq '.proxies[0] | [has("username"), has("password")] | join(",")' "false,false" \
	"$(clash_cm_add_socks_proxy "$C" socks-out 192.168.1.10 1080 "" "" "")"

# --- clash_cm_add_raw_proxy -------------------------------------------------

it "add_raw_proxy кладёт объект как есть и подставляет имя"
assert_json_eq '{"name":"raw-out","type":"ss","server":"127.0.0.1","port":443,"cipher":"aes-128-gcm","password":"pass"}' \
	"$(clash_cm_add_raw_proxy "$C" raw-out '{"type":"ss","server":"127.0.0.1","port":443,"cipher":"aes-128-gcm","password":"pass"}' | "$JQ" -c '.proxies[0]')"

it "add_raw_proxy с пустым именем оставляет имя из объекта"
assert_jq '.proxies[0].name' "own-name" \
	"$(clash_cm_add_raw_proxy "$C" "" '{"name":"own-name","type":"ss"}')"

it "add_raw_proxy сохраняет вложенные структуры"
assert_jq '.proxies[0]["ws-opts"].headers.Host' "example.com" \
	"$(clash_cm_add_raw_proxy "$C" raw-out '{"type":"vless","ws-opts":{"headers":{"Host":"example.com"}}}')"

# --- clash_cm_set_tls_for_proxy ---------------------------------------------

VLESS=$(clash_cm_add_vless_proxy "$C" vless-out example.com 443 bf000d23 "" "" "")
TROJAN=$(clash_cm_add_trojan_proxy "$C" trojan-out example.com 443 secret "" "")

it "set_tls_for_proxy включает tls и ставит servername"
assert_jq '.proxies[0] | [(.tls | tostring), .servername] | join(",")' "true,example.com" \
	"$(clash_cm_set_tls_for_proxy "$VLESS" vless-out example.com "" "" "" "" "")"

it "set_tls_for_proxy собирает reality-opts и отпечаток клиента"
assert_json_eq '{"public-key":"pbk123","short-id":"0123abcd"}' \
	"$(clash_cm_set_tls_for_proxy "$VLESS" vless-out example.com "" "" chrome pbk123 0123abcd | "$JQ" -c '.proxies[0]["reality-opts"]')"

it "set_tls_for_proxy разбирает alpn из JSON-массива"
assert_jq '.proxies[0].alpn | join(",")' "h2,http/1.1" \
	"$(clash_cm_set_tls_for_proxy "$VLESS" vless-out "" "" '["h2","http/1.1"]' "" "" "")"

it "set_tls_for_proxy принимает alpn=null как отсутствие значения"
assert_jq '.proxies[0] | has("alpn")' "false" \
	"$(clash_cm_set_tls_for_proxy "$VLESS" vless-out "" "" null "" "" "")"

it "set_tls_for_proxy ставит skip-cert-verify только при true"
assert_jq '.proxies[0] | has("skip-cert-verify")' "false" \
	"$(clash_cm_set_tls_for_proxy "$VLESS" vless-out example.com false "" "" "" "")"

it "set_tls_for_proxy у trojan пишет sni и не трогает флаг tls"
assert_jq '.proxies[0] | [.sni, (has("servername") | tostring), (has("tls") | tostring)] | join(",")' "sni.example.com,false,false" \
	"$(clash_cm_set_tls_for_proxy "$TROJAN" trojan-out sni.example.com "" "" "" "" "")"

it "set_tls_for_proxy не трогает прокси с другим именем"
assert_jq '.proxies[0] | has("tls")' "false" \
	"$(clash_cm_set_tls_for_proxy "$VLESS" other-name example.com "" "" "" "" "")"

# --- clash_cm_set_ws_transport ----------------------------------------------

it "set_ws_transport ставит network и путь"
assert_jq '.proxies[0] | [.network, .["ws-opts"].path] | join(",")' "ws,/path" \
	"$(clash_cm_set_ws_transport "$VLESS" vless-out /path "" "" "")"

it "set_ws_transport кладёт host в заголовки"
assert_jq '.proxies[0]["ws-opts"].headers.Host' "example.com" \
	"$(clash_cm_set_ws_transport "$VLESS" vless-out /path example.com "" "")"

it "set_ws_transport пишет max-early-data числом"
assert_jq '.proxies[0]["ws-opts"]["max-early-data"] | type' "number" \
	"$(clash_cm_set_ws_transport "$VLESS" vless-out /path "" 2048 Sec-WebSocket-Protocol)"

it "set_ws_transport без параметров всё равно переключает транспорт"
assert_jq '.proxies[0] | [.network, (.["ws-opts"] | length | tostring)] | join(",")' "ws,0" \
	"$(clash_cm_set_ws_transport "$VLESS" vless-out "" "" "" "")"

# --- clash_cm_set_grpc_transport --------------------------------------------

it "set_grpc_transport ставит network и имя сервиса"
assert_jq '.proxies[0] | [.network, .["grpc-opts"]["grpc-service-name"]] | join(",")' "grpc,TunService" \
	"$(clash_cm_set_grpc_transport "$VLESS" vless-out TunService)"

it "set_grpc_transport без имени сервиса оставляет grpc-opts пустым"
assert_jq '.proxies[0] | [.network, (.["grpc-opts"] | length | tostring)] | join(",")' "grpc,0" \
	"$(clash_cm_set_grpc_transport "$VLESS" vless-out "")"

# --- clash_cm_set_interface_for_proxy ---------------------------------------

it "set_interface_for_proxy ставит interface-name"
assert_jq '.proxies[0]["interface-name"]' "awg0" \
	"$(clash_cm_set_interface_for_proxy "$VLESS" vless-out awg0)"

it "set_interface_for_proxy с пустым интерфейсом ничего не добавляет"
assert_jq '.proxies[0] | has("interface-name")' "false" \
	"$(clash_cm_set_interface_for_proxy "$VLESS" vless-out "")"

it "set_interface_for_proxy не трогает прокси с другим именем"
assert_jq '.proxies[0] | has("interface-name")' "false" \
	"$(clash_cm_set_interface_for_proxy "$VLESS" other-name awg0)"

# --- clash_cm_add_select_group ----------------------------------------------

it "add_select_group кладёт группу с участниками"
assert_json_eq '{"name":"main","type":"select","proxies":["vless-out","DIRECT"]}' \
	"$(clash_cm_add_select_group "$C" main '["vless-out","DIRECT"]' | "$JQ" -c '.["proxy-groups"][0]')"

it "add_select_group с пустым списком даёт пустой массив участников"
assert_jq '.["proxy-groups"][0].proxies | length' "0" "$(clash_cm_add_select_group "$C" main "")"

it "add_select_group вторым вызовом дописывает группу, а не затирает"
assert_jq '[.["proxy-groups"][].name] | join(",")' "first,second" \
	"$(clash_cm_add_select_group "$(clash_cm_add_select_group "$C" first '["DIRECT"]')" second '["REJECT"]')"

# --- clash_cm_add_urltest_group ---------------------------------------------

it "add_urltest_group кладёт группу с проверкой задержки"
assert_json_eq '{"name":"auto","type":"url-test","proxies":["p1","p2"],"url":"http://cp.cloudflare.com/generate_204","interval":300,"tolerance":50,"lazy":true}' \
	"$(clash_cm_add_urltest_group "$C" auto '["p1","p2"]' "http://cp.cloudflare.com/generate_204" 300 50 true | "$JQ" -c '.["proxy-groups"][0]')"

it "add_urltest_group пишет interval и tolerance числами"
assert_jq '.["proxy-groups"][0] | [(.interval | type), (.tolerance | type)] | join(",")' "number,number" \
	"$(clash_cm_add_urltest_group "$C" auto '["p1"]' "" 300 50 "")"

it "add_urltest_group без необязательных полей их не заводит"
assert_jq '.["proxy-groups"][0] | [has("url"), has("interval"), has("tolerance"), has("lazy")] | join(",")' \
	"false,false,false,false" \
	"$(clash_cm_add_urltest_group "$C" auto '["p1"]' "" "" "" "")"

# --- clash_cm_add_rule ------------------------------------------------------

it "add_rule собирает строку тип-значение-цель"
assert_jq '.rules[0]' "DOMAIN-SUFFIX,example.com,main" \
	"$(clash_cm_add_rule "$C" DOMAIN-SUFFIX example.com main "")"

it "add_rule дописывает no-resolve"
assert_jq '.rules[0]' "IP-CIDR,1.1.1.1/32,main,no-resolve" \
	"$(clash_cm_add_rule "$C" IP-CIDR 1.1.1.1/32 main true)"

it "add_rule приводит тип к верхнему регистру"
assert_jq '.rules[0]' "DOMAIN-SUFFIX,example.com,main" \
	"$(clash_cm_add_rule "$C" domain-suffix example.com main "")"

it "add_rule без значения даёт правило из двух частей"
assert_jq '.rules[0]' "MATCH,DIRECT" "$(clash_cm_add_rule "$C" MATCH "" DIRECT "")"

it "add_rule не ломается на спецсимволах в значении"
assert_jq '.rules[0]' 'DOMAIN,a"b.example.com,main' \
	"$(clash_cm_add_rule "$C" DOMAIN 'a"b.example.com' main "")"

it "add_rule сохраняет порядок добавления"
assert_jq '.rules | join(" | ")' "DOMAIN,a.com,main | DOMAIN,b.com,main | DOMAIN,c.com,main" \
	"$(clash_cm_add_rule "$(clash_cm_add_rule "$(clash_cm_add_rule "$C" DOMAIN a.com main "")" DOMAIN b.com main "")" DOMAIN c.com main "")"

# --- clash_cm_add_ruleset_rule ----------------------------------------------

it "add_ruleset_rule собирает правило по набору"
assert_jq '.rules[0]' "RULE-SET,telegram,main" "$(clash_cm_add_ruleset_rule "$C" telegram main "")"

it "add_ruleset_rule дописывает no-resolve"
assert_jq '.rules[0]' "RULE-SET,telegram-ip,main,no-resolve" \
	"$(clash_cm_add_ruleset_rule "$C" telegram-ip main true)"

it "add_ruleset_rule сохраняет порядок наборов"
assert_jq '.rules | join(" | ")' "RULE-SET,telegram,main | RULE-SET,discord,DIRECT" \
	"$(clash_cm_add_ruleset_rule "$(clash_cm_add_ruleset_rule "$C" telegram main "")" discord DIRECT "")"

# --- clash_cm_add_reject_rule -----------------------------------------------

it "add_reject_rule ставит целью REJECT"
assert_jq '.rules[0]' "DOMAIN-SUFFIX,ads.example.com,REJECT" \
	"$(clash_cm_add_reject_rule "$C" DOMAIN-SUFFIX ads.example.com "")"

it "add_reject_rule дописывает no-resolve"
assert_jq '.rules[0]' "IP-CIDR,10.0.0.0/8,REJECT,no-resolve" \
	"$(clash_cm_add_reject_rule "$C" IP-CIDR 10.0.0.0/8 true)"

# --- clash_cm_add_match_rule ------------------------------------------------

it "add_match_rule даёт правило MATCH с целью"
assert_jq '.rules[0]' "MATCH,DIRECT" "$(clash_cm_add_match_rule "$C" DIRECT)"

it "add_match_rule встаёт последним, после уже добавленных правил"
assert_jq '.rules | join(" | ")' "RULE-SET,telegram,main | MATCH,DIRECT" \
	"$(clash_cm_add_match_rule "$(clash_cm_add_ruleset_rule "$C" telegram main "")" DIRECT)"

# --- clash_cm_add_http_rule_provider ----------------------------------------

it "add_http_rule_provider объявляет набор из сети"
assert_json_eq '{"type":"http","behavior":"ipcidr","format":"text","url":"https://example.com/telegram.lst","path":"./rules/telegram.lst","interval":86400}' \
	"$(clash_cm_add_http_rule_provider "$C" telegram ipcidr text "https://example.com/telegram.lst" ./rules/telegram.lst 86400 | "$JQ" -c '.["rule-providers"].telegram')"

it "add_http_rule_provider без behavior берёт classical"
assert_jq '.["rule-providers"].telegram.behavior' "classical" \
	"$(clash_cm_add_http_rule_provider "$C" telegram "" "" "https://example.com/telegram.lst" "" "")"

it "add_http_rule_provider без пути и интервала не заводит эти ключи"
assert_jq '.["rule-providers"].telegram | [has("path"), has("interval"), has("format")] | join(",")' "false,false,false" \
	"$(clash_cm_add_http_rule_provider "$C" telegram domain "" "https://example.com/telegram.lst" "" "")"

it "add_http_rule_provider вторым набором не затирает первый"
assert_jq '.["rule-providers"] | keys | join(",")' "discord,telegram" \
	"$(clash_cm_add_http_rule_provider "$(clash_cm_add_http_rule_provider "$C" telegram domain text "https://example.com/t.lst" "" "")" discord domain text "https://example.com/d.lst" "" "")"

# --- clash_cm_add_file_rule_provider ----------------------------------------

it "add_file_rule_provider объявляет набор из файла"
assert_json_eq '{"type":"file","behavior":"domain","format":"text","path":"/tmp/podkop/local.lst"}' \
	"$(clash_cm_add_file_rule_provider "$C" local-domains domain text /tmp/podkop/local.lst | "$JQ" -c '.["rule-providers"]["local-domains"]')"

it "add_file_rule_provider без формата не заводит ключ"
assert_jq '.["rule-providers"]["local-domains"] | has("format")' "false" \
	"$(clash_cm_add_file_rule_provider "$C" local-domains domain "" /tmp/podkop/local.lst)"

it "add_file_rule_provider уживается с набором из сети"
assert_jq '[.["rule-providers"] | to_entries[] | .value.type] | sort | join(",")' "file,http" \
	"$(clash_cm_add_file_rule_provider "$(clash_cm_add_http_rule_provider "$C" telegram domain text "https://example.com/t.lst" "" "")" local domain text /tmp/local.lst)"

# --- clash_cm_save_config_to_file -------------------------------------------

clash_cm_save_config_to_file "$(clash_cm_add_match_rule "$C" DIRECT)" "$TMP.json"

it "save_config_to_file пишет валидный JSON"
assert_valid_json "$(cat "$TMP.json")"

it "save_config_to_file сохраняет содержимое без потерь"
assert_jq '.rules | join(",")' "MATCH,DIRECT" "$(cat "$TMP.json")"

clash_cm_save_config_to_file "$(clash_cm_add_match_rule "$C" REJECT)" "$TMP.json"

it "save_config_to_file повторным вызовом перезаписывает файл целиком"
assert_jq '.rules | join(",")' "MATCH,REJECT" "$(cat "$TMP.json")"

rm -f "$TMP.json"

# --- сборка целиком ---------------------------------------------------------
# Порядок правил в Clash значим: выигрывает первое совпавшее. Проверяем, что
# цепочка вызовов складывает их именно в том порядке, в каком их добавляли.

FULL=$(clash_cm_configure_route "$C" rule)
FULL=$(clash_cm_add_reject_rule "$FULL" DOMAIN-SUFFIX ads.example.com "")
FULL=$(clash_cm_add_rule "$FULL" DOMAIN-SUFFIX example.com main "")
FULL=$(clash_cm_add_ruleset_rule "$FULL" telegram main "")
FULL=$(clash_cm_add_rule "$FULL" IP-CIDR 10.0.0.0/8 DIRECT true)
FULL=$(clash_cm_add_match_rule "$FULL" DIRECT)

it "цепочка вызовов складывает правила в порядке добавления"
assert_jq '.rules | join(" | ")' \
	"DOMAIN-SUFFIX,ads.example.com,REJECT | DOMAIN-SUFFIX,example.com,main | RULE-SET,telegram,main | IP-CIDR,10.0.0.0/8,DIRECT,no-resolve | MATCH,DIRECT" \
	"$FULL"

it "MATCH оказывается последним правилом"
assert_jq '.rules | last' "MATCH,DIRECT" "$FULL"

# Полный конфиг из всех разделов должен остаться валидным JSON.
FULL=$(clash_cm_configure_log "$FULL" false info)
FULL=$(clash_cm_configure_dns "$FULL" true "127.0.0.42:53" false)
FULL=$(clash_cm_enable_fakeip "$FULL" "")
FULL=$(clash_cm_add_nameserver "$FULL" tls 1.1.1.1 853 "")
FULL=$(clash_cm_set_tproxy_port "$FULL" 6969)
FULL=$(clash_cm_set_bind_address "$FULL" "*")
FULL=$(clash_cm_add_vless_proxy "$FULL" vless-out example.com 443 bf000d23 xtls-rprx-vision "" true)
FULL=$(clash_cm_set_tls_for_proxy "$FULL" vless-out example.com "" "" chrome pbk123 0123abcd)
FULL=$(clash_cm_add_select_group "$FULL" main '["vless-out","DIRECT"]')
FULL=$(clash_cm_add_http_rule_provider "$FULL" telegram ipcidr text "https://example.com/t.lst" ./rules/t.lst 86400)
FULL=$(clash_cm_configure_clash_api "$FULL" "0.0.0.0:9090" "" "s3cret")
FULL=$(clash_cm_configure_profile "$FULL" true true)

it "конфиг из всех разделов остаётся валидным JSON"
assert_valid_json "$FULL"

it "в собранном конфиге на месте все разделы схемы Clash"
assert_jq 'keys | join(",")' \
	"bind-address,dns,external-controller,log-level,mode,profile,proxies,proxy-groups,rule-providers,rules,secret,tproxy-port" \
	"$(printf '%s' "$FULL" | "$JQ" -S .)"

# ============================ CORS для Clash API =============================
#
# Выяснено на живом clash-rs 0.10.8: он отказывается поднимать API на
# нелокальном адресе, пока не заданы И секрет, И CORS. Причём ругается по
# очереди - сначала на секрет, потом на CORS, - так что второе требование
# обнаруживается только после того, как закрыто первое. У sing-box такой
# настройки нет вовсе, поэтому у апстрима вопрос не возникал.

it "источники попадают в конфиг списком"
assert_jq '.["cors-allow-origins"] | join(",")' "*" 	"$(clash_cm_set_cors_origins "$(clash_empty_config)" "*")"

it "несколько источников разбираются по пробелу"
assert_jq '.["cors-allow-origins"] | join(",")' "http://a,http://b" 	"$(clash_cm_set_cors_origins "$(clash_empty_config)" "http://a http://b")"

it "пустое значение убирает ключ, а не пишет пустой список"
assert_jq 'has("cors-allow-origins")' "false" 	"$(clash_cm_set_cors_origins "$(clash_empty_config)" "")"

it "лишние пробелы не создают пустых элементов"
assert_jq '.["cors-allow-origins"] | length' "2" 	"$(clash_cm_set_cors_origins "$(clash_empty_config)" "  http://a   http://b  ")"

it "повторный вызов заменяет список, а не дописывает"
assert_jq '.["cors-allow-origins"] | join(",")' "http://b" 	"$(clash_cm_set_cors_origins "$(clash_cm_set_cors_origins "$(clash_empty_config)" "http://a")" "http://b")"

finish
