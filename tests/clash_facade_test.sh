#!/bin/sh
# Тесты фасада clash-rs.
#
# Главное, что здесь проверяется, - разбор ссылок на прокси. Ссылки взяты из
# String-example.md, то есть это ровно те строки, которые подкоп получает от
# людей, а не выдуманные под удобный разбор.
#
# Менеджер конфига в тестах не участвует: он пишется параллельно, и его правки
# не должны ронять эти тесты. Всё, что фасаду от менеджера нужно, - положить
# готовый объект в proxies[] и дописать строку в rules[], поэтому на это место
# поставлены заглушки в три строки, а ожидаемый JSON собран руками.
#
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

# Git Bash переписывает аргументы, похожие на пути Unix: путь /wspath уехал бы
# в jq.exe как C:/Program Files/Git/wspath. На роутере такого нет, в тестах
# конверсию выключаем.
MSYS2_ARG_CONV_EXCL='*'
MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL MSYS_NO_PATHCONV

PODKOP_LIB=$(cd "$(dirname "$0")/../podkop/files/usr/lib" && pwd)
export PODKOP_LIB

# Модуль зовёт jq по имени, как и на роутере. В тестах подменяем его
# портативным бинарником из JQ: функция перекрывает поиск по PATH.
jq() { "$JQ" "$@"; }

# logger на машине разработчика нет, а фасад пишет туда причины отказов
log() { :; }

# --- заглушки менеджера -----------------------------------------------------
# Сигнатуры настоящие, поведение упрощено до "запиши, что тебе передали":
# проверяем решения фасада, а не работу менеджера. Определены до подключения
# фасада - он подтягивает менеджер, только если тех же функций ещё нет.

clash_cm_add_raw_proxy() {
	printf '%s' "$1" | "$JQ" -c --arg name "$2" --argjson proxy "$3" '.proxies += [$proxy + {name: $name}]'
}

clash_cm_set_interface_for_proxy() {
	printf '%s' "$1" | "$JQ" -c --arg name "$2" --arg interface "$3" \
		'.proxies |= map(if .name == $name then . + {"interface-name": $interface} else . end)'
}

clash_cm_add_rule() {
	printf '%s' "$1" | "$JQ" -c --arg type "$2" --arg value "$3" --arg target "$4" \
		'.rules += [[$type, $value, $target] | join(",")]'
}

clash_cm_add_reject_rule() {
	clash_cm_add_rule "$1" "$2" "$3" "REJECT"
}

# части адреса склеивать - дело менеджера, поэтому заглушка просто показывает,
# что фасад ему передал: тип|адрес|порт|путь
clash_cm_add_nameserver() {
	printf '%s' "$1" | "$JQ" -c --arg type "$2" --arg address "$3" --arg port "$4" --arg path "$5" \
		'.dns.nameserver += [[$type, $address, $port, $path] | join("|")]'
}

clash_cm_set_mixed_port() {
	printf '%s' "$1" | "$JQ" -c --arg port "$2" '. + {"mixed-port": ($port | tonumber)}'
}

. "$PODKOP_LIB/clash_config_facade.sh"

# --- служебное --------------------------------------------------------------

# Разобрать ссылку с фиксированным именем: имя проверяется отдельно, в
# остальных тестах оно только мешало бы.
parse() { clash_cf_parse_proxy_url "$1" "PROXY"; }

# Код возврата на битой ссылке
rc_of() {
	clash_cf_parse_proxy_url "$1" "PROXY" >/dev/null 2>&1
	printf '%s' "$?"
}

# Текст, который фасад пишет в stderr
err_of() { clash_cf_parse_proxy_url "$1" "PROXY" 2>&1 >/dev/null; }

# Что фасад отдал в stdout, когда разбор не удался
out_of() { clash_cf_parse_proxy_url "$1" "PROXY" 2>/dev/null; }

# ============================ VLESS: reality + vision =======================
# Основной боевой случай. Ссылка - vless-tcp-reality из String-example.md, к ней
# дописаны flow и packetEncoding: в примерах их нет, а в реальных подписках
# xtls-rprx-vision встречается чаще всего.

