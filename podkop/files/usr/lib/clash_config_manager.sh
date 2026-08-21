#
# Module: clash_config_manager.sh
#
# Purpose:
#   Набор функций для сборки конфигурации clash-rs — тот же приём, что и в
#   sing_box_config_manager.sh, только схема другая: proxies[], proxy-groups[],
#   rules[] строками, rule-providers{}, скалярные порты вместо inbounds[].
#   Соответствие функций разобрано в docs/mapping.md.
#
# Conventions:
#   - все функции названы clash_cm_*, "cm" — сокращение от "config manager"
#   - функция чистая: конфиг приходит строкой первым аргументом, изменённый
#     конфиг уходит в stdout, на диск ничего не пишется
#     (единственное исключение — clash_cm_save_config_to_file)
#   - имена полей в kebab-case: именно так их ждёт serde в clash-rs
#   - булевы аргументы передаются строками, истиной считается ровно "true"
#   - пустой необязательный аргумент означает "поле не задавать"
#   - DIRECT и REJECT — встроенные имена Clash, в proxies их не объявляют
#
# Usage:
#   Подключить в своём ash-скрипте:
#     . /usr/lib/podkop/clash_config_manager.sh
#
#   После этого доступны функции clash_cm_* для генерации и правки
#   конфигурации clash-rs.
#
# shellcheck shell=ash

# Диапазон fake-ip по умолчанию: тот же, что подкоп отдавал sing-box.
CLASH_DEFAULT_FAKEIP_RANGE="198.18.0.0/15"

#######################################
# Истиной считается ровно "true", "1", "yes" и "on".
# Заведено при переносе функций из clash_subscriptions.sh: там был свой
# такой же помощник, а в менеджере булевы значения до сих пор сравнивались
# с "true" прямо в jq. Держать два разных понимания истины в одном файле -
# верный способ разойтись.
# Arguments:
#   value: строка
# Returns:
#   0 если значение истинно
#######################################
_clash_cm_is_true() {
	case "$1" in
	true | TRUE | True | 1 | yes | YES | on | ON) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Задать уровень логирования в конфигурации Clash.
# У sing-box это объект log{}, у clash-rs — скаляр log-level.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   disabled: строка, "true" — логирование выключить (уровень silent)
#   level: строка, уровень: silent error warning info debug trace.
#          Пустой означает info.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_configure_log "$CONFIG" false "info")
#######################################
clash_cm_configure_log() {
    local config="$1"
    local disabled="$2"
    local level="$3"

    echo "$config" | jq \
        --arg disabled "$disabled" \
        --arg level "$level" \
        '.["log-level"] = (
            if $disabled == "true" then "silent"
            elif $level == "" then "info"
            else $level
            end
        )'
}

#######################################
# Задать режим маршрутизации и завести раздел правил.
# Аналог sing_box_cm_configure_route: у Clash нет route{}, есть режим и
# порядок правил в rules[].
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   mode: строка, режим: rule global direct. Пустой означает rule.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_configure_route "$CONFIG" "rule")
#######################################
clash_cm_configure_route() {
    local config="$1"
    local mode="$2"

    echo "$config" | jq \
        --arg mode "$mode" \
        '.mode = (if $mode == "" then "rule" else $mode end)
        | .rules = (.rules // [])'
}

#######################################
# Настроить Clash API. У sing-box это experimental.clash_api, у clash-rs —
# поля верхнего уровня.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   external_controller: строка, адрес API. Пустой — API не поднимается,
#                        ключ убирается из конфигурации.
#   external_ui: строка, каталог со статикой веб-интерфейса (необязательный)
#   secret: строка, секрет для авторизации в API (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_configure_clash_api "$CONFIG" "0.0.0.0:9090" "ui" "s3cret")
#######################################
clash_cm_configure_clash_api() {
    local config="$1"
    local external_controller="$2"
    local external_ui="$3"
    local secret="$4"

    echo "$config" | jq \
        --arg external_controller "$external_controller" \
        --arg external_ui "$external_ui" \
        --arg secret "$secret" \
        'if $external_controller == "" then
            del(.["external-controller"])
        else
            .["external-controller"] = $external_controller
        end
        | (if $external_ui != "" then .["external-ui"] = $external_ui else . end)
        | (if $secret != "" then .secret = $secret else . end)'
}

#######################################
# Настроить раздел profile. Заменяет experimental.cache_file у sing-box:
# путь к хранилищу clash-rs выбирает сам, настраивается только что хранить.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   store_selected: строка, "true" — помнить выбор в select-группах
#   store_fake_ip: строка, "true" — помнить выданные fake-ip между запусками
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_configure_profile "$CONFIG" true true)
#######################################
clash_cm_configure_profile() {
    local config="$1"
    local store_selected="$2"
    local store_fake_ip="$3"

    echo "$config" | jq \
        --arg store_selected "$store_selected" \
        --arg store_fake_ip "$store_fake_ip" \
        '.profile = {
            "store-selected": ($store_selected == "true"),
            "store-fake-ip": ($store_fake_ip == "true")
        }'
}

