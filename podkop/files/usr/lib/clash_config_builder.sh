#
# Module: clash_config_builder.sh
#
# Purpose:
#   Сборка полной конфигурации clash-rs из настроек UCI. Пара к
#   sing_box_init_config и семейству sing_box_configure_* из /usr/bin/podkop:
#   те же настройки, тот же порядок шагов, только на выходе схема clash-rs
#   (см. docs/mapping.md). Своей логики здесь нет - модуль раскладывает
#   настройки по вызовам clash_cm_* (менеджер), clash_cf_* (фасад),
#   ruleset_* (переключатель наборов) и clash_rs_* (списки).
#
# Conventions:
#   - функции названы clash_configure_* и clash_*_handler, как в апстриме
#   - конфиг живёт в глобальной переменной $config: её заводит
#     clash_init_config, каждая clash_configure_* переписывает её целиком.
#     Поэтому функции здесь НЕ чистые, в отличие от менеджера, и зовутся без
#     $( ) - ровно как sing_box_configure_log и соседи
#   - всё, что зовётся через config_foreach, обязано пережить секцию без
#     единой заполненной опции: в LuCI секцию заводят раньше, чем настраивают
#
# Что важно знать про схему Clash, прежде чем читать дальше:
#
#   1. Правила - упорядоченный список строк, выигрывает ПЕРВОЕ совпавшее.
#      Порядок обхода секций поэтому повторяет апстримный один в один:
#      сначала списки block-секций, затем exclusion, затем адреса устройств,
#      затем списки секций proxy/vpn в порядке объявления в UCI. Ровно так же
#      ложатся правила в route.rules у sing-box, и ровно этим объясняется
#      поведение, которое видно живьём: russia_inside в секции main
#      перехватывает домен раньше, чем до него доберётся секция ниже.
#
#   2. У инбаундов нет тегов, значит нет и правил "трафик пришёл оттуда-то".
#      Всё, что у sing-box делалось через inbound: tproxy-in, здесь не
#      выражается вовсе (см. "Пробелы" в docs/mapping.md).
#
#   3. Режим fake-ip у Clash - свойство резолвера, а не отдельный сервер:
#      поддельный адрес выдаётся ВСЕМ именам, кроме перечисленных в
#      dns.fake-ip-filter. У sing-box было наоборот - fakeip получали только
#      домены из списков. Значит через ядро пойдёт весь трафик, а не только
#      подпадающий под списки. Это самое крупное поведенческое отличие
#      конфига, и проверять его надо на живом роутере, а не на глаз.
#
# Про глобальный режим (global_proxy на секции). В форке netshift его сделали
# так: "раз включён глобальный прокси, списки секции не нужны", и функция
# построения правил выходила по return 0. Правило не создавалось вовсе, весь
# трафик проваливался в route.final и уходил напрямую - глобальный прокси
# отправлял всё мимо туннеля, без единой ошибки в логах. Здесь правила
# строятся ВСЕГДА, а глобальность выражается только целью финального MATCH.
#
# Usage:
#   Подключить в своём ash-скрипте после менеджера, фасада и слоя ядра:
#     . /usr/lib/podkop/clash_config_builder.sh
#   и позвать clash_init_config - она соберёт конфиг и запишет его на диск.
#
# Depends on:
#   constants.sh             SB_* и прочие константы подкопа
#   helpers.sh               get_outbound_tag_by_section, url_get_*, file_exists
#   logging.sh               log
#   core.sh                  core_config_path, core_check_config
#   clash_config_manager.sh  clash_cm_*
#   clash_config_facade.sh   clash_cf_* и _clash_json_array_from_commas
#   clash_rulesets.sh        clash_rs_*
#   ruleset_dispatch.sh      ruleset_add_community, ruleset_folder
#   nft.sh и /usr/bin/podkop nft_*, get_first_outbound_section,
#                            section_has_enabled_lists, get_service_*
#
# shellcheck shell=ash

# Адрес, на котором слушают инбаунды. У Clash он один на все порты, поэтому
# SB_TPROXY_INBOUND_ADDRESS (127.0.0.1) не годится: на том же адресе висел бы
# и mixed-прокси, до которого клиенты из LAN не достучались бы.
CLASH_BIND_ADDRESS="${CLASH_BIND_ADDRESS:-*}"

# Формат payload у наборов правил, которые готовит подкоп. yaml понимают и
# clash-rs, и mihomo, поэтому он же стоит умолчанием в clash_rulesets.sh.
CLASH_RULE_PROVIDER_FORMAT="${CLASH_RULE_PROVIDER_FORMAT:-yaml}"

## --- служебное --------------------------------------------------------------

#######################################
# Перевести уровень логирования подкопа в уровень clash-rs.
# У sing-box уровни trace debug info warn error fatal panic, у clash-rs -
# silent error warning info debug trace. Совпадают не все, поэтому таблица.
# Arguments:
#   level: строка, уровень из podkop.settings.log_level
# Outputs:
#   Уровень в терминах clash-rs
# Example:
#   _clash_log_level "warn"   # -> warning
#######################################
_clash_log_level() {
    case "$1" in
    silent | trace | debug | info | error) printf '%s' "$1" ;;
    warn | warning) printf '%s' "warning" ;;
    # у clash-rs нет уровней "fatal" и "panic", а ронять сборку из-за
    # настройки логирования незачем
    fatal | panic) printf '%s' "error" ;;
    *) printf '%s' "info" ;;
    esac
}

#######################################
# Тип правила Clash по виду адреса.
# Arguments:
#   value: строка, адрес или подсеть
# Outputs:
#   IP-CIDR либо IP-CIDR6
# Example:
#   _clash_ip_rule_type "2001:db8::/32"   # -> IP-CIDR6
#######################################
_clash_ip_rule_type() {
    case "$1" in
    *:*) printf '%s' "IP-CIDR6" ;;
    *) printf '%s' "IP-CIDR" ;;
    esac
}