VLESS_VISION='vless://e95163dc-905e-480a-afe5-20b146288679@127.0.0.1:16399?type=tcp&encryption=none&security=reality&flow=xtls-rprx-vision&packetEncoding=xudp&pbk=tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM&fp=chrome&sni=google.com&sid=f6&spx=%2F#vless-tcp-reality'

it "vless + reality + xtls-rprx-vision разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "vless",
	"server": "127.0.0.1",
	"port": 16399,
	"uuid": "e95163dc-905e-480a-afe5-20b146288679",
	"udp": true,
	"flow": "xtls-rprx-vision",
	"packet-encoding": "xudp",
	"tls": true,
	"servername": "google.com",
	"client-fingerprint": "chrome",
	"reality-opts": {
		"public-key": "tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM",
		"short-id": "f6"
	}
}' "$(parse "$VLESS_VISION")"

it "порт стал числом, а не строкой"
assert_jq '.port | type' "number" "$(parse "$VLESS_VISION")"

it "spx из ссылки в объект не просачивается"
assert_not_contains "spx" "$(parse "$VLESS_VISION")"

# ============================ VLESS: без защиты и транспорта ================

VLESS_TCP_NONE='vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?type=tcp&encryption=none&security=none#vless-tcp-none'

it "vless без необязательных параметров: только обязательные поля"
assert_json_eq '{
	"name": "PROXY",
	"type": "vless",
	"server": "127.0.0.1",
	"port": 34520,
	"uuid": "94792286-7bbe-4f33-8b36-18d1bbf70723",
	"udp": true
}' "$(parse "$VLESS_TCP_NONE")"

it "security=none не включает tls"
assert_jq 'has("tls")' "false" "$(parse "$VLESS_TCP_NONE")"

it "type=tcp не добавляет network"
assert_jq 'has("network")' "false" "$(parse "$VLESS_TCP_NONE")"

# ============================ VLESS: reality без flow =======================

VLESS_REALITY='vless://e95163dc-905e-480a-afe5-20b146288679@127.0.0.1:16399?type=tcp&encryption=none&security=reality&pbk=tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM&fp=chrome&sni=google.com&sid=f6&spx=%2F#vless-tcp-reality'

it "pbk уехал в reality-opts.public-key"
assert_jq '.["reality-opts"]["public-key"]' "tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM" "$(parse "$VLESS_REALITY")"

it "sid уехал в reality-opts.short-id"
assert_jq '.["reality-opts"]["short-id"]' "f6" "$(parse "$VLESS_REALITY")"

it "fp уехал в client-fingerprint"
assert_jq '.["client-fingerprint"]' "chrome" "$(parse "$VLESS_REALITY")"

it "sni у vless называется servername"
assert_jq '.servername' "google.com" "$(parse "$VLESS_REALITY")"

it "reality всё равно поднимает tls"
assert_jq '.tls' "true" "$(parse "$VLESS_REALITY")"

it "flow не выдумывается, если его нет в ссылке"
assert_jq 'has("flow")' "false" "$(parse "$VLESS_REALITY")"

# ============================ VLESS: tls ====================================

VLESS_TLS='vless://2e9e8288-060e-4da2-8b9f-a1c81826feb7@127.0.0.1:19316?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-tcp-tls'
VLESS_TLS_INSECURE='vless://0235c833-dc29-4202-8a7b-1bbba5b516a2@127.0.0.1:22993?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#vless-tcp-tls-insecure'
VLESS_TLS_ECH='vless://17776137-e747-4268-a84d-99fd798accac@127.0.0.1:48076?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com&ech=AFP%2BDQBPAAAgACDJXiKG5eoCHfd1MbMxgccxgrbGisBPPe3bz1KVIETUXQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAAAAAA%3D%3D#vless-tcp-tls-ech'

it "alpn из percent-encoding разбирается в массив"
assert_jq '.alpn | join("|")' "h2|http/1.1" "$(parse "$VLESS_TLS")"