#######################################
# Настроить раздел dns. Уже настроенное (режим fake-ip, фильтры, политики)
# не затирается — дописываются только перечисленные поля.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   enable: строка, "true" — включить встроенный DNS clash-rs
#   listen: строка, адрес DNS-слушателя, например "127.0.0.42:53"
#           (необязательный; заменяет отдельный direct-инбаунд sing-box)
#   ipv6: строка, "true" — отдавать AAAA-ответы
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_configure_dns "$CONFIG" true "127.0.0.42:53" false)
#######################################
clash_cm_configure_dns() {
    local config="$1"
    local enable="$2"
    local listen="$3"
    local ipv6="$4"

    echo "$config" | jq \
        --arg enable "$enable" \
        --arg listen "$listen" \
        --arg ipv6 "$ipv6" \
        '.dns = (
            (.dns // {})
            + {
                enable: ($enable == "true"),
                ipv6: ($ipv6 == "true"),
                nameserver: ((.dns.nameserver) // [])
            }
            + (if $listen != "" then { listen: $listen } else {} end)
        )'
}

#######################################
# Добавить сервер в dns.nameserver. У sing-box под каждый транспорт был свой
# тип сервера, у Clash транспорт задаётся схемой в URL:
# "8.8.8.8:53", "tls://1.1.1.1:853", "https://1.1.1.1/dns-query".
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   type: строка, транспорт: udp tls https quic dhcp. Пустой и "udp" дают
#         адрес без схемы, любой другой подставляется как "<тип>://".
#   server_address: строка, адрес или имя сервера. IPv6-адрес без скобок
#                   оборачивается в них автоматически.
#   server_port: строка или число, порт (необязательный)
#   path: строка, путь запроса для https (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_nameserver "$CONFIG" "udp" "8.8.8.8" 53)
#   CONFIG=$(clash_cm_add_nameserver "$CONFIG" "https" "1.1.1.1" "" "/dns-query")
#######################################
clash_cm_add_nameserver() {
    local config="$1"
    local type="$2"
    local server_address="$3"
    local server_port="$4"
    local path="$5"

    echo "$config" | jq \
        --arg type "$type" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg path "$path" \
        '
        def host:
            if ($server_address | index(":")) != null
                and ($server_address | startswith("[") | not)
            then "[" + $server_address + "]"
            else $server_address
            end;

        .dns.nameserver = ((.dns.nameserver // []) + [(
            (if $type == "" or $type == "udp" then "" else $type + "://" end)
            + host
            + (if $server_port != "" then ":" + $server_port else "" end)
            + (if $path == "" then ""
               elif ($path | startswith("/")) then $path
               else "/" + $path
               end)
        )])'
}

#######################################
# Включить режим fake-ip. У sing-box это был отдельный DNS-сервер, у Clash —
# режим работы встроенного резолвера.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   fakeip_range: строка, диапазон подменных адресов
#                 (необязательный, по умолчанию 198.18.0.0/15)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_enable_fakeip "$CONFIG" "198.18.0.0/15")
#######################################
clash_cm_enable_fakeip() {
    local config="$1"
    local fakeip_range="$2"

    echo "$config" | jq \
        --arg fakeip_range "$fakeip_range" \
        --arg default_range "$CLASH_DEFAULT_FAKEIP_RANGE" \
        '.dns["enhanced-mode"] = "fake-ip"
        | .dns["fake-ip-range"] = (
            if $fakeip_range == "" then $default_range else $fakeip_range end
        )
        | .dns["fake-ip-filter"] = (.dns["fake-ip-filter"] // [])'
}

#######################################
# Добавить шаблон в dns.fake-ip-filter: подходящим именам fake-ip не выдаётся,
# они резолвятся обычным образом.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   pattern: строка, шаблон имени, например "+.lan". Пустой ничего не меняет.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_fakeip_filter "$CONFIG" "+.lan")
#######################################
clash_cm_add_fakeip_filter() {
    local config="$1"
    local pattern="$2"

    echo "$config" | jq \
        --arg pattern "$pattern" \
        'if $pattern == "" then
            .
        else
            .dns["fake-ip-filter"] = ((.dns["fake-ip-filter"] // []) + [$pattern])
        end'
}

#######################################
# Добавить запись в dns.nameserver-policy — "какое имя каким сервером решать".
# Заменяет правила dns.rules у sing-box: у Clash это карта, а не список,
# поэтому повторная запись по тому же ключу перезаписывает значение.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   domain: строка, шаблон имени, например "+.example.com"
#   server: строка, сервер или JSON-массив серверов
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_nameserver_policy "$CONFIG" "+.example.com" "tls://1.1.1.1")
#   CONFIG=$(clash_cm_add_nameserver_policy "$CONFIG" "+.lan" '["192.168.1.1"]')
#######################################
clash_cm_add_nameserver_policy() {
    local config="$1"
    local domain="$2"
    local server="$3"

    server=$(_clash_cm_normalize_arg "$server")

    echo "$config" | jq \
        --arg domain "$domain" \
        --argjson server "$server" \
        '.dns["nameserver-policy"] = (
            (.dns["nameserver-policy"] // {}) + { ($domain): $server }
        )'
}

#######################################
# Задать порт tproxy-инбаунда. У sing-box это была запись в inbounds[] с тегом,
# у clash-rs — скаляр верхнего уровня, тега нет (см. «Пробелы» в mapping.md).
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   port: строка или число, порт. Пустой убирает ключ, инбаунд не поднимается.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_tproxy_port "$CONFIG" 6969)
#######################################
clash_cm_set_tproxy_port() {
    local config="$1"
    local port="$2"

    echo "$config" | jq \
        --arg port "$port" \
        'if $port == "" then
            del(.["tproxy-port"])
        else
            .["tproxy-port"] = ($port | tonumber)
        end'
}

#######################################
# Задать порт mixed-инбаунда (HTTP и SOCKS на одном порту).
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   port: строка или число, порт. Пустой убирает ключ.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_mixed_port "$CONFIG" 2080)
#######################################
clash_cm_set_mixed_port() {
    local config="$1"
    local port="$2"

    echo "$config" | jq \
        --arg port "$port" \
        'if $port == "" then
            del(.["mixed-port"])
        else
            .["mixed-port"] = ($port | tonumber)
        end'
}