#######################################
# Дописать маску, если её нет: правила IP-CIDR у Clash всегда с маской, а в
# user_subnets подкопа адрес разрешено писать голым.
# Arguments:
#   value: строка, адрес или подсеть
# Outputs:
#   Подсеть с маской
# Example:
#   _clash_normalize_cidr "1.1.1.1"   # -> 1.1.1.1/32
#######################################
_clash_normalize_cidr() {
    case "$1" in
    */*) printf '%s' "$1" ;;
    *:*) printf '%s/128' "$1" ;;
    *) printf '%s/32' "$1" ;;
    esac
}

#######################################
# Нужен ли правилу флаг no-resolve.
# Без него Clash резолвит домен, чтобы проверить его адрес по IP-правилу, -
# в режиме fake-ip это лишний круг и лишняя задержка. Апстрим включает
# резолв только по отдельной опции секции (resolve_real_ip_for_routing), так
# что и здесь он включается ровно ей.
# Arguments:
#   section: строка, имя секции подкопа
# Outputs:
#   "true" если резолв не нужен, иначе пустая строка
# Example:
#   no_resolve=$(_clash_no_resolve_for_section "main")
#######################################
_clash_no_resolve_for_section() {
    local section="$1"

    local resolve_real_ip
    config_get_bool resolve_real_ip "$section" "resolve_real_ip_for_routing" 0

    if [ "$resolve_real_ip" -eq 1 ]; then
        printf '%s' ""
    else
        printf '%s' "true"
    fi
}

#######################################
# Задать dns.default-nameserver - серверы, которыми clash-rs резолвит имена
# самих DNS-серверов. Это и есть bootstrap подкопа: без него DoH или DoT,
# заданный именем, не поднимется - ядру неоткуда узнать адрес dns.google.
#
# Функции на это поле у менеджера нет, а трогать чужой модуль в этой задаче
# нельзя, поэтому помощник живёт здесь. Появится clash_cm_add_default_nameserver -
# его надо будет убрать вместе с вызовом.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   server: строка, адрес сервера. Пустой ничего не меняет.
# Outputs:
#   Пишет изменённую конфигурацию в stdout
# Example:
#   config=$(_clash_add_default_nameserver "$config" "77.88.8.8")
#######################################
_clash_add_default_nameserver() {
    local config="$1"
    local server="$2"

    echo "$config" | jq \
        --arg server "$server" \
        'if $server == "" then
            .
        else
            .dns["default-nameserver"] = ((.dns["default-nameserver"] // []) + [$server])
        end'
}

## --- точка входа ------------------------------------------------------------

#######################################
# Собрать конфигурацию clash-rs целиком и записать её на диск.
# Полный аналог sing_box_init_config: тот же список шагов в том же порядке.
# Outputs:
#   Пишет конфигурацию в файл, путь берётся из слоя ядра (core_config_path)
# Example:
#   clash_init_config
#######################################
clash_init_config() {
    local config='{"proxies":[],"proxy-groups":[],"rules":[],"rule-providers":{},"dns":{},"profile":{}}'

    clash_configure_log
    clash_configure_inbounds
    clash_configure_proxies
    clash_configure_dns
    clash_configure_rules
    clash_configure_controller
    clash_configure_profile
    clash_save_config
}

## --- лог --------------------------------------------------------------------

#######################################
# Уровень логирования. У sing-box это объект log{}, у clash-rs скаляр
# log-level, поэтому disable_log апстрима выражается уровнем silent.
#######################################
clash_configure_log() {
    log "Configure the log level of a clash-rs configuration"

    local log_level
    config_get log_level "settings" "log_level" "warn"

    config=$(clash_cm_configure_log "$config" false "$(_clash_log_level "$log_level")")
}

## --- инбаунды ---------------------------------------------------------------

#######################################
# Порты инбаундов. Массива inbounds[] с тегами у clash-rs нет - есть скаляры
# верхнего уровня, поэтому tproxy один, mixed один и адрес один на всех.
#######################################
clash_configure_inbounds() {
    log "Configure the inbound ports of a clash-rs configuration"

    config=$(clash_cm_set_tproxy_port "$config" "$SB_TPROXY_INBOUND_PORT")
    config=$(clash_cm_set_bind_address "$config" "$CLASH_BIND_ADDRESS")

    clash_configure_mixed_port
}

#######################################
# Поднять mixed-инбаунд (HTTP и SOCKS на одном порту).
#
# У sing-box mixed-инбаунд заводился на каждую секцию плюс отдельный служебный
# для скачивания списков. У clash-rs mixed-port один на весь конфиг, поэтому
# порт достаётся первому претенденту, а остальные честно отправляются в лог:
# молча потерянный порт выглядел бы как "прокси настроен, но не отвечает".
#
# Первым идёт служебный инбаунд: без него не скачаются списки, а это ломает
# маршрутизацию целиком, тогда как неподнятый mixed секции - потеря удобства.
#######################################
clash_configure_mixed_port() {
    local mixed_port="" mixed_proxy=""

    local download_lists_via_proxy download_lists_via_proxy_section
    config_get_bool download_lists_via_proxy "settings" "download_lists_via_proxy" 0
    if [ "$download_lists_via_proxy" -eq 1 ]; then
        config_get download_lists_via_proxy_section "settings" "download_lists_via_proxy_section"
        mixed_port="$SB_SERVICE_MIXED_INBOUND_PORT"
        mixed_proxy="$(get_outbound_tag_by_section "$download_lists_via_proxy_section")"
    fi

    config_foreach clash_claim_section_mixed_port_handler "section"

    if [ -n "$mixed_port" ]; then
        config=$(clash_cf_add_mixed_inbound_and_route_rule "$config" "$mixed_port" "$mixed_proxy")
    fi
}

#######################################
# Забрать единственный mixed-port под секцию, если он ещё свободен.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_claim_section_mixed_port_handler() {
    local section="$1"

    local mixed_proxy_enabled mixed_proxy_port
    config_get_bool mixed_proxy_enabled "$section" "mixed_proxy_enabled" 0
    [ "$mixed_proxy_enabled" -eq 1 ] || return 0

    config_get mixed_proxy_port "$section" "mixed_proxy_port"
    if [ -z "$mixed_proxy_port" ]; then
        log "Mixed proxy port is not set for the $section section, mixed inbound skipped" "warn"
        return 0
    fi

    if [ -n "$mixed_port" ]; then
        log "clash-rs has a single mixed-port: port $mixed_proxy_port of the $section section is not opened, $mixed_port is already taken" "warn"
        return 0
    fi

    mixed_port="$mixed_proxy_port"
    mixed_proxy="$(get_outbound_tag_by_section "$section")"
}

## --- прокси и группы --------------------------------------------------------

#######################################
# Прокси и группы. Аналог sing_box_configure_outbounds, но короче на один шаг:
# direct-выход у Clash встроенный (DIRECT) и в proxies[] не объявляется.
#######################################
clash_configure_proxies() {
    log "Configure the proxies section of a clash-rs configuration"

    config_foreach clash_configure_proxy_handler "section"
}

#######################################
# Собрать прокси одной секции. Аналог configure_outbound_handler.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_proxy_handler() {
    local section="$1"

    local connection_type
    config_get connection_type "$section" "connection_type"

    case "$connection_type" in
    proxy)
        log "Configuring proxy in proxy connection type for the $section section"
        clash_configure_proxy_section "$section"
        ;;
    vpn)
        log "Configuring proxy in VPN connection type for the $section section"
        clash_configure_vpn_section "$section"
        ;;
    block)
        log "Connection type 'block' detected for the $section section – no proxy will be created (handled via REJECT rules)"
        ;;
    exclusion)
        log "Connection type 'exclusion' detected for the $section section – no proxy will be created (handled via DIRECT rules)"
        ;;
    bypass)
        # Действие из podkop_extras.sh: трафик такой секции не получает
        # tproxy-метку и в ядро не заходит вовсе, поэтому ему нечего давать
        # ни в proxies, ни в rules. Ветка нужна затем, чтобы сборка не
        # обрывалась на незнакомом типе, когда фича доедет до UCI.
        log "Connection type 'bypass' detected for the $section section – traffic does not enter the core"
        ;;
    "")
        # Секцию в LuCI заводят раньше, чем заполняют. Апстрим на этом
        # обрывает запуск, но пустая секция - не повод оставить роутер без
        # интернета: она ничего не описывает, значит её нечего и собирать.
        log "Section '$section' has no connection type, skipping" "warn"
        ;;
    *)
        log "Unknown connection type '$connection_type' for the $section section. Aborted." "fatal"
        exit 1
        ;;
    esac
}

#######################################
# Секция типа proxy: одна ссылка, готовый JSON, selector или urltest.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_proxy_section() {
    local section="$1"

    local proxy_config_type
    config_get proxy_config_type "$section" "proxy_config_type"

    local proxy_string json_proxy udp_over_tcp new_config
    case "$proxy_config_type" in
    url)
        log "Detected proxy configuration type: url" "debug"
        config_get proxy_string "$section" "proxy_string"
        config_get udp_over_tcp "$section" "enable_udp_over_tcp"

        if [ -z "$proxy_string" ]; then
            log "Proxy string is not set. Aborted." "fatal"
            exit 1
        fi

        # Разбор ссылки проверяется, а не принимается на веру: фасад при
        # отказе печатает в stdout пустоту, и без проверки $config молча
        # обнулился бы, а падение вылезло бы через два шага и в другом месте.
        new_config=$(clash_cf_add_proxy_outbound "$config" "$section" "$proxy_string" "$udp_over_tcp") || {
            log "Failed to parse the proxy string of the $section section. Aborted." "fatal"
            exit 1
        }
        config="$new_config"
        ;;
    outbound)
        log "Detected proxy configuration type: outbound" "debug"
        config_get json_proxy "$section" "outbound_json"

        new_config=$(clash_cf_add_json_outbound "$config" "$section" "$json_proxy") || {
            log "Failed to add the JSON proxy of the $section section. Aborted." "fatal"
            exit 1
        }
        config="$new_config"
        ;;
    selector)
        log "Detected proxy configuration type: selector" "debug"
        clash_configure_group_section "$section" "selector"
        ;;
    urltest)
        log "Detected proxy configuration type: urltest" "debug"
        clash_configure_group_section "$section" "urltest"
        ;;
    subscription)
        # Подписка есть только на clash-ветке: у sing-box её нет вовсе.
        # Без этой ветки секция с подпиской попадала бы в *) и убивала сборку.
        log "Detected proxy configuration type: subscription" "debug"
        config=$(clash_sub_configure_section "$config" "$section") || {
            log "Failed to configure subscription for '$section' section. Aborted." "fatal"
            exit 1
        }
        ;;
    *)
        log "Unknown proxy configuration type: '$proxy_config_type'. Aborted." "fatal"
        exit 1
        ;;
    esac
}

#######################################
# Секция типа selector или urltest: список ссылок и группа поверх него.
#
# Имена участников те же, что у sing-box (<секция>-<номер>-out), имя группы
# совпадает с именем секции (<секция>-out) - на него и ссылаются правила.
# У urltest групп две, как в апстриме: url-test с замером задержки и select
# поверх него, чтобы выбор можно было переключить руками через Clash API.
# Arguments:
#   section: строка, имя секции подкопа
#   kind: строка, selector либо urltest
#######################################
clash_configure_group_section() {
    local section="$1"
    local kind="$2"

    local links udp_over_tcp
    config_get udp_over_tcp "$section" "enable_udp_over_tcp"
    if [ "$kind" = "urltest" ]; then
        config_get links "$section" "urltest_proxy_links"
    else
        config_get links "$section" "selector_proxy_links"
    fi

    if [ -z "$links" ]; then
        log "Proxy links are not set for the $section section. Aborted." "fatal"
        exit 1
    fi

    local link index proxy_name proxy_names new_config
    index=1
    proxy_names=""
    for link in $links; do
        new_config=$(clash_cf_add_proxy_outbound "$config" "$section-$index" "$link" "$udp_over_tcp") || {
            log "Failed to parse a proxy link of the $section section. Aborted." "fatal"
            exit 1
        }
        config="$new_config"

        proxy_name="$(get_outbound_tag_by_section "$section-$index")"
        if [ -z "$proxy_names" ]; then
            proxy_names="$proxy_name"
        else
            proxy_names="$proxy_names,$proxy_name"
        fi
        index=$((index + 1))
    done

    local group_name urltest_name
    group_name="$(get_outbound_tag_by_section "$section")"

    if [ "$kind" = "urltest" ]; then
        local check_interval tolerance testing_url
        config_get check_interval "$section" "urltest_check_interval" "3m"
        config_get tolerance "$section" "urltest_tolerance" 50
        config_get testing_url "$section" "urltest_testing_url" "https://www.gstatic.com/generate_204"

        urltest_name="$(get_outbound_tag_by_section "$section-urltest")"
        config=$(
            clash_cm_add_urltest_group "$config" "$urltest_name" \
                "$(_clash_json_array_from_commas "$proxy_names")" \
                "$testing_url" "$(clash_rs_interval_to_seconds "$check_interval")" "$tolerance"
        )
        config=$(
            clash_cm_add_select_group "$config" "$group_name" \
                "$(_clash_json_array_from_commas "$proxy_names,$urltest_name")"
        )
    else
        config=$(
            clash_cm_add_select_group "$config" "$group_name" \
                "$(_clash_json_array_from_commas "$proxy_names")"
        )
    fi
}

#######################################
# Секция типа vpn: трафик уходит в интерфейс, а не в прокси.
#
# У sing-box для этого заводился direct-выход с bind_interface. У Clash
# привязка к интерфейсу - поле самого прокси (см. docs/mapping.md), поэтому
# заводим прокси типа direct и вешаем interface-name на него: иначе правилам
# нечего было бы называть целью.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_vpn_section() {
    local section="$1"

    local interface_name domain_resolver_enabled
    config_get interface_name "$section" "interface"
    config_get_bool domain_resolver_enabled "$section" "domain_resolver_enabled" 0

    if [ -z "$interface_name" ]; then
        log "VPN interface is not set. Aborted." "fatal"
        exit 1
    fi

    if [ "$domain_resolver_enabled" -eq 1 ]; then
        # У sing-box у выхода свой domain_resolver. У clash-rs резолвер
        # привязывается к имени (dns.nameserver-policy), а не к выходу, и
        # выбрать сервер "для всего, что уходит в этот интерфейс" нельзя.
        log "Per-outbound domain resolver of the $section section is not expressible in clash-rs, skipped" "warn"
    fi

    local proxy_name
    proxy_name="$(get_outbound_tag_by_section "$section")"

    config=$(clash_cm_add_raw_proxy "$config" "$proxy_name" '{"type":"direct"}')
    config=$(clash_cf_set_proxy_interface "$config" "$section" "$interface_name")
}

## --- DNS --------------------------------------------------------------------

#######################################
# Раздел dns. Отличий от sing-box два, и оба структурные:
#   - fake-ip не сервер, а режим резолвера, и работает он на все имена сразу;
#   - отдельный direct-инбаунд на 127.0.0.42:53 заменяется на dns.listen.
#######################################
clash_configure_dns() {
    log "Configure the DNS section of a clash-rs configuration"

    config=$(clash_cm_configure_dns "$config" true "$SB_DNS_INBOUND_ADDRESS:$SB_DNS_INBOUND_PORT" false)
    config=$(clash_cm_enable_fakeip "$config" "$SB_FAKEIP_INET4_RANGE")

    log "Adding DNS servers" "debug"
    local dns_type dns_server bootstrap_dns_server new_config
    config_get dns_type "settings" "dns_type" "doh"
    config_get dns_server "settings" "dns_server" "1.1.1.1"
    config_get bootstrap_dns_server "settings" "bootstrap_dns_server" "77.88.8.8"

    new_config=$(clash_cf_add_dns_server "$config" "$dns_type" "$dns_server") || {
        log "Failed to add the '$dns_type' DNS server '$dns_server'. Aborted." "fatal"
        exit 1
    }
    config="$new_config"

    config=$(_clash_add_default_nameserver "$config" "$bootstrap_dns_server")

    # Локальные имена решает dnsmasq, и поддельный адрес им только помешал бы:
    # на fake-ip нельзя ни зайти по SSH на соседа, ни открыть веб-морду NAS.
    log "Adding fake-ip filters" "debug"
    config=$(clash_cm_add_fakeip_filter "$config" "+.lan")
    config=$(clash_cm_add_fakeip_filter "$config" "+.local")

    local rewrite_ttl
    config_get rewrite_ttl "settings" "dns_rewrite_ttl" "60"
    if [ -n "$rewrite_ttl" ]; then
        # У sing-box TTL ответов переписывался правилом fakeip. У clash-rs
        # срок жизни поддельной записи ядро выбирает само.
        log "DNS rewrite TTL ($rewrite_ttl) is not configurable in clash-rs, skipped" "debug"
    fi

    # Запрет ответов типа HTTPS (у sing-box - dns reject rule на query_type)
    # в clash-rs не выражается: правила DNS у него по именам, а не по типу
    # запроса. Домен-канарейка Firefox отправляется в REJECT правилом
    # маршрутизации, это делает clash_configure_rules.
    log "Rejecting DNS queries by record type is not expressible in clash-rs, skipped" "debug"
}

## --- правила маршрутизации --------------------------------------------------

#######################################
# Раздел rules. Порядок здесь и есть маршрутизация: выигрывает первое
# совпавшее правило, поэтому шаги идут ровно в том же порядке, в каком
# sing_box_configure_route наполняет route.rules.
#
#   1. служебные правила подкопа
#   2. списки block-секций      -> REJECT
#   3. списки exclusion-секций  -> DIRECT
#   4. routing_excluded_ips     -> DIRECT
#   5. fully_routed_ips секций  -> прокси секции
#   6. списки секций proxy/vpn  -> прокси секции, в порядке объявления в UCI
#   7. финальный MATCH
#
# Пункты 2 и 3 стоят выше адресов устройств не по недосмотру: у sing-box
# общие правила reject и exclusion создаются до правил по источнику и
# перекрывают их так же.
#######################################
clash_configure_rules() {
    log "Configure the rules section of a clash-rs configuration"

    config=$(clash_cm_configure_route "$config" "rule")

    clash_configure_service_rules

    log "Processing block sections" "debug"
    config_foreach clash_configure_block_rules_handler "section"

    log "Processing exclusion sections" "debug"
    config_foreach clash_configure_exclusion_rules_handler "section"

    local routing_excluded_ips
    config_get routing_excluded_ips "settings" "routing_excluded_ips"
    if [ -n "$routing_excluded_ips" ]; then
        log "Processing routing excluded IPs" "debug"
        config_list_foreach "settings" "routing_excluded_ips" clash_exclude_source_ip_handler
    fi

    log "Processing fully routed IPs" "debug"
    config_foreach clash_include_source_ips_handler "section"

    log "Processing section lists" "debug"
    config_foreach clash_configure_section_rules_handler "section"

    clash_configure_final_rule
}

#######################################
# Служебные правила подкопа: они должны стоять выше пользовательских списков,
# иначе список секции перехватит их первым.
#######################################
clash_configure_service_rules() {
    # Канарейка Firefox: пока домен отвечает, браузер включает свой DoH и
    # уходит мимо маршрутизации подкопа целиком.
    config=$(clash_cf_add_single_key_reject_rule "$config" "domain_suffix" "use-application-dns.net")

    local disable_quic
    config_get_bool disable_quic "settings" "disable_quic" 0
    if [ "$disable_quic" -eq 1 ]; then
        # У sing-box QUIC отсекался правилом по протоколу. Правила Clash -
        # строки с одним признаком, "udp и порт 443" в них не записать, а
        # запрет одного лишь порта 443 убил бы весь HTTPS.
        log "QUIC blocking is not expressible in clash-rs rules, skipped" "warn"
    fi

    # Проверка "через какой адрес мы выходим наружу" должна идти в первую
    # секцию с прокси, а не туда, куда попадёт по спискам.
    local first_section first_proxy
    first_section="$(get_first_outbound_section)"
    if [ -n "$first_section" ]; then
        first_proxy="$(get_outbound_tag_by_section "$first_section")"
        config=$(clash_cf_proxy_domain "$config" "$CHECK_PROXY_IP_DOMAIN" "$first_proxy")
    else
        log "No proxy or VPN section found, the check proxy domain rule is not created" "warn"
    fi

    # Подмены порта у назначения в clash-rs нет; функция фасада только пишет
    # об этом в лог и возвращает конфиг нетронутым.
    config=$(clash_cf_override_domain_port "$config" "$FAKEIP_TEST_DOMAIN" 8443)
}

#######################################
# Списки block-секции: всё, что в них попало, отвергается.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_block_rules_handler() {
    local section="$1"

    local connection_type
    config_get connection_type "$section" "connection_type"
    [ "$connection_type" = "block" ] || return 0

    clash_configure_routing_for_section_lists "$section" "REJECT"
}

#######################################
# Списки exclusion-секции: всё, что в них попало, идёт напрямую.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_exclusion_rules_handler() {
    local section="$1"

    local connection_type
    config_get connection_type "$section" "connection_type"
    [ "$connection_type" = "exclusion" ] || return 0

    clash_configure_routing_for_section_lists "$section" "DIRECT"
}

#######################################
# Списки секции proxy или vpn: всё, что в них попало, идёт в прокси секции.
# Секции block и exclusion уже разобраны выше и здесь пропускаются.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_configure_section_rules_handler() {
    local section="$1"

    local connection_type
    config_get connection_type "$section" "connection_type"

    case "$connection_type" in
    proxy | vpn)
        clash_configure_routing_for_section_lists "$section" "$(get_outbound_tag_by_section "$section")"
        ;;
    *) ;;
    esac
}

#######################################
# Адреса устройств, которые целиком заворачиваются в секцию.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
clash_include_source_ips_handler() {
    local section="$1"

    local fully_routed_ips connection_type
    config_get fully_routed_ips "$section" "fully_routed_ips"
    [ -n "$fully_routed_ips" ] || return 0

    config_get connection_type "$section" "connection_type"
    case "$connection_type" in
    proxy | vpn) ;;
    *)
        log "Section '$section' has fully routed IPs but no proxy, they are ignored" "warn"
        return 0
        ;;
    esac

    config_list_foreach "$section" "fully_routed_ips" clash_include_source_ip_handler \
        "$(get_outbound_tag_by_section "$section")"
}

#######################################
# Одно устройство - одно правило по адресу источника.
# Заодно, как и в апстриме, адрес добавляется в nft: без метки трафик до ядра
# просто не доедет, и правило некому будет применить.
# Arguments:
#   source_ip: строка, адрес устройства
#   target: строка, цель правила
#######################################
clash_include_source_ip_handler() {
    local source_ip="$1"
    local target="$2"

    nft_list_all_traffic_from_ip "$source_ip"
    config=$(clash_cm_add_rule "$config" "SRC-IP-CIDR" "$(_clash_normalize_cidr "$source_ip")" "$target")
}

#######################################
# Одно устройство, которое подкоп не трогает вовсе.
# Arguments:
#   source_ip: строка, адрес устройства
#######################################
clash_exclude_source_ip_handler() {
    local source_ip="$1"

    config=$(clash_cm_add_rule "$config" "SRC-IP-CIDR" "$(_clash_normalize_cidr "$source_ip")" "DIRECT")
}

#######################################
# Правила по всем спискам одной секции. Аналог configure_routing_for_section_lists.
#
# Списки разбираются в том же порядке, что и в апстриме: сообщество, домены и
# подсети пользователя, локальные файлы, удалённые файлы. Внутри секции
# порядок роли почти не играет (цель у всех правил одна), но одинаковый
# порядок делает два конфига сравнимыми глазами.
#
# Arguments:
#   section: строка, имя секции подкопа
#   target: строка, цель правил: имя прокси, DIRECT или REJECT
#######################################
clash_configure_routing_for_section_lists() {
    local section="$1"
    local target="$2"

    log "Configuring routing for '$section' section"
    if ! section_has_enabled_lists "$section"; then
        log "Section '$section' does not have any enabled list, skipping..." "warn"
        return 0
    fi

    local community_lists user_domain_list_type user_subnet_list_type local_domain_lists local_subnet_lists \
        remote_domain_lists remote_subnet_lists no_resolve
    config_get community_lists "$section" "community_lists"
    config_get user_domain_list_type "$section" "user_domain_list_type" "disabled"
    config_get user_subnet_list_type "$section" "user_subnet_list_type" "disabled"
    config_get local_domain_lists "$section" "local_domain_lists"
    config_get local_subnet_lists "$section" "local_subnet_lists"
    config_get remote_domain_lists "$section" "remote_domain_lists"
    config_get remote_subnet_lists "$section" "remote_subnet_lists"
    no_resolve="$(_clash_no_resolve_for_section "$section")"

    if [ -n "$community_lists" ]; then
        log "Processing community list routing rules for '$section' section"
        config_list_foreach "$section" "community_lists" clash_configure_community_list_handler "$target"
    fi

    if [ "$user_domain_list_type" != "disabled" ]; then
        log "Processing user domains routing rules for '$section' section"
        clash_configure_user_domain_list "$section" "$target"
    fi

    if [ "$user_subnet_list_type" != "disabled" ]; then
        log "Processing user subnets routing rules for '$section' section"
        clash_configure_user_subnet_list "$section" "$target" "$no_resolve"
    fi

    if [ -n "$local_domain_lists" ]; then
        log "Processing local domains routing rules for '$section' section"
        config_list_foreach "$section" "local_domain_lists" clash_configure_local_list_handler \
            "domains" "$section" "$target" "$no_resolve"
    fi

    if [ -n "$local_subnet_lists" ]; then
        log "Processing local subnets routing rules for '$section' section"
        config_list_foreach "$section" "local_subnet_lists" clash_configure_local_list_handler \
            "subnets" "$section" "$target" "$no_resolve"
    fi

    if [ -n "$remote_domain_lists" ]; then
        log "Processing remote domains routing rules for '$section' section"
        config_list_foreach "$section" "remote_domain_lists" clash_configure_remote_list_handler \
            "domains" "$section" "$target" "$no_resolve"
    fi

    if [ -n "$remote_subnet_lists" ]; then
        log "Processing remote subnets routing rules for '$section' section"
        config_list_foreach "$section" "remote_subnet_lists" clash_configure_remote_list_handler \
            "subnets" "$section" "$target" "$no_resolve"
    fi
}

#######################################
# Список сообщества. Форматом занимается переключатель наборов правил: у
# sing-box это .srs, у clash-rs - провайдер плюс строка RULE-SET.
# Arguments:
#   service: строка, имя сервиса из COMMUNITY_SERVICES
#   target: строка, цель правила
#######################################
clash_configure_community_list_handler() {
    local service="$1"
    local target="$2"

    local update_interval new_config
    config_get update_interval "settings" "update_interval" "1d"

    new_config=$(ruleset_add_community "$config" "$service" "$target" "$update_interval") || {
        log "Community list '$service' is not available for clash-rs, skipped" "error"
        return 1
    }
    config="$new_config"
}

#######################################
# Домены, вписанные руками. Провайдер правил ради десятка имён заводить
# незачем - это ровно те же правила, только через файл на диске.
# Arguments:
#   section: строка, имя секции подкопа
#   target: строка, цель правил
#######################################
clash_configure_user_domain_list() {
    local section="$1"
    local target="$2"

    local user_domain_list_type items item
    config_get user_domain_list_type "$section" "user_domain_list_type"
    case "$user_domain_list_type" in
    dynamic) config_get items "$section" "user_domains" ;;
    text) config_get items "$section" "user_domains_text" ;;
    esac

    items="$(parse_domain_or_subnet_string_to_commas_string "$items" "domains")"
    for item in $(printf '%s' "$items" | tr ',' ' '); do
        # domain_suffix у sing-box ловит и сам домен, и всё под ним - у Clash
        # это DOMAIN-SUFFIX с той же семантикой
        config=$(clash_cm_add_rule "$config" "DOMAIN-SUFFIX" "$item" "$target")
    done
}

#######################################
# Подсети, вписанные руками. Они же уезжают в nft: без этого трафик к ним не
# получит метку и до ядра не доедет.
# Arguments:
#   section: строка, имя секции подкопа
#   target: строка, цель правил
#   no_resolve: строка, "true" если резолвить домены ради IP-правил не надо
#######################################
clash_configure_user_subnet_list() {
    local section="$1"
    local target="$2"
    local no_resolve="$3"

    local user_subnet_list_type items item
    config_get user_subnet_list_type "$section" "user_subnet_list_type"
    case "$user_subnet_list_type" in
    dynamic) config_get items "$section" "user_subnets" ;;
    text) config_get items "$section" "user_subnets_text" ;;
    esac

    items="$(parse_domain_or_subnet_string_to_commas_string "$items" "subnets")"
    for item in $(printf '%s' "$items" | tr ',' ' '); do
        config=$(
            clash_cm_add_rule "$config" "$(_clash_ip_rule_type "$item")" \
                "$(_clash_normalize_cidr "$item")" "$target" "$no_resolve"
        )
    done

    [ -n "$items" ] && nft_add_set_elements "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME" "$items"

    return 0
}

#######################################
# Список из файла на роутере.
# Сырой список сначала превращается в payload (домены получают "+.", адреса -
# маску), и только потом объявляется провайдером: behavior определяется по
# содержимому, а не по имени файла - провайдер с неверным behavior clash-rs
# не примет.
# Arguments:
#   filepath: строка, путь к файлу со списком
#   type: строка, domains либо subnets
#   section: строка, имя секции подкопа
#   target: строка, цель правила
#   no_resolve: строка, "true" если резолвить домены ради IP-правил не надо
#######################################
clash_configure_local_list_handler() {
    local filepath="$1"
    local type="$2"
    local section="$3"
    local target="$4"
    local no_resolve="$5"

    if ! file_exists "$filepath"; then
        log "Local $type list file $filepath not found" "error"
        return 1
    fi

    clash_add_prepared_ruleset "$section" "$(url_get_basename "$filepath")" "local-$type" "$filepath" "" \
        "$target" "$no_resolve" || return 1

    if [ "$type" = "subnets" ]; then
        nft_add_set_elements_from_file_chunked "$filepath" "$NFT_TABLE_NAME" "$NFT_COMMON_SET_NAME"
    fi
}

#######################################
# Список по ссылке.
# Скачиванием занимается подкоп, а не ядро: так список успевает пройти чистку
# и конвертацию, и так ретраи при 429 от github остаются под нашим контролем
# (см. clash_rs_download_list).
# Arguments:
#   url: строка, ссылка на список
#   type: строка, domains либо subnets
#   section: строка, имя секции подкопа
#   target: строка, цель правила
#   no_resolve: строка, "true" если резолвить домены ради IP-правил не надо
#######################################
clash_configure_remote_list_handler() {
    local url="$1"
    local type="$2"
    local section="$3"
    local target="$4"
    local no_resolve="$5"

    local file_extension
    file_extension=$(url_get_file_extension "$url")
    case "$file_extension" in
    srs | json)
        # .srs - бинарный формат sing-box, .json - его же source-набор;
        # clash-rs не читает ни того, ни другого (см. docs/mapping.md)
        log "Remote list $url is in '$file_extension' format, which clash-rs cannot read, skipped" "error"
        return 1
        ;;
    esac

    clash_add_prepared_ruleset "$section" "$(url_get_basename "$url")" "remote-$type" "" "$url" \
        "$target" "$no_resolve"
}

#######################################
# Общая часть локальных и удалённых списков: подготовить payload, объявить
# провайдера и сослаться на него правилом.
# Arguments:
#   section: строка, имя секции подкопа
#   name: строка, имя списка (обычно имя файла)
#   type: строка, вид набора для имени провайдера
#   filepath: строка, путь к исходному файлу (для локального списка)
#   url: строка, ссылка на список (для удалённого)
#   target: строка, цель правила
#   no_resolve: строка, "true" если резолвить домены ради IP-правил не надо
# Returns:
#   1 если список подготовить не удалось
#######################################
clash_add_prepared_ruleset() {
    local section="$1"
    local name="$2"
    local type="$3"
    local filepath="$4"
    local url="$5"
    local target="$6"
    local no_resolve="$7"

    local provider_name payload_path behavior
    provider_name="$(clash_rs_provider_name "$section" "$name" "$type")"
    payload_path="$(ruleset_folder)/$provider_name.lst"

    mkdir -p "$(ruleset_folder)"

    if [ -n "$url" ]; then
        behavior="$(clash_rs_prepare_remote_list "$url" "$payload_path" "$CLASH_RULE_PROVIDER_FORMAT" \
            "$(get_service_proxy_address)")"
    else
        behavior="$(clash_rs_convert_list "$filepath" "$payload_path" "$CLASH_RULE_PROVIDER_FORMAT")"
    fi

    if [ -z "$behavior" ]; then
        log "Failed to prepare the rule set '$provider_name', skipped" "error"
        return 1
    fi

    config=$(
        clash_cm_add_file_rule_provider "$config" "$provider_name" "$behavior" \
            "$CLASH_RULE_PROVIDER_FORMAT" "$payload_path"
    )

    # no-resolve имеет смысл только там, где в наборе лежат адреса: в наборе
    # с доменами резолвить нечего, и флаг только сбивал бы с толку
    if [ "$behavior" = "domain" ]; then
        no_resolve=""
    fi

    config=$(clash_cm_add_ruleset_rule "$config" "$provider_name" "$target" "$no_resolve")
}

#######################################
# Финальное правило MATCH - то, куда идёт всё не совпавшее. Аналог route.final.
#
# Обычно это DIRECT. Если у какой-то секции включён global_proxy, целью
# становится её прокси: именно так глобальный режим и выражается в Clash -
# хвостом маршрутизации, а не отменой правил. Правила секций к этому моменту
# уже построены, включая правила самой глобальной секции.
#######################################
clash_configure_final_rule() {
    local global_section target
    global_section="$(clash_get_global_proxy_section)"

    if [ -n "$global_section" ]; then
        target="$(get_outbound_tag_by_section "$global_section")"
        log "Global proxy mode is enabled for the '$global_section' section: unmatched traffic goes to $target"
    else
        target="DIRECT"
    fi

    config=$(clash_cm_add_match_rule "$config" "$target")
}

#######################################
# Секция, в которую уходит весь неопознанный трафик.
# Глобальной может быть только одна секция; если их несколько, берётся первая
# по порядку объявления, остальные отправляются в лог.
# Outputs:
#   Имя секции либо пустая строка
# Example:
#   section="$(clash_get_global_proxy_section)"
#######################################
clash_get_global_proxy_section() {
    local global_section=""

    config_foreach _clash_determine_global_proxy_section "section"

    printf '%s' "$global_section"
}

#######################################
# Обработчик перебора секций для clash_get_global_proxy_section.
# Arguments:
#   section: строка, имя секции подкопа
#######################################
_clash_determine_global_proxy_section() {
    local section="$1"

    local global_proxy connection_type
    config_get_bool global_proxy "$section" "global_proxy" 0
    [ "$global_proxy" -eq 1 ] || return 0

    config_get connection_type "$section" "connection_type"
    case "$connection_type" in
    proxy | vpn) ;;
    *)
        log "Section '$section' is marked as global proxy but has no proxy, ignored" "warn"
        return 0
        ;;
    esac

    if [ -n "$global_section" ]; then
        log "Section '$section' is also marked as global proxy, but '$global_section' is already the global one" "warn"
        return 0
    fi

    global_section="$section"
}

## --- Clash API и profile ----------------------------------------------------

#######################################
# Clash API. У sing-box он жил в experimental.clash_api, у clash-rs это поля
# верхнего уровня и штатная часть конфига.
#######################################
#######################################
# Придумать секрет для Clash API.
#
# Берём из системного источника случайности, а не из $RANDOM: последний в ash
# даёт 15 бит, то есть тридцать тысяч вариантов - перебрать такой секрет в
# локальной сети дело секунд.
# Outputs:
#   строка шестнадцатеричных символов
#######################################
clash_generate_api_secret() {
    local secret

    secret=$(head -c 16 /dev/urandom 2> /dev/null | hexdump -v -e '/1 "%02x"' 2> /dev/null)

    # hexdump есть не в каждой сборке busybox
    [ -n "$secret" ] || secret=$(head -c 16 /dev/urandom 2> /dev/null | od -An -tx1 2> /dev/null | tr -d " \n")

    # последний рубеж: uuid есть всегда, где есть /proc
    [ -n "$secret" ] || secret=$(tr -d - < /proc/sys/kernel/random/uuid 2> /dev/null)

    printf '%s' "$secret"
}
clash_configure_controller() {
    log "Configuring Clash API"

    local enable_yacd enable_yacd_wan_access controller_address external_ui yacd_secret_key
    config_get_bool enable_yacd "settings" "enable_yacd" 0
    config_get_bool enable_yacd_wan_access "settings" "enable_yacd_wan_access" 0
    config_get yacd_secret_key "settings" "yacd_secret_key"

    if [ "$enable_yacd" -eq 1 ] && [ "$enable_yacd_wan_access" -eq 1 ]; then
        controller_address="0.0.0.0"
    else
        controller_address="$(get_service_listen_address)"
        if [ -z "$controller_address" ]; then
            log "Could not determine the listening IP address for the Clash API controller. It will run only on localhost." "warn"
            controller_address="127.0.0.1"
        fi
    fi

    external_ui=""
    if [ "$enable_yacd" -eq 1 ]; then
        log "YACD is enabled, enabling Clash API with downloadable YACD" "debug"
        external_ui="ui"
    else
        log "YACD is disabled, enabling Clash API in online mode" "debug"
    fi

    # Секрет ставится всегда, когда он задан, а не только вместе с YACD:
    # дашборд ходит в тот же API, и открытый API на адресе LAN - это чужая
    # возможность переключить выход.
    # Если секрета нет, а адрес нелокальный - придумываем его сами.
    #
    # Проверено на живом clash-rs 0.10.8: он не поднимает API на нелокальном
    # адресе без секрета вовсе и пишет об этом ошибкой:
    #
    #   API server is listening on a non-loopback address without a secret
    #   API server failed to start
    #
    # sing-box такое разрешает, поэтому у апстрима вопроса не возникало. А без
    # секрета на clash-rs молча отваливается весь дашборд подкопа: он ходит в
    # тот же API.
    #
    # Придуманный секрет сохраняем в podkop.settings.yacd_secret_key, иначе о
    # нём не узнает интерфейс и будет получать 401 вместо данных.
    if [ -z "$yacd_secret_key" ] && [ "$controller_address" != "127.0.0.1" ]; then
        yacd_secret_key="$(clash_generate_api_secret)"
        uci set "podkop.settings.yacd_secret_key=$yacd_secret_key"
        uci commit podkop
        log "Clash API secret generated: clash-rs refuses a non-loopback API without one" "warn"
    fi

    config=$(
        clash_cm_configure_clash_api "$config" \
            "$controller_address:$SB_CLASH_API_CONTROLLER_PORT" "$external_ui" "$yacd_secret_key"
    )

    # CORS - второе требование clash-rs к нелокальному API, помимо секрета.
    # Без него он тоже отказывается стартовать, и это выяснилось только на
    # живом ядре: сначала он ругается на отсутствие секрета, а когда секрет
    # появляется - на отсутствие CORS.
    #
    # Ставим "*", потому что настоящей защитой служит секрет: дашборд ходит с
    # адреса роутера, но у пользователя это может быть и IP, и имя хоста, и
    # любой из них через LuCI - перечислить все заранее нельзя.
    config=$(clash_cm_set_cors_origins "$config" "*")
}

#######################################
# Раздел profile. Заменяет experimental.cache_file у sing-box: путь ядро
# выбирает само, настраивается только что помнить между запусками.
#######################################
clash_configure_profile() {
    log "Configuring profile"

    config=$(clash_cm_configure_profile "$config" true true)
}

## --- запись на диск ---------------------------------------------------------

#######################################
# Записать конфигурацию. Как и в апстриме, сначала во временный файл, затем
# проверка ядром, и только потом подмена рабочего файла - и то лишь если он
# действительно изменился: лишняя запись во flash сокращает ей жизнь.
#######################################
clash_save_config() {
    local config_path temp_file_path current_config_hash temp_config_hash
    config_path="$(core_config_path)"
    temp_file_path="$(mktemp)"

    log "Save clash-rs temporary config to $temp_file_path" "debug"
    clash_cm_save_config_to_file "$config" "$temp_file_path"

    clash_config_check "$temp_file_path"

    current_config_hash=$(md5sum "$config_path" 2> /dev/null | awk '{print $1}')
    temp_config_hash=$(md5sum "$temp_file_path" | awk '{print $1}')
    log "Current clash-rs config hash: $current_config_hash" "debug"
    log "Temporary clash-rs config hash: $temp_config_hash" "debug"
    if [ "$current_config_hash" != "$temp_config_hash" ]; then
        log "clash-rs configuration has changed and will be updated"
        mkdir -p "$(dirname "$config_path")"
        mv "$temp_file_path" "$config_path"
    else
        log "clash-rs configuration is unchanged"
        rm "$temp_file_path"
    fi
}

#######################################
# Проверить конфигурацию ядром. Команда проверки у ядер разная, поэтому она
# спрятана в слой ядра.
# Arguments:
#   config_path: строка, путь к проверяемому файлу
#######################################
clash_config_check() {
    local config_path="$1"

    if ! core_check_config "$config_path"; then
        log "clash-rs configuration $config_path is invalid. Aborted." "fatal"
        exit 1
    fi
}