it "без allowInsecure сертификат проверяется"
assert_jq 'has("skip-cert-verify")' "false" "$(parse "$VLESS_TLS")"

it "allowInsecure=1 даёт skip-cert-verify"
assert_jq '.["skip-cert-verify"]' "true" "$(parse "$VLESS_TLS_INSECURE")"

it "ссылка с ech разбирается, сам ech отбрасывается"
assert_jq '.tls' "true" "$(parse "$VLESS_TLS_ECH")"

it "ech в объект не попадает: в схеме clash-rs его нет"
assert_not_contains "ech" "$(parse "$VLESS_TLS_ECH")"

# ============================ VLESS: WebSocket ==============================

VLESS_WS_NONE='vless://d86daef7-565b-4ecd-a9ee-bac847ad38e6@127.0.0.1:12928?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=none#vless-websocket-none'
VLESS_WS_TLS='vless://fe0f0941-09a9-4e46-bc69-e00190d7bb9c@127.0.0.1:10156?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-websocket-tls'

it "vless + ws + tls разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "vless",
	"server": "127.0.0.1",
	"port": 10156,
	"uuid": "fe0f0941-09a9-4e46-bc69-e00190d7bb9c",
	"udp": true,
	"tls": true,
	"servername": "google.com",
	"alpn": ["h2", "http/1.1"],
	"client-fingerprint": "chrome",
	"network": "ws",
	"ws-opts": {
		"path": "/wspath",
		"headers": {"Host": "google.com"}
	}
}' "$(parse "$VLESS_WS_TLS")"

it "path из percent-encoding раскодирован"
assert_jq '.["ws-opts"].path' "/wspath" "$(parse "$VLESS_WS_NONE")"

it "host уехал в заголовок Host"
assert_jq '.["ws-opts"].headers.Host' "google.com" "$(parse "$VLESS_WS_NONE")"

it "ws без tls остаётся без tls"
assert_jq 'has("tls")' "false" "$(parse "$VLESS_WS_NONE")"

# ============================ VLESS: gRPC ===================================

VLESS_GRPC_NONE='vless://974b39e3-f7bf-42b9-933c-16699c635e77@127.0.0.1:15633?type=grpc&encryption=none&serviceName=TunService&authority=&security=none#vless-gRPC-none'
VLESS_GRPC_REALITY='vless://651e7eca-5152-46f1-baf2-d502e0af7b27@127.0.0.1:28535?type=grpc&encryption=none&serviceName=TunService&authority=authority&security=reality&pbk=nhZ7NiKfcqESa5ZeBFfsq9o18W-OWOAHLln9UmuVXSk&fp=chrome&sni=google.com&sid=11cbaeaa&spx=%2F#vless-gRPC-reality'
VLESS_GRPC_EMPTY_SID='vless://221ff905-b783-41a0-a6a6-8089eaf3b34b@abc.def.xyz:443?security=reality&type=grpc&headerType=&authority=abc.def.xyz&serviceName=name&mode=gun&sni=abc.def.xyz&fp=chrome&pbk=C3nhDJw02ZU_rjx4GbC54Sp79-ysF5lWIQVWdY4FOnE&sid=#vless-gRPC-reality-mode'

it "serviceName уехал в grpc-opts.grpc-service-name"
assert_jq '.["grpc-opts"]["grpc-service-name"]' "TunService" "$(parse "$VLESS_GRPC_NONE")"

it "network=grpc выставлен"
assert_jq '.network' "grpc" "$(parse "$VLESS_GRPC_NONE")"

it "grpc и reality уживаются в одном объекте"
assert_jq '[.network, .["reality-opts"]["short-id"]] | join(",")' "grpc,11cbaeaa" "$(parse "$VLESS_GRPC_REALITY")"

it "пустой sid не создаёт пустой short-id"
assert_jq '.["reality-opts"] | has("short-id")' "false" "$(parse "$VLESS_GRPC_EMPTY_SID")"