#######################################
# Задать адрес, на котором слушают инбаунды. Один на все порты: у Clash
# отдельного listen у каждого инбаунда нет.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   address: строка, адрес или "*" для всех интерфейсов. Пустой убирает ключ.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_bind_address "$CONFIG" "*")
#######################################
clash_cm_set_bind_address() {
    local config="$1"
    local address="$2"

    echo "$config" | jq \
        --arg address "$address" \
        'if $address == "" then
            del(.["bind-address"])
        else
            .["bind-address"] = $address
        end'
}

#######################################
# Добавить VLESS-прокси в proxies[].
# TLS, Reality и транспорт задаются отдельными функциями:
# clash_cm_set_tls_for_proxy, clash_cm_set_ws_transport, clash_cm_set_grpc_transport.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси (в Clash оно же идентификатор для правил)
#   server_address: строка, адрес сервера
#   server_port: строка или число, порт сервера
#   uuid: строка, UUID пользователя
#   flow: строка, flow, например "xtls-rprx-vision" (необязательный)
#   packet_encoding: строка, упаковка UDP: packetaddr или xudp (необязательный)
#   udp: строка, "true" — разрешить UDP через этот прокси (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(
#       clash_cm_add_vless_proxy "$CONFIG" "vless-out" "example.com" 443 \
#       "bf000d23-0752-40b4-affe-68f7707a9661" "xtls-rprx-vision" "xudp" true
#   )
#######################################
clash_cm_add_vless_proxy() {
    local config="$1"
    local name="$2"
    local server_address="$3"
    local server_port="$4"
    local uuid="$5"
    local flow="$6"
    local packet_encoding="$7"
    local udp="$8"

    echo "$config" | jq \
        --arg name "$name" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg uuid "$uuid" \
        --arg flow "$flow" \
        --arg packet_encoding "$packet_encoding" \
        --arg udp "$udp" \
        '.proxies += [(
            {
                name: $name,
                type: "vless",
                server: $server_address,
                port: ($server_port | tonumber),
                uuid: $uuid
            }
            + (if $flow != "" then {flow: $flow} else {} end)
            + (if $packet_encoding != "" then {"packet-encoding": $packet_encoding} else {} end)
            + (if $udp == "true" then {udp: true} else {} end)
        )]'
}

#######################################
# Добавить Shadowsocks-прокси в proxies[].
# У sing-box поле называлось method, у Clash — cipher.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси
#   server_address: строка, адрес сервера
#   server_port: строка или число, порт сервера
#   cipher: строка, метод шифрования
#   password: строка, пароль
#   udp: строка, "true" — разрешить UDP (необязательный)
#   plugin: строка, имя плагина, например "obfs" (необязательный)
#   plugin_opts: строка, JSON-объект с настройками плагина (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(
#       clash_cm_add_shadowsocks_proxy "$CONFIG" "ss-out" "127.0.0.1" 443 \
#       "2022-blake3-aes-128-gcm" "8JCsPssfgS8tiRwiMlhARg==" true
#   )
#######################################
clash_cm_add_shadowsocks_proxy() {
    local config="$1"
    local name="$2"
    local server_address="$3"
    local server_port="$4"
    local cipher="$5"
    local password="$6"
    local udp="$7"
    local plugin="$8"
    local plugin_opts="$9"

    echo "$config" | jq \
        --arg name "$name" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg cipher "$cipher" \
        --arg password "$password" \
        --arg udp "$udp" \
        --arg plugin "$plugin" \
        --arg plugin_opts "$plugin_opts" \
        '.proxies += [(
            {
                name: $name,
                type: "ss",
                server: $server_address,
                port: ($server_port | tonumber),
                cipher: $cipher,
                password: $password
            }
            + (if $udp == "true" then {udp: true} else {} end)
            + (if $plugin != "" then {plugin: $plugin} else {} end)
            + (if $plugin_opts != "" then {"plugin-opts": ($plugin_opts | fromjson)} else {} end)
        )]'
}

