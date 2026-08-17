# Переключатель наборов правил между ядрами.
#
# Форматы у ядер несовместимы:
#   sing-box  - бинарные .srs, скачивает их сам по ссылке из конфига
#   clash-rs  - .srs не читает вовсе, нужны текстовые списки в rule-providers
#
# Оба формата поддерживаются одновременно и остаются рабочими: реализации
# лежат в rulesets.sh (.srs) и clash_rulesets.sh (текст), а этот файл только
# выбирает нужную по активному ядру. Логику ни одной из них он не дублирует.
#
# Точка, где подкоп решал формат, была ровно одна - строка с
# "$SRS_MAIN_URL/$tag.srs" в configure_community_list_handler. Поэтому и
# переключатель узкий: подменяется не весь слой списков, а способ получить
# набор и способ сослаться на него из правила.
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- формат ----------------------------------------------------------------

#######################################
# Формат наборов правил для активного ядра.
# Outputs:
#   srs | text
#######################################
ruleset_format() {
	if core_is_clash; then printf 'text'; else printf 'srs'; fi
}

#######################################
# Ссылка на список сообщества под нужный формат.
#
# У sing-box это готовый бинарник из релизов, у clash-rs - сырой текстовый
# список из дерева репозитория. Источник данных один и тот же, отличается
# только представление, поэтому и функция одна.
#
# Arguments:
#   service: имя сервиса из COMMUNITY_SERVICES (telegram, russia_inside, ...)
#   kind:    domains | subnets (нужен только текстовому формату)
# Outputs:
#   URL
# Returns:
#   1 если для текстового формата такого списка нет
#######################################
ruleset_community_url() {
	local service="$1" kind="${2:-domains}"

	if [ "$(ruleset_format)" = "srs" ]; then
		printf '%s/%s.srs' "$SRS_MAIN_URL" "$service"
		return 0
	fi

	clash_rs_list_url "$service" "$kind"
}

## --- подключение набора к правилу -------------------------------------------

#######################################
# Добавить набор правил сообщества и сослаться на него из правила маршрута.
#
# Формы вызова у ядер разные настолько, что общего кода почти нет:
#   sing-box - удалённый ruleset в конфиге плюс патч правила и правила DNS
#   clash-rs - провайдер правил плюс строка RULE-SET,<имя>,<цель>
#
# Отдельно про DNS: у sing-box набор надо продублировать в правило fakeip,
# иначе домены из списка не отправятся в поддельные адреса. У clash-rs
# режим fake-ip работает поверх всех правил разом, дублировать нечего.
#
# Arguments:
#   config:     конфиг строкой
#   service:    имя сервиса сообщества
#   rule_tag:   тег правила маршрута (sing-box) либо цель (clash-rs)
#   interval:   период обновления, например 1d
#   detour:     тег выхода для скачивания (только sing-box)
# Outputs:
#   изменённый конфиг
#######################################
ruleset_add_community() {
	local config="$1" service="$2" rule_tag="$3" interval="${4:-1d}" detour="$5"
	local url name

	if core_is_clash; then
		name=$(clash_rs_provider_name "$service")
		url=$(ruleset_community_url "$service" "domains") || return 1
		config=$(clash_cm_add_http_rule_provider "$config" "$name" "domain" "text" \
			"$url" "$(clash_rs_interval_to_seconds "$interval")")
		config=$(clash_cm_add_ruleset_rule "$config" "$name" "$rule_tag")
		printf '%s' "$config"
		return 0
	fi

	url=$(ruleset_community_url "$service")
	config=$(sing_box_cm_add_remote_ruleset "$config" "$service" "binary" "$url" "$detour" "$interval")
	config=$(sing_box_cm_patch_route_rule "$config" "$rule_tag" "rule_set" "$service")
	config=$(sing_box_cm_patch_dns_route_rule "$config" "$SB_FAKEIP_DNS_RULE_TAG" "rule_set" "$service")
	printf '%s' "$config"
}

## --- каталоги ---------------------------------------------------------------

#######################################
# Каталог, куда складываются подготовленные наборы.
# Берётся из слоя ядра, чтобы два ядра не писали в один и тот же путь: при
# переключении остатки чужого формата иначе принимались бы за свои.
#######################################
ruleset_folder() { core_ruleset_folder; }