it "но сам ключ reality на месте"
assert_jq '.["reality-opts"]["public-key"]' "C3nhDJw02ZU_rjx4GbC54Sp79-ysF5lWIQVWdY4FOnE" "$(parse "$VLESS_GRPC_EMPTY_SID")"

# ============================ VLESS: чего clash-rs не умеет =================

VLESS_KCP='vless://72e201d7-7841-4a32-b266-4aa3eb776d51@127.0.0.1:17270?type=kcp&encryption=none&headerType=none&seed=AirziWi4ng&security=none#vless-mKCP'
VLESS_HTTPUPGRADE='vless://2b98f144-847f-42f7-8798-e1a32d27bdc7@127.0.0.1:47154?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=none#vless-httpupgrade-none'
VLESS_XHTTP='vless://c2841505-ec32-4b8d-b6dd-3e19d648c321@127.0.0.1:45507?type=xhttp&encryption=none&path=%2Fxhttppath&host=xhttp&mode=auto&security=none#vless-xhttp'

it "mKCP отвергается: транспорта kcp в clash-rs нет"
assert_eq "1" "$(rc_of "$VLESS_KCP")"

it "и объясняет, что именно не поддержано"
assert_contains "kcp" "$(err_of "$VLESS_KCP")"

it "httpupgrade отвергается"
assert_eq "1" "$(rc_of "$VLESS_HTTPUPGRADE")"

it "xhttp отвергается"
assert_eq "1" "$(rc_of "$VLESS_XHTTP")"

it "отвергнутая ссылка не оставляет после себя огрызок объекта"
assert_eq "" "$(out_of "$VLESS_XHTTP")"

# ============================ Shadowsocks ===================================

SS_BASE64='ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206ZG1DbHkvWmgxNVd3OStzK0dGWGlGVElrcHc3Yy9xQ0lTYUJyYWk3V2hoWT0@127.0.0.1:25144?type=tcp#shadowsocks-no-client'
SS_BASE64_TWO_KEYS='ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206S3FiWXZiNkhwb1RmTUt0N2VGcUZQSmJNNXBXaHlFU0ZKTXY2dEp1Ym1Fdz06dzRNMEx5RU9OTGQ5SWlkSGc0endTbzN2R3h4NS9aQ3hId0FpaWlxck5hcz0@127.0.0.1:26627?type=tcp#shadowsocks-client'
SS_PLAIN='ss://2022-blake3-aes-256-gcm:dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=@127.0.0.1:27214?type=tcp#shadowsocks-plain-user'
SS_LEGACY='ss://YWVzLTI1Ni1nY206c2VjcmV0cGFzcw@example.com:8388#ss-legacy'

it "ss с base64-userinfo разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "ss",
	"server": "127.0.0.1",
	"port": 25144,
	"cipher": "2022-blake3-aes-256-gcm",
	"password": "dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=",
	"udp": true
}' "$(parse "$SS_BASE64")"

it "method из ссылки в Clash называется cipher"
assert_jq '.cipher' "2022-blake3-aes-256-gcm" "$(parse "$SS_BASE64")"

it "плюс в пароле остаётся плюсом, а не превращается в пробел"
assert_jq '.password' "dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=" "$(parse "$SS_PLAIN")"

it "открытый method:password разбирается так же, как base64"
assert_jq '.cipher' "2022-blake3-aes-256-gcm" "$(parse "$SS_PLAIN")"

it "два ключа шифра 2022 целиком уходят в пароль"
assert_jq '.password' "KqbYvb6HpoTfMKt7eFqFPJbM5pWhyESFJMv6tJubmEw=:w4M0LyEONLd9IidHg4zwSo3vGxx5/ZCxHwAiiiqrNas=" \
	"$(parse "$SS_BASE64_TWO_KEYS")"

it "base64 без выравнивания '=' тоже разбирается"
assert_jq '[.cipher, .password] | join(" ")' "aes-256-gcm secretpass" "$(parse "$SS_LEGACY")"

it "type=tcp у ss не превращается в network"
assert_jq 'has("network")' "false" "$(parse "$SS_BASE64")"