#######################################
# Добавить Trojan-прокси в proxies[].
# Trojan всегда работает поверх TLS, поэтому имя сервера у него зовётся sni,
# а не servername; отдельного флага tls в схеме нет.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси
#   server_address: строка, адрес сервера
#   server_port: строка или число, порт сервера
#   password: строка, пароль
#   sni: строка, имя сервера для проверки сертификата (необязательный)
#   udp: строка, "true" — разрешить UDP (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_trojan_proxy "$CONFIG" "trojan-out" "example.com" 443 "secret" "example.com" true)
#######################################
clash_cm_add_trojan_proxy() {
    local config="$1"
    local name="$2"
    local server_address="$3"
    local server_port="$4"
    local password="$5"
    local sni="$6"
    local udp="$7"

    echo "$config" | jq \
        --arg name "$name" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg password "$password" \
        --arg sni "$sni" \
        --arg udp "$udp" \
        '.proxies += [(
            {
                name: $name,
                type: "trojan",
                server: $server_address,
                port: ($server_port | tonumber),
                password: $password
            }
            + (if $sni != "" then {sni: $sni} else {} end)
            + (if $udp == "true" then {udp: true} else {} end)
        )]'
}

#######################################
# Добавить SOCKS5-прокси в proxies[].
# У Clash тип один — socks5, версии 4 и 4a не поддерживаются.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси
#   server_address: строка, адрес сервера
#   server_port: строка или число, порт сервера
#   username: строка, имя пользователя (необязательный)
#   password: строка, пароль (необязательный)
#   udp: строка, "true" — разрешить UDP (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_socks_proxy "$CONFIG" "socks-out" "192.168.1.10" 1080)
#######################################
clash_cm_add_socks_proxy() {
    local config="$1"
    local name="$2"
    local server_address="$3"
    local server_port="$4"
    local username="$5"
    local password="$6"
    local udp="$7"

    echo "$config" | jq \
        --arg name "$name" \
        --arg server_address "$server_address" \
        --arg server_port "$server_port" \
        --arg username "$username" \
        --arg password "$password" \
        --arg udp "$udp" \
        '.proxies += [(
            {
                name: $name,
                type: "socks5",
                server: $server_address,
                port: ($server_port | tonumber)
            }
            + (if $username != "" then {username: $username} else {} end)
            + (if $password != "" then {password: $password} else {} end)
            + (if $udp == "true" then {udp: true} else {} end)
        )]'
}

#######################################
# Вставить готовый объект прокси в proxies[] как есть.
# Приём тот же, что и у sing_box_cm_add_raw_outbound: пользователь принёс
# JSON — кладём его без разбора, только подставляем имя.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси. Пустое оставляет имя из самого объекта.
#   raw_proxy: строка, JSON-объект прокси
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_raw_proxy "$CONFIG" "raw-out" '{"type":"ss","server":"127.0.0.1","port":443,"cipher":"aes-128-gcm","password":"pass"}')
#######################################
clash_cm_add_raw_proxy() {
    local config="$1"
    local name="$2"
    local raw_proxy="$3"

    echo "$config" | jq \
        --arg name "$name" \
        --argjson raw_proxy "$raw_proxy" \
        '.proxies += [(
            $raw_proxy + (if $name != "" then {name: $name} else {} end)
        )]'
}