it "udp_over_tcp выключен - поля нет"
assert_jq 'has("udp-over-tcp")' "false" "$(parse "$SS_BASE64")"

it "udp_over_tcp включён - поле появилось"
assert_jq '.["udp-over-tcp"]' "true" "$(clash_cf_parse_proxy_url "$SS_BASE64" "PROXY" "1")"

it "userinfo, который не base64 и не method:password, отвергается"
assert_eq "1" "$(rc_of 'ss://not-a-valid-userinfo@127.0.0.1:8388')"

it "и в тексте ошибки видно, чего ждали"
assert_contains "method:password" "$(err_of 'ss://not-a-valid-userinfo@127.0.0.1:8388')"

# ============================ Trojan ========================================

TROJAN_NONE='trojan://04agAQapcl@127.0.0.1:33641?type=tcp&security=none#trojan-tcp-none'
TROJAN_TLS='trojan://EJjpAj02lg@127.0.0.1:11381?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-tcp-tls'
TROJAN_TLS_INSECURE='trojan://ZP2Ik5sxN3@127.0.0.1:16247?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-tcp-tls-insecure'
TROJAN_REALITY='trojan://cME3ZlUrYF@127.0.0.1:43772?type=tcp&security=reality&pbk=DckTwU6p6pTX9QxFXOi6vH4Vzt_RCE1vMCnj2c6hvjw&fp=chrome&sni=google.com&sid=221a80cf94&spx=%2F#trojan-tcp-reality'
TROJAN_WS='trojan://G3cE9phv1g@127.0.0.1:57370?type=ws&path=%2Fwspath&host=google.com&security=none#trojan-websocket-none'
TROJAN_GRPC='trojan://WMR7qkKhsV@127.0.0.1:27897?type=grpc&serviceName=TunService&authority=authority&security=none#trojan-gRPC-none'
TROJAN_XHTTP='trojan://VEetltxLtw@127.0.0.1:59072?type=xhttp&path=%2Fxhttppath&host=google.com&mode=auto&security=none#trojan-xhttp'

it "trojan разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "trojan",
	"server": "127.0.0.1",
	"port": 11381,
	"password": "EJjpAj02lg",
	"udp": true,
	"sni": "google.com",
	"alpn": ["h2", "http/1.1"],
	"client-fingerprint": "chrome"
}' "$(parse "$TROJAN_TLS")"

it "пароль trojan берётся из userinfo"
assert_jq '.password' "04agAQapcl" "$(parse "$TROJAN_NONE")"

it "sni у trojan так и называется sni, а не servername"
assert_jq 'has("servername")' "false" "$(parse "$TROJAN_TLS")"

it "trojan не получает поле tls: у него TLS и так всегда"
assert_jq 'has("tls")' "false" "$(parse "$TROJAN_TLS")"

it "allowInsecure у trojan работает так же"
assert_jq '.["skip-cert-verify"]' "true" "$(parse "$TROJAN_TLS_INSECURE")"

it "trojan + reality"
assert_jq '.["reality-opts"]["short-id"]' "221a80cf94" "$(parse "$TROJAN_REALITY")"

it "trojan + ws: путь и Host на месте"
assert_jq '[.network, .["ws-opts"].path, .["ws-opts"].headers.Host] | join(" ")' "ws /wspath google.com" \
	"$(parse "$TROJAN_WS")"

it "trojan + grpc"
assert_jq '.["grpc-opts"]["grpc-service-name"]' "TunService" "$(parse "$TROJAN_GRPC")"

it "trojan + xhttp отвергается"
assert_eq "1" "$(rc_of "$TROJAN_XHTTP")"

# ============================ SOCKS =========================================

SOCKS5_PLAIN='socks5://127.0.0.1:1080'
SOCKS5_AUTH='socks5://username:password@127.0.0.1:1080'
SOCKS4='socks4://127.0.0.1:1080'
SOCKS4A='socks4a://127.0.0.1:1080'

it "socks без логина разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "socks5",
	"server": "127.0.0.1",
	"port": 1080,
	"udp": true
}' "$(parse "$SOCKS5_PLAIN")"