#######################################
# Настроить TLS у прокси с указанным именем.
# У Trojan имя сервера кладётся в sni и флаг tls не выставляется — он там
# подразумевается схемой; у остальных типов это servername и tls: true.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси, который надо изменить
#   servername: строка, имя сервера для SNI и проверки сертификата (необязательный)
#   skip_cert_verify: строка, "true" — не проверять сертификат (необязательный)
#   alpn: строка, JSON-массив протоколов, например '["h2"]' (необязательный;
#         пустая строка и "null" означают "не задавать")
#   client_fingerprint: строка, отпечаток TLS-клиента, например "chrome"
#                       (необязательный; у sing-box это был utls)
#   reality_public_key: строка, публичный ключ Reality (необязательный)
#   reality_short_id: строка, short id Reality (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(
#       clash_cm_set_tls_for_proxy "$CONFIG" "vless-out" "example.com" false "" "chrome" \
#       "jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0" "0123456789abcdef"
#   )
#######################################
clash_cm_set_tls_for_proxy() {
    local config="$1"
    local name="$2"
    local servername="$3"
    local skip_cert_verify="$4"
    local alpn="$5"
    local client_fingerprint="$6"
    local reality_public_key="$7"
    local reality_short_id="$8"

    echo "$config" | jq \
        --arg name "$name" \
        --arg servername "$servername" \
        --arg skip_cert_verify "$skip_cert_verify" \
        --arg alpn "$alpn" \
        --arg client_fingerprint "$client_fingerprint" \
        --arg reality_public_key "$reality_public_key" \
        --arg reality_short_id "$reality_short_id" \
        '.proxies |= map(
            if .name == $name then
                .
                + (if .type == "trojan" then {} else {tls: true} end)
                + (if $servername == "" then {}
                   elif .type == "trojan" then {sni: $servername}
                   else {servername: $servername}
                   end)
                + (if $skip_cert_verify == "true" then {"skip-cert-verify": true} else {} end)
                + (if $alpn != "" and $alpn != "null" then {alpn: ($alpn | fromjson)} else {} end)
                + (if $client_fingerprint != "" then {"client-fingerprint": $client_fingerprint} else {} end)
                + (if $reality_public_key != "" then {
                    "reality-opts": (
                        {"public-key": $reality_public_key}
                        + (if $reality_short_id != "" then {"short-id": $reality_short_id} else {} end)
                    )
                } else {} end)
            else
                .
            end
        )'
}

#######################################
# Настроить транспорт WebSocket у прокси с указанным именем.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси, который надо изменить
#   path: строка, путь запроса (необязательный)
#   host: строка, заголовок Host (необязательный)
#   max_early_data: строка или число, размер early data (необязательный)
#   early_data_header_name: строка, имя заголовка early data (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_ws_transport "$CONFIG" "vless-out" "/path" "example.com")
#######################################
clash_cm_set_ws_transport() {
    local config="$1"
    local name="$2"
    local path="$3"
    local host="$4"
    local max_early_data="$5"
    local early_data_header_name="$6"

    echo "$config" | jq \
        --arg name "$name" \
        --arg path "$path" \
        --arg host "$host" \
        --arg max_early_data "$max_early_data" \
        --arg early_data_header_name "$early_data_header_name" \
        '.proxies |= map(
            if .name == $name then
                . + {
                    network: "ws",
                    "ws-opts": (
                        (if $path != "" then {path: $path} else {} end)
                        + (if $host != "" then {headers: {Host: $host}} else {} end)
                        + (if $max_early_data != "" then
                            {"max-early-data": ($max_early_data | tonumber)}
                        else {} end)
                        + (if $early_data_header_name != "" then
                            {"early-data-header-name": $early_data_header_name}
                        else {} end)
                    )
                }
            else
                .
            end
        )'
}

#######################################
# Настроить транспорт gRPC у прокси с указанным именем.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси, который надо изменить
#   service_name: строка, имя gRPC-сервиса (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_grpc_transport "$CONFIG" "vless-out" "TunService")
#######################################
clash_cm_set_grpc_transport() {
    local config="$1"
    local name="$2"
    local service_name="$3"

    echo "$config" | jq \
        --arg name "$name" \
        --arg service_name "$service_name" \
        '.proxies |= map(
            if .name == $name then
                . + {
                    network: "grpc",
                    "grpc-opts": (
                        if $service_name != "" then
                            {"grpc-service-name": $service_name}
                        else {} end
                    )
                }
            else
                .
            end
        )'
}

#######################################
# Привязать прокси к сетевому интерфейсу.
# У sing-box для этого заводился отдельный direct-выход с bind_interface,
# у Clash это поле самого прокси.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя прокси, который надо изменить
#   interface: строка, имя интерфейса, например "awg0".
#              Пустое ничего не меняет.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_set_interface_for_proxy "$CONFIG" "warp-out" "awg0")
#######################################
clash_cm_set_interface_for_proxy() {
    local config="$1"
    local name="$2"
    local interface="$3"

    echo "$config" | jq \
        --arg name "$name" \
        --arg interface "$interface" \
        'if $interface == "" then
            .
        else
            .proxies |= map(
                if .name == $name then
                    . + {"interface-name": $interface}
                else
                    .
                end
            )
        end'
}

#######################################
# Добавить группу select в proxy-groups[] — переключаемую руками или
# через Clash API. Аналог selector-выхода sing-box.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя группы
#   proxies: строка, JSON-массив имён участников.
#            Пустая строка означает пустой массив.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_select_group "$CONFIG" "main" '["vless-out","DIRECT"]')
#######################################
clash_cm_add_select_group() {
    local config="$1"
    local name="$2"
    local proxies="$3"

    echo "$config" | jq \
        --arg name "$name" \
        --arg proxies "$proxies" \
        '.["proxy-groups"] += [{
            name: $name,
            type: "select",
            proxies: (if $proxies == "" then [] else ($proxies | fromjson) end)
        }]'
}