it "socks с логином разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "socks5",
	"server": "127.0.0.1",
	"port": 1080,
	"username": "username",
	"password": "password",
	"udp": true
}' "$(parse "$SOCKS5_AUTH")"

it "без userinfo пустой логин не выдумывается"
assert_jq 'has("username")' "false" "$(parse "$SOCKS5_PLAIN")"

it "socks4 отвергается: clash-rs умеет только socks5"
assert_eq "1" "$(rc_of "$SOCKS4")"

it "socks4a тоже"
assert_eq "1" "$(rc_of "$SOCKS4A")"

it "и в ошибке сказано, чем socks4 не угодил"
assert_contains "socks5" "$(err_of "$SOCKS4")"

it "логин с percent-encoding раскодируется"
assert_jq '[.username, .password] | join(" ")' "поль зователь па:роль" \
	"$(parse 'socks5://%D0%BF%D0%BE%D0%BB%D1%8C%20%D0%B7%D0%BE%D0%B2%D0%B0%D1%82%D0%B5%D0%BB%D1%8C:%D0%BF%D0%B0%3A%D1%80%D0%BE%D0%BB%D1%8C@127.0.0.1:1080')"

# ============================ Hysteria2 =====================================

HY2='hysteria2://password@example.com:443/#hysteria2-password'
HY2_INSECURE='hysteria2://password@example.com:443/?insecure=1#hysteria2-password-insecure'
HY2_SNI='hysteria2://password@example.com:443/?sni=example.com#hysteria2-password-sni'
HY2_OBFS='hysteria2://password@example.com:443/?obfs=salamander&obfs-password=obfspassword#hysteria2-obfs'
HY2_ALL='hysteria2://mypassword@example.com:8443/?sni=example.com&obfs=salamander&obfs-password=obfspass&insecure=1#hysteria2-all-params'
HY2_SHORT='hy2://password@example.com:443/?sni=example.com#hysteria2-password-sni'

it "hysteria2 со всеми параметрами разбирается целиком"
assert_json_eq '{
	"name": "PROXY",
	"type": "hysteria2",
	"server": "example.com",
	"port": 8443,
	"password": "mypassword",
	"sni": "example.com",
	"obfs": "salamander",
	"obfs-password": "obfspass",
	"skip-cert-verify": true
}' "$(parse "$HY2_ALL")"

it "hysteria2 без параметров: слэш и якорь не мешают"
assert_json_eq '{
	"name": "PROXY",
	"type": "hysteria2",
	"server": "example.com",
	"port": 443,
	"password": "password"
}' "$(parse "$HY2")"

it "insecure=1 (без allow) тоже понимается"
assert_jq '.["skip-cert-verify"]' "true" "$(parse "$HY2_INSECURE")"

it "sni у hysteria2 доезжает"
assert_jq '.sni' "example.com" "$(parse "$HY2_SNI")"

it "обфускация разбирается парой полей"
assert_jq '[.obfs, .["obfs-password"]] | join(" ")' "salamander obfspassword" "$(parse "$HY2_OBFS")"

it "hy2:// - тот же hysteria2"
assert_jq '.type' "hysteria2" "$(parse "$HY2_SHORT")"

it "hysteria2 не получает client-fingerprint: uTLS там нечему подделывать"
assert_jq 'has("client-fingerprint")' "false" \
	"$(parse 'hysteria2://password@example.com:443/?fp=chrome&sni=example.com#hy2-fp')"

it "upmbps и downmbps становятся строками с единицей измерения"
assert_jq '[.up, .down] | join(" / ")' "50 Mbps / 200 Mbps" \
	"$(parse 'hysteria2://password@example.com:443/?upmbps=50&downmbps=200#hy2-speed')"

it "перечисление портов уезжает в ports, а в port остаётся первый"
assert_jq '[.port, .ports] | join(" ")' "443 443,8443-9000" \
	"$(parse 'hysteria2://password@example.com:443,8443-9000/#hy2-hopping')"

# ============================ имя прокси ====================================

it "имя берётся из якоря, если явного имени нет"
assert_jq '.name' "vless-tcp-reality" "$(clash_cf_parse_proxy_url "$VLESS_REALITY" "")"

it "якорь с percent-encoding раскодируется"
assert_jq '.name' "Мой сервер" \
	"$(clash_cf_parse_proxy_url 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?security=none#%D0%9C%D0%BE%D0%B9%20%D1%81%D0%B5%D1%80%D0%B2%D0%B5%D1%80' '')"

it "явное имя важнее якоря"
assert_jq '.name' "PROXY" "$(parse "$VLESS_REALITY")"

it "без имени и без якоря имя собирается из схемы"
assert_jq '.name' "vless-out" \
	"$(clash_cf_parse_proxy_url 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?security=none' '')"

it "параметры из якоря не притворяются параметрами ссылки"
assert_jq 'has("network")' "false" \
	"$(clash_cf_parse_proxy_url 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?security=none#name?type=ws' '')"

it "пробелы вокруг ссылки не мешают"
assert_jq '.server' "127.0.0.1" "$(parse "  $VLESS_TCP_NONE  ")"

# ============================ битые ссылки ==================================

it "неизвестная схема отвергается"
assert_eq "1" "$(rc_of 'vmess://eyJhZGQiOiIxLjIuMy40In0=')"

it "и в ошибке названа сама схема"
assert_contains "vmess" "$(err_of 'vmess://eyJhZGQiOiIxLjIuMy40In0=')"

it "неизвестная схема не даёт молча пустой объект"
assert_eq "" "$(out_of 'vmess://eyJhZGQiOiIxLjIuMy40In0=')"

it "строка без схемы отвергается"
assert_eq "1" "$(rc_of 'vless.example.com:443?type=tcp')"

it "и подсказывает, чего не хватает"
assert_contains "://" "$(err_of 'vless.example.com:443?type=tcp')"

it "пустая ссылка отвергается"
assert_eq "1" "$(rc_of '')"

it "ссылка без порта отвергается"
assert_eq "1" "$(rc_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com?type=tcp&security=none')"

it "и в ошибке сказано про порт"
assert_contains "порт" "$(err_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com?type=tcp&security=none')"

it "буквы вместо порта отвергаются"
assert_eq "1" "$(rc_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:порт?security=none')"

it "порт за пределами диапазона отвергается"
assert_eq "1" "$(rc_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:70000?security=none')"

it "vless без uuid отвергается"
assert_eq "1" "$(rc_of 'vless://@example.com:443?type=tcp&security=none')"

it "trojan без пароля отвергается"
assert_eq "1" "$(rc_of 'trojan://@example.com:443?type=tcp&security=none')"

it "незнакомый security отвергается"
assert_eq "1" "$(rc_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?security=xtls')"

it "security=reality без pbk отвергается: молчаливый reality без ключа не работает"
assert_eq "1" "$(rc_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?security=reality&sni=google.com')"

it "и в ошибке названо недостающее поле"
assert_contains "pbk" "$(err_of 'vless://94792286-7bbe-4f33-8b36-18d1bbf70723@example.com:443?security=reality&sni=google.com')"

# ============================ работа с конфигом ==============================
# Дальше нужен менеджер, поэтому в дело вступают заглушки сверху.

CONFIG=$(clash_empty_config)

it "прокси секции добавляется в proxies"
assert_jq '.proxies | length' "1" "$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_REALITY")"

it "имя прокси - тег секции, а не якорь ссылки"
assert_jq '.proxies[0].name' "main-out" "$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_REALITY")"

it "поля прокси доехали до конфига целыми"
assert_jq '.proxies[0]["reality-opts"]["public-key"]' "tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM" \
	"$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_REALITY")"

it "udp_over_tcp секции доезжает до прокси"
assert_jq '.proxies[0]["udp-over-tcp"]' "true" "$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$SS_BASE64" "1")"

it "битая ссылка не портит конфиг: на выходе пусто"
assert_eq "" "$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_KCP" 2>/dev/null)"

it "битая ссылка возвращает код ошибки"
clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_KCP" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc"