#######################################
# Добавить группу url-test в proxy-groups[] — выбирает участника с наименьшей
# задержкой. Аналог urltest-выхода sing-box.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя группы
#   proxies: строка, JSON-массив имён участников.
#            Пустая строка означает пустой массив.
#   url: строка, адрес для замера задержки (необязательный)
#   interval: строка или число, период проверки в секундах (необязательный)
#   tolerance: строка или число, допустимая разница задержек в мс
#              (необязательный)
#   lazy: строка, "true" — не проверять, пока группа не используется
#         (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(
#       clash_cm_add_urltest_group "$CONFIG" "auto" '["p1","p2"]' \
#       "http://cp.cloudflare.com/generate_204" 300 50
#   )
#######################################
clash_cm_add_urltest_group() {
    local config="$1"
    local name="$2"
    local proxies="$3"
    local url="$4"
    local interval="$5"
    local tolerance="$6"
    local lazy="$7"

    echo "$config" | jq \
        --arg name "$name" \
        --arg proxies "$proxies" \
        --arg url "$url" \
        --arg interval "$interval" \
        --arg tolerance "$tolerance" \
        --arg lazy "$lazy" \
        '.["proxy-groups"] += [(
            {
                name: $name,
                type: "url-test",
                proxies: (if $proxies == "" then [] else ($proxies | fromjson) end)
            }
            + (if $url != "" then {url: $url} else {} end)
            + (if $interval != "" then {interval: ($interval | tonumber)} else {} end)
            + (if $tolerance != "" then {tolerance: ($tolerance | tonumber)} else {} end)
            + (if $lazy != "" then {lazy: ($lazy == "true")} else {} end)
        )]'
}

#######################################
# Добавить правило в rules[]. Правило у Clash — строка вида
# "ТИП,ЗНАЧЕНИЕ,ЦЕЛЬ[,no-resolve]"; у правил без значения (MATCH) средняя
# часть опускается. Тип приводится к верхнему регистру.
# Порядок правил значим: выигрывает первое совпавшее, поэтому правила
# дописываются в конец в том порядке, в каком их добавляли.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   type: строка, тип правила: DOMAIN-SUFFIX, IP-CIDR, RULE-SET, MATCH и прочие
#   value: строка, значение правила. Пустая даёт правило без значения.
#   target: строка, цель: имя прокси, группы, DIRECT или REJECT
#   no_resolve: строка, "true" — добавить флаг no-resolve (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_rule "$CONFIG" "DOMAIN-SUFFIX" "example.com" "main")
#   CONFIG=$(clash_cm_add_rule "$CONFIG" "IP-CIDR" "1.1.1.1/32" "main" true)
#######################################
clash_cm_add_rule() {
    local config="$1"
    local type="$2"
    local value="$3"
    local target="$4"
    local no_resolve="$5"

    echo "$config" | jq \
        --arg type "$type" \
        --arg value "$value" \
        --arg target "$target" \
        --arg no_resolve "$no_resolve" \
        '.rules += [(
            ($type | ascii_upcase)
            + (if $value != "" then "," + $value else "" end)
            + "," + $target
            + (if $no_resolve == "true" then ",no-resolve" else "" end)
        )]'
}

#######################################
# Добавить правило по набору правил: "RULE-SET,<набор>,<цель>".
# Набор должен быть объявлен в rule-providers.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   provider: строка, имя набора из rule-providers
#   target: строка, цель: имя прокси, группы, DIRECT или REJECT
#   no_resolve: строка, "true" — добавить флаг no-resolve (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_ruleset_rule "$CONFIG" "telegram" "main")
#######################################
clash_cm_add_ruleset_rule() {
    local config="$1"
    local provider="$2"
    local target="$3"
    local no_resolve="$4"

    clash_cm_add_rule "$config" "RULE-SET" "$provider" "$target" "$no_resolve"
}

#######################################
# Добавить запрещающее правило: то же, что clash_cm_add_rule, но с целью REJECT.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   type: строка, тип правила, например DOMAIN-SUFFIX
#   value: строка, значение правила
#   no_resolve: строка, "true" — добавить флаг no-resolve (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_reject_rule "$CONFIG" "DOMAIN-SUFFIX" "ads.example.com")
#######################################
clash_cm_add_reject_rule() {
    local config="$1"
    local type="$2"
    local value="$3"
    local no_resolve="$4"

    clash_cm_add_rule "$config" "$type" "$value" "REJECT" "$no_resolve"
}