it "готовый объект прокси добавляется как есть"
assert_jq '.proxies[0].cipher' "aes-128-gcm" \
	"$(clash_cf_add_json_outbound "$CONFIG" "custom" '{"type":"ss","server":"1.2.3.4","port":8388,"cipher":"aes-128-gcm","password":"x"}')"

it "и получает имя секции"
assert_jq '.proxies[0].name' "custom-out" \
	"$(clash_cf_add_json_outbound "$CONFIG" "custom" '{"type":"ss","server":"1.2.3.4","port":8388,"cipher":"aes-128-gcm","password":"x"}')"

it "не-объект вместо прокси отвергается"
clash_cf_add_json_outbound "$CONFIG" "custom" '[1,2,3]' >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc"

it "интерфейс становится полем interface-name у прокси"
# Обе функции принимают секцию, а не имя прокси: тег выводится из неё через
# get_outbound_tag_by_section, как и в апстримном фасаде.
assert_jq '.proxies[0]["interface-name"]' "awg0" \
	"$(clash_cf_set_proxy_interface "$(clash_cf_add_proxy_outbound "$CONFIG" "main" "$VLESS_REALITY")" "main" "awg0")"

# ============================ правила и DNS ==================================

it "домен превращается в правило DOMAIN"
assert_jq '.rules[0]' "DOMAIN,ipinfo.io,main-out" "$(clash_cf_proxy_domain "$CONFIG" "ipinfo.io" "main-out")"

it "запрет по домену превращается в правило с REJECT"
assert_jq '.rules[0]' "DOMAIN-SUFFIX,example.com,REJECT" \
	"$(clash_cf_add_single_key_reject_rule "$CONFIG" "domain_suffix" "example.com")"

it "ключ ip_cidr знает свой тип правила"
assert_eq "IP-CIDR" "$(_clash_rule_type_from_key "ip_cidr")"

it "ключ source_ip_cidr тоже"
assert_eq "SRC-IP-CIDR" "$(_clash_rule_type_from_key "source_ip_cidr")"

it "признак, которого в правилах Clash нет, отвергается"
clash_cf_add_single_key_reject_rule "$CONFIG" "protocol" "quic" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc"

it "подмена порта у домена честно ничего не делает"
assert_json_eq "$CONFIG" "$(clash_cf_override_domain_port "$CONFIG" "example.com" 8443)"

DNS_CONFIG='{"dns":{"nameserver":[]}}'

it "udp остаётся udp: схемы в строке не будет"
assert_jq '.dns.nameserver[0]' "udp|1.1.1.1||" "$(clash_cf_add_dns_server "$DNS_CONFIG" "udp" "1.1.1.1")"

it "dot переводится в схему tls"
assert_jq '.dns.nameserver[0]' "tls|1.1.1.1||" "$(clash_cf_add_dns_server "$DNS_CONFIG" "dot" "1.1.1.1")"

it "doh переводится в схему https и сохраняет путь"
assert_jq '.dns.nameserver[0]' "https|dns.google||/dns-query" \
	"$(clash_cf_add_dns_server "$DNS_CONFIG" "doh" "https://dns.google/dns-query")"

it "doh без пути получает путь по умолчанию"
assert_jq '.dns.nameserver[0]' "https|dns.google||/dns-query" \
	"$(clash_cf_add_dns_server "$DNS_CONFIG" "doh" "https://dns.google")"

it "порт DNS-сервера не теряется"
assert_jq '.dns.nameserver[0]' "tls|1.1.1.1|8853|" "$(clash_cf_add_dns_server "$DNS_CONFIG" "dot" "1.1.1.1:8853")"

it "неизвестный тип DNS отвергается"
clash_cf_add_dns_server "$DNS_CONFIG" "quic" "1.1.1.1" >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "1" "$rc"

it "mixed-инбаунд поднимает порт"
assert_jq '.["mixed-port"]' "2080" "$(clash_cf_add_mixed_inbound_and_route_rule "$CONFIG" 2080 "main-out")"

finish