#######################################
# Добавить завершающее правило MATCH — куда идёт всё, что не совпало.
# Аналог route.final у sing-box. Должно добавляться последним: правила ниже
# него никогда не сработают.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   target: строка, цель: имя прокси, группы, DIRECT или REJECT
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_match_rule "$CONFIG" "DIRECT")
#######################################
clash_cm_add_match_rule() {
    local config="$1"
    local target="$2"

    clash_cm_add_rule "$config" "MATCH" "" "$target" ""
}

#######################################
# Объявить набор правил, скачиваемый по HTTP.
# Замена remote-ruleset у sing-box: формат .srs clash-rs не читает, списки
# берутся текстом или yaml.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя набора, по нему на него ссылаются правила RULE-SET
#   behavior: строка, что лежит в наборе: domain ipcidr classical.
#             Пустое означает classical.
#   format: строка, формат файла: yaml text mrs (необязательный)
#   url: строка, адрес для скачивания
#   path: строка, куда класть скачанное (необязательный)
#   interval: строка или число, период обновления в секундах (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(
#       clash_cm_add_http_rule_provider "$CONFIG" "telegram" "ipcidr" "text" \
#       "https://example.com/telegram.lst" "./rules/telegram.lst" 86400
#   )
#######################################
clash_cm_add_http_rule_provider() {
    local config="$1"
    local name="$2"
    local behavior="$3"
    local format="$4"
    local url="$5"
    local path="$6"
    local interval="$7"

    echo "$config" | jq \
        --arg name "$name" \
        --arg behavior "$behavior" \
        --arg format "$format" \
        --arg url "$url" \
        --arg path "$path" \
        --arg interval "$interval" \
        '.["rule-providers"] = ((.["rule-providers"] // {}) + { ($name): (
            {
                type: "http",
                behavior: (if $behavior == "" then "classical" else $behavior end),
                url: $url
            }
            + (if $format != "" then {format: $format} else {} end)
            + (if $path != "" then {path: $path} else {} end)
            + (if $interval != "" then {interval: ($interval | tonumber)} else {} end)
        )})'
}

#######################################
# Объявить набор правил из локального файла.
# Замена local-ruleset и inline-ruleset у sing-box: у Clash встроенных
# наборов нет, список пишется в файл, а файл объявляется провайдером.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя набора, по нему на него ссылаются правила RULE-SET
#   behavior: строка, что лежит в наборе: domain ipcidr classical.
#             Пустое означает classical.
#   format: строка, формат файла: yaml text mrs (необязательный)
#   path: строка, путь к файлу
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   CONFIG=$(clash_cm_add_file_rule_provider "$CONFIG" "local-domains" "domain" "text" "/tmp/podkop/local.lst")
#######################################

#######################################
# Положить готовое описание в proxy-providers.
#
# ЭТО ФУНКЦИЯ МЕНЕДЖЕРА, живущая не в менеджере: в clash_config_manager.sh
# работы с proxy-providers нет вовсе (есть только rule-providers), а править
# чужой файл в рамках этой задачи нельзя. При интеграции её стоит перенести
# в менеджер под именем clash_cm_add_raw_proxy_provider - она ничем не
# отличается от clash_cm_add_raw_rule_provider, кроме ключа.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, ключ в proxy-providers
#   provider: строка (JSON), объект провайдера целиком
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Returns:
#   1 если имя пусто либо provider не разбирается как JSON
# Example:
#   CONFIG=$(clash_cm_add_raw_proxy_provider "$CONFIG" "main-sub1" "$PROVIDER_JSON")
#######################################
clash_cm_add_raw_proxy_provider() {
	local config="$1" name="$2" provider="$3"

	[ -n "$name" ] || return 1
	printf '%s' "$provider" | jq -e . > /dev/null 2>&1 || return 1

	# shellcheck disable=SC2016  # $name и $provider - переменные jq, не шелла
	printf '%s\n' "$config" | jq \
		--arg name "$name" \
		--argjson provider "$provider" \
		'.["proxy-providers"] = ((.["proxy-providers"] // {}) + {($name): $provider})'
}


#######################################
# Добавить группу, участники которой берутся из провайдеров.
#
# Тоже функция менеджера не на своём месте: clash_cm_add_select_group и
# clash_cm_add_urltest_group умеют только поимённый список proxies и поля use
# не знают, а имена серверов подписки нам на этапе сборки конфига неизвестны -
# их узнает ядро, когда скачает тело. Переносить в менеджер вместе с
# предыдущей.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   name: строка, имя группы
#   kind: строка, urltest|url-test либо selector|select
#   use_json: строка, JSON-массив имён провайдеров
#   proxies_json: строка, JSON-массив дополнительных участников поимённо
#                 (необязательный; пустой массив в конфиг не пишется)
#   url: строка, чем мерять задержку (необязательный)
#   interval: строка или число, период замера в секундах (необязательный)
#   tolerance: строка или число, допуск в мс (необязательный)
#   lazy: строка, "true"/"1" (необязательный)
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Returns:
#   1 при неизвестном типе группы или неразбираемых массивах
# Example:
#   CONFIG=$(clash_cm_add_provider_group "$CONFIG" "main-out" select '["main-sub1"]' "" "" "" "" "")
#######################################
clash_cm_add_provider_group() {
	local config="$1" name="$2" kind="$3" use_json="$4" proxies_json="$5"
	local url="$6" interval="$7" tolerance="$8" lazy="$9"
	local type lazy_json=""

	[ -n "$name" ] || return 1

	case "$kind" in
	urltest | url-test | url_test) type="url-test" ;;
	selector | select) type="select" ;;
	*)
		log "Неизвестный тип группы подписки: '$kind'" "error"
		return 1
		;;
	esac

	[ -n "$use_json" ] || use_json="[]"
	[ -n "$proxies_json" ] || proxies_json="[]"

	printf '%s' "$use_json" | jq -e 'type == "array"' > /dev/null 2>&1 || return 1
	printf '%s' "$proxies_json" | jq -e 'type == "array"' > /dev/null 2>&1 || return 1

	if [ -n "$lazy" ]; then
		if _clash_cm_is_true "$lazy"; then lazy_json="true"; else lazy_json="false"; fi
	fi

	# shellcheck disable=SC2016  # $name и прочее - переменные jq, не шелла
	printf '%s\n' "$config" | jq \
		--arg name "$name" \
		--arg type "$type" \
		--argjson use "$use_json" \
		--argjson proxies "$proxies_json" \
		--arg url "$url" \
		--arg interval "$interval" \
		--arg tolerance "$tolerance" \
		--arg lazy "$lazy_json" \
		'.["proxy-groups"] = ((.["proxy-groups"] // []) + [(
			{name: $name, type: $type, use: $use}
			+ (if ($proxies | length) > 0 then {proxies: $proxies} else {} end)
			+ (if $url != "" then {url: $url} else {} end)
			+ (if $interval != "" then {interval: ($interval | tonumber)} else {} end)
			+ (if $tolerance != "" then {tolerance: ($tolerance | tonumber)} else {} end)
			+ (if $lazy == "" then {} else {lazy: ($lazy == "true")} end)
		)])'
}

#######################################
# Положить в rule-providers готовое описание провайдера, как есть.
#
# Нужно там, где описание собирает не менеджер, а слой списков: он скачивает
# файл, определяет behavior по содержимому и возвращает готовый объект. Дублировать
# это определение здесь значило бы держать две расходящиеся копии логики.
#
# Arguments:
#   config:   string (JSON), конфигурация Clash
#   name:     string, ключ в rule-providers
#   provider: string (JSON), объект провайдера целиком
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Returns:
#   1 если provider не разбирается как JSON - молча подставлять мусор в
#   конфиг нельзя, ядро потом откажется стартовать без внятной причины
# Example:
#   CONFIG=$(clash_cm_add_raw_rule_provider "$CONFIG" "telegram" "$PROVIDER_JSON")
#######################################
clash_cm_add_raw_rule_provider() {
	local config="$1"
	local name="$2"
	local provider="$3"

	printf '%s' "$provider" | jq -e . >/dev/null 2>&1 || return 1

	echo "$config" | jq \
		--arg name "$name" \
		--argjson provider "$provider" \
		'.["rule-providers"] += {($name): $provider}'
}

clash_cm_add_file_rule_provider() {
    local config="$1"
    local name="$2"
    local behavior="$3"
    local format="$4"
    local path="$5"

    echo "$config" | jq \
        --arg name "$name" \
        --arg behavior "$behavior" \
        --arg format "$format" \
        --arg path "$path" \
        '.["rule-providers"] = ((.["rule-providers"] // {}) + { ($name): (
            {
                type: "file",
                behavior: (if $behavior == "" then "classical" else $behavior end),
                path: $path
            }
            + (if $format != "" then {format: $format} else {} end)
        )})'
}

#######################################
# Записать конфигурацию в файл.
# Пишем JSON: он подмножество YAML, и clash-rs читает его тем же разбором,
# так что переводить в YAML отдельно не нужно.
# Arguments:
#   config: строка (JSON), конфигурация для записи
#   filepath: строка, путь к файлу
# Outputs:
#   Пишет конфигурацию в указанный файл
# Example:
#   clash_cm_save_config_to_file "$CONFIG" "/tmp/podkop/clash-config.json"
#######################################
clash_cm_save_config_to_file() {
    local config="$1"
    local filepath="$2"

    echo "$config" | jq '.' > "$filepath"
}

# Привести аргумент к JSON: то, что уже разбирается как JSON, оставляем как
# есть, всё остальное заворачиваем в строку. Нужно там, где значение может
# быть и скаляром, и массивом.
_clash_cm_normalize_arg() {
    local value="$1"
    if echo "$value" | jq -e . > /dev/null 2>&1; then
        printf '%s' "$value"
    else
        printf '%s' "$value" | jq -R .
    fi
}
