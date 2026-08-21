#
# Module: clash_subscriptions.sh
#
# Purpose:
#   Подписки на серверы (Subscription URL) для ветки clash-rs.
#
#   Главное, что нужно понимать про этот файл: здесь НЕТ парсера подписок и
#   не должно появиться. У обоих форков подкопа (netshift, forkop) подписка -
#   это тысяча с лишним строк: скачать тело, разжать gzip, распознать формат
#   (base64-блоб, плоский список ссылок, Xray-JSON), развернуть его в список
#   выходов, сложить кэш на постоянную ФС, завести cron на обновление,
#   написать воркер ретраев на случай "сети ещё нет". Разбор в
#   docs/forks-features.md, фичи 1, 2, 3, 6, 7, 10, 11.
#
#   На clash-rs всего этого не нужно, потому что у ядра есть штатный раздел:
#
#     proxy-providers:
#       main-sub1:
#         type: http
#         url: "https://panel.example/api/sub/<token>"
#         interval: 3600
#         path: /tmp/clash-rs/providers/main-sub1.yaml
#         health-check: {enable: true, url: "...", interval: 300}
#
#   Скачивание, расписание обновления, кэш на диске и проверку живости
#   серверов делает само ядро. Наша работа - собрать этот кусок конфига и
#   сослаться на провайдера из proxy-group. Отсюда размер модуля.
#
#   Работает это потому, что панели отдают формат по заголовку User-Agent:
#   с UA "clash-meta" remnawave, marzban и 3x-ui возвращают готовый
#   Clash-YAML, а clash-rs читает тело провайдера ТОЛЬКО как Clash-YAML с
#   ключом proxies: (ProviderScheme в proxy_set_provider.rs). Поэтому UA -
#   не косметика, а условие работоспособности, и он вынесен в настройку.
#
#   Если панель Clash-формат не отдаёт вовсе, наше дело - внятно сказать об
#   этом (clash_sub_check_provider_file), а не разбирать тело самим.
#   Фолбэк-парсер для base64 и Xray-JSON сознательно отложен отдельной
#   задачей: он общий для обоих ядер и по объёму больше всего остального.
#
# Conventions:
#   - все функции названы clash_sub_*, служебные - _clash_sub_*
#   - сборка JSON отделена от чтения настроек и от файловой системы:
#     clash_sub_provider_json и clash_sub_health_check_json чистые, их можно
#     звать откуда угодно; UCI трогает только clash_sub_configure_section
#   - функция, меняющая конфиг, принимает его строкой и печатает изменённый
#     в stdout - тот же приём, что у clash_cm_* (см. clash_config_manager.sh)
#   - имена полей в kebab-case: именно так их ждёт serde в clash-rs
#   - булевы аргументы передаются строками; истиной считаются "true" и "1",
#     потому что config_get_bool отдаёт 1/0, а менеджер ждёт true/false
#   - пустой необязательный аргумент означает "поле не задавать"
#   - при активном sing-box модуль не делает НИЧЕГО: подписок там нет,
#     конфиг возвращается нетронутым
#
# Опции UCI секции (все необязательные, кроме первой):
#
#   list subscription_url             одна или несколько ссылок подписки.
#                                     Скалярная форма (option) тоже работает
#   subscription_update_interval      как часто ядро перекачивает подписку:
#                                     30m 1h 3h 6h 12h 1d. По умолчанию 1h
#
#   Опций фильтрации и User-Agent здесь НЕТ намеренно. У http-провайдера
#   clash-rs 0.10.8 всего четыре поля (url, interval, path, health-check), а
#   UA зашит в само ядро константой "clash-rs/<версия>" и не переопределяется.
#   Панели обычно смотрят на подстроку "clash" и отдают нужный формат, но
#   повлиять на это мы не можем.
#   subscription_group_type           urltest (по умолчанию) либо selector
#   subscription_test_url             чем меряется задержка
#   subscription_check_interval       как часто, по умолчанию 5m
#   subscription_tolerance            допуск url-test в мс, по умолчанию 50
#   subscription_lazy                 не проверять неиспользуемое
#   subscription_health_check         0 - выключить проверку живости
#
#   Фильтры - это регулярные выражения ядра (подстрока их частный случай).
#   Отбор делает ядро, а не мы: у провайдера clash-rs для этого есть поля
#   filter и exclude-filter. Обратите внимание, что у proxy-group такого
#   поля в clash-rs 0.10.8 НЕТ (в отличие от mihomo), так что фильтровать
#   можно только на уровне провайдера - и именно поэтому фильтр здесь
#   один на все подписки секции.
#
# Usage:
#   Подключить в своём ash-скрипте после менеджера, списков и слоя ядра:
#     . /usr/lib/podkop/clash_subscriptions.sh
#
#   Секция с proxy_config_type=subscription собирается одним вызовом:
#     config=$(clash_sub_configure_section "$config" "$section") || ...
#
# Depends on:
#   core.sh            core_is_clash, core_tmp_folder
#   clash_rulesets.sh  clash_rs_interval_to_seconds
#   helpers.sh         get_outbound_tag_by_section (необязательно)
#   logging.sh         log (необязательно)
#   /lib/functions.sh  config_get (только в clash_sub_configure_section)
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- параметры --------------------------------------------------------------
# Всё через :- чтобы переопределялось снаружи: из подкопа, из тестов или
# руками при отладке на роутере.

# UA по умолчанию. Именно он превращает подписку в три строки конфига:
# панель, увидев клэшевый клиент, отдаёт Clash-YAML, который ядро съест само.
CLASH_SUB_DEFAULT_USER_AGENT="${CLASH_SUB_DEFAULT_USER_AGENT:-clash-meta}"

# Как часто ядро перекачивает подписку. Час - компромисс: панели меняют
# список узлов редко, а бить в них каждые несколько минут с тысячи роутеров
# невежливо.
CLASH_SUB_DEFAULT_INTERVAL="${CLASH_SUB_DEFAULT_INTERVAL:-1h}"

# Проверка живости. URL тот же, что у urltest-секций в clash_config_builder.sh:
# разные адреса для одного и того же замера сбивали бы с толку.
CLASH_SUB_DEFAULT_HEALTH_URL="${CLASH_SUB_DEFAULT_HEALTH_URL:-https://www.gstatic.com/generate_204}"
CLASH_SUB_DEFAULT_HEALTH_INTERVAL="${CLASH_SUB_DEFAULT_HEALTH_INTERVAL:-5m}"

# Допуск url-test в миллисекундах: ниже него разница задержек считается
# несущественной и группа не дёргает соединения ради пары миллисекунд.
CLASH_SUB_DEFAULT_TOLERANCE="${CLASH_SUB_DEFAULT_TOLERANCE:-50}"

# Тип группы поверх подписки: urltest (сам выбирает быстрейший) или selector.
CLASH_SUB_DEFAULT_GROUP_TYPE="${CLASH_SUB_DEFAULT_GROUP_TYPE:-urltest}"

# Куда ядро кладёт скачанное. Пусто - спросить у слоя ядра; fallback нужен
# на случай, когда модуль подключили отдельно от подкопа.
CLASH_SUB_PROVIDER_DIR="${CLASH_SUB_PROVIDER_DIR:-}"
CLASH_SUB_PROVIDER_DIR_FALLBACK="/tmp/clash-rs/providers"

## --- служебное --------------------------------------------------------------

# Логи есть только внутри подкопа; в тестах и при ручном запуске модуль
# должен работать молча, а не падать на отсутствующей функции log.
#
# Проверяется именно функция: command -v для функции печатает её имя, а для
# внешней программы - путь. На наличие команды проверять нельзя, на машине
# разработчика в PATH может лежать посторонний бинарник с именем log.
_clash_sub_log() {
	case "$(command -v log 2> /dev/null)" in
	log) log "$1" "${2:-info}" ;;
	esac
	return 0
}

# jq на роутере системный, в тестах подсовывается через JQ=
_clash_sub_jq() {
	"${JQ:-jq}" "$@"
}

#######################################
# Активно ли ядро clash-rs.
#
# Без слоя ядра отвечаем "нет": подписки - фича одного ядра, и модуль,
# подключённый в отрыве от подкопа, должен молчать, а не собирать разделы
# конфига, которых sing-box не поймёт.
# Returns:
#   0 если активен clash-rs
#######################################
_clash_sub_core_is_clash() {
	case "$(command -v core_is_clash 2> /dev/null)" in
	core_is_clash) core_is_clash ;;
	*) return 1 ;;
	esac
}

#######################################
# Истина по-подкоповски: config_get_bool отдаёт 1/0, руками в UCI пишут
# true/yes/on, а менеджер конфига ждёт строку "true".
# Arguments:
#   value: строка
# Returns:
#   0 если значение означает истину
#######################################
_clash_sub_is_true() {
	case "$1" in
	1 | true | yes | on | enabled) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Строка через запятую в JSON-массив. Своя копия вместо
# _clash_json_array_from_commas из фасада: тот приватный, а тащить сюда
# весь фасад ради пяти строк незачем.
# Arguments:
#   value: строка, элементы через запятую
# Outputs:
#   JSON-массив строк, для пустого входа - []
# Example:
#   _clash_sub_json_array "main-sub1,main-sub2"  # -> ["main-sub1","main-sub2"]
#######################################
_clash_sub_json_array() {
	local value="$1"

	if [ -z "$value" ]; then
		printf '%s' "[]"
		return 0
	fi

	printf '%s' "$value" | _clash_sub_jq -R -c 'split(",") | map(select(length > 0))'
}

#######################################
# Интервал подкопа (30m, 1h, 1d) в секунды, с запасным значением.
#
# Перевод берётся из clash_rulesets.sh - там он уже написан и уже покрыт
# тестами, вторая копия рано или поздно разошлась бы с первой. Здесь только
# политика на случай мусора в настройке: битый интервал не повод не собрать
# конфиг, поэтому подставляется значение по умолчанию, а в лог уходит
# предупреждение.
# Arguments:
#   raw: значение из UCI, может быть пустым
#   fallback: чем заменить пустое или неразобранное
# Outputs:
#   число секунд
# Returns:
#   1 если и запасное значение не разбирается
# Example:
#   _clash_sub_interval_to_seconds "1h" "1d"   # -> 3600
#######################################
_clash_sub_interval_to_seconds() {
	local raw="$1" fallback="$2" seconds

	[ -n "$raw" ] || raw="$fallback"

	seconds=$(clash_rs_interval_to_seconds "$raw" 2> /dev/null) || seconds=""
	case "$seconds" in
	'' | 0 | *[!0-9]*)
		[ "$raw" = "$fallback" ] ||
			_clash_sub_log "Не разобрать интервал подписки '$raw', беру $fallback" "warn"
		seconds=$(clash_rs_interval_to_seconds "$fallback" 2> /dev/null) || return 1
		;;
	esac

	case "$seconds" in
	'' | *[!0-9]*) return 1 ;;
	esac

	printf '%s' "$seconds"
}

## --- имена и пути -----------------------------------------------------------

#######################################
# Имя провайдера в proxy-providers.
#
# Номер, а не хэш ссылки: имя видно в дашборде и в логах ядра, и "main-sub2"
# читается, а "main-3f2a9c" нет. Провайдеры пересобираются при каждой сборке
# конфига, так что устаревать именам негде.
# Arguments:
#   section: имя секции подкопа
#   index: порядковый номер подписки в секции, начиная с 1
# Outputs:
#   ключ для proxy-providers
# Example:
#   clash_sub_provider_name "main" 2   # -> main-sub2
#######################################
clash_sub_provider_name() {
	local section="$1" index="${2:-1}"

	printf '%s-sub%s' "$section" "$index"
}

#######################################
# Каталог, куда ядро складывает скачанные подписки.
# Берётся у слоя ядра, чтобы два ядра не писали в один и тот же путь.
# Outputs:
#   путь к каталогу
#######################################
clash_sub_provider_dir() {
	if [ -n "$CLASH_SUB_PROVIDER_DIR" ]; then
		printf '%s' "$CLASH_SUB_PROVIDER_DIR"
		return 0
	fi

	case "$(command -v core_tmp_folder 2> /dev/null)" in
	core_tmp_folder) printf '%s/providers' "$(core_tmp_folder)" ;;
	*) printf '%s' "$CLASH_SUB_PROVIDER_DIR_FALLBACK" ;;
	esac
}

#######################################
# Путь к файлу подписки.
# Путь абсолютный: относительный clash-rs считает от своего рабочего
# каталога, а он не совпадает с каталогом конфига (та же оговорка, что у
# clash_rs_file_provider_json).
# Arguments:
#   name: имя провайдера
# Outputs:
#   путь к файлу
# Example:
#   clash_sub_provider_path "main-sub1"  # -> /tmp/clash-rs/providers/main-sub1.yaml
#######################################
clash_sub_provider_path() {
	local name="$1"

	printf '%s/%s.yaml' "$(clash_sub_provider_dir)" "$name"
}

#######################################
# Имя группы, которую видят правила маршрутизации.
#
# Совпадает с именем выхода секции у остальных типов секций: правила
# ссылаются на "<секция>-out" и знать не знают, откуда взялись серверы.
# Постфикс не дублируется, а берётся у helpers.sh, если тот подключён.
# Arguments:
#   section: имя секции подкопа
# Outputs:
#   имя группы
# Example:
#   clash_sub_group_name "main"   # -> main-out
#######################################
clash_sub_group_name() {
	local section="$1"

	case "$(command -v get_outbound_tag_by_section 2> /dev/null)" in
	get_outbound_tag_by_section) get_outbound_tag_by_section "$section" ;;
	*) printf '%s-out' "$section" ;;
	esac
}

## --- сборка JSON ------------------------------------------------------------
# Отсюда и до конца раздела - чистые функции: ни сети, ни файлов, ни UCI.

#######################################
# Описание health-check провайдера.
#
# Проверка живости серверов подписки - работа ядра: оно само ходит по url,
# само помнит задержки и само выкидывает мёртвые узлы из url-test-группы.
# Отдельного демона, как в forkop, здесь не нужно.
# Arguments:
#   enable: строка, "0"/"false" - проверку выключить
#   url: строка, чем мерять (пустой - CLASH_SUB_DEFAULT_HEALTH_URL)
#   interval: строка, как часто: 5m, 300 (пустой - умолчание модуля)
#   lazy: строка, "true"/"1" - не проверять, пока группа не используется.
#         Пустой означает "поле не задавать"
# Outputs:
#   JSON-объект health-check
# Returns:
#   1 если интервал не разбирается
# Example:
#   clash_sub_health_check_json 1 "" "5m" ""
#######################################
clash_sub_health_check_json() {
	local enable="$1" url="$2" interval="$3" lazy="$4"
	local seconds lazy_json=""

	if [ -n "$enable" ] && ! _clash_sub_is_true "$enable"; then
		_clash_sub_jq -n -c '{enable: false}'
		return 0
	fi

	[ -n "$url" ] || url="$CLASH_SUB_DEFAULT_HEALTH_URL"
	seconds=$(_clash_sub_interval_to_seconds "$interval" "$CLASH_SUB_DEFAULT_HEALTH_INTERVAL") || return 1

	if [ -n "$lazy" ]; then
		if _clash_sub_is_true "$lazy"; then lazy_json="true"; else lazy_json="false"; fi
	fi

	# shellcheck disable=SC2016  # $url и прочее - переменные jq, не шелла
	_clash_sub_jq -n -c \
		--arg url "$url" \
		--argjson interval "$seconds" \
		--arg lazy "$lazy_json" \
		'{enable: true, url: $url, interval: $interval}
		+ (if $lazy == "" then {} else {lazy: ($lazy == "true")} end)'
}

#######################################
# Описание одной подписки для proxy-providers.
#
# Ровно то, ради чего написан модуль: тип http, ссылка, интервал, путь,
# User-Agent и фильтры. Всё остальное - забота ядра.
#
# Про user-agent. Поле называется так, как его ждёт clash-rs; в mihomo тот же
# смысл выражается через header: {User-Agent: [...]}. Если ядро выбранной
# версии ключ не примет, менять надо здесь, в одном месте, а не по всему
# модулю - остальной код имени поля не знает.
# Arguments:
#   url: строка, ссылка подписки (обязательный)
#   path: строка, куда ядро положит скачанное (необязательный)
#   interval: строка, период обновления: 1h, 3600 (пустой - умолчание модуля)
#   user_agent: строка, UA запроса (пустой - clash-meta)
#   filter: строка, регулярное выражение "оставить только это"
#   exclude_filter: строка, регулярное выражение "это выбросить"
#   health_check: строка (JSON), описание проверки живости. Пустая означает
#                 проверку с умолчаниями
# Outputs:
#   JSON-объект провайдера
# Returns:
#   1 если ссылка пуста, интервал не разбирается либо health_check не JSON
# Example:
#   clash_sub_provider_json "https://panel/sub" "/tmp/s.yaml" "1h" "" "" "" ""
#######################################
clash_sub_provider_json() {
	local url="$1" path="$2" interval="$3" user_agent="$4"
	local filter="$5" exclude_filter="$6" health_check="$7"
	local seconds

	if [ -z "$url" ]; then
		_clash_sub_log "Ссылка подписки пуста, провайдер не собирается" "warn"
		return 1
	fi

	seconds=$(_clash_sub_interval_to_seconds "$interval" "$CLASH_SUB_DEFAULT_INTERVAL") || return 1
	[ -n "$user_agent" ] || user_agent="$CLASH_SUB_DEFAULT_USER_AGENT"

	if [ -z "$health_check" ]; then
		health_check=$(clash_sub_health_check_json "" "" "" "") || return 1
	fi

	# Молча подставить мусор в конфиг нельзя: ядро потом откажется стартовать
	# без внятной причины (та же оговорка, что у clash_cm_add_raw_rule_provider)
	printf '%s' "$health_check" | _clash_sub_jq -e . > /dev/null 2>&1 || return 1

	# Пишем ровно те четыре поля, которые clash-rs 0.10.8 действительно знает:
	# OutboundHttpProvider в clash-lib/src/config/internal/proxy.rs объявлен как
	# url, interval, path и health-check - и ничего больше.
	#
	# user-agent, filter и exclude-filter сюда НЕ кладутся, хотя в mihomo они
	# есть. У структуры нет deny_unknown_fields, так что лишние ключи ядро не
	# уронили бы - оно бы их молча проглотило. Это хуже ошибки: пользователь
	# задал фильтр, ошибки не увидел, а серверы приехали все до одного.
	#
	# shellcheck disable=SC2016  # $url и прочее - переменные jq, не шелла
	_clash_sub_jq -n -c \
		--arg url "$url" \
		--arg path "$path" \
		--argjson interval "$seconds" \
		--argjson health_check "$health_check" \
		'{type: "http", url: $url, interval: $interval, "health-check": $health_check}
		+ (if $path != "" then {path: $path} else {} end)'
}

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
#   CONFIG=$(clash_sub_add_raw_provider "$CONFIG" "main-sub1" "$PROVIDER_JSON")
#######################################
clash_sub_add_raw_provider() {
	local config="$1" name="$2" provider="$3"

	[ -n "$name" ] || return 1
	printf '%s' "$provider" | _clash_sub_jq -e . > /dev/null 2>&1 || return 1

	# shellcheck disable=SC2016  # $name и $provider - переменные jq, не шелла
	printf '%s\n' "$config" | _clash_sub_jq \
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
#   CONFIG=$(clash_sub_add_provider_group "$CONFIG" "main-out" select '["main-sub1"]' "" "" "" "" "")
#######################################
clash_sub_add_provider_group() {
	local config="$1" name="$2" kind="$3" use_json="$4" proxies_json="$5"
	local url="$6" interval="$7" tolerance="$8" lazy="$9"
	local type lazy_json=""

	[ -n "$name" ] || return 1

	case "$kind" in
	urltest | url-test | url_test) type="url-test" ;;
	selector | select) type="select" ;;
	*)
		_clash_sub_log "Неизвестный тип группы подписки: '$kind'" "error"
		return 1
		;;
	esac

	[ -n "$use_json" ] || use_json="[]"
	[ -n "$proxies_json" ] || proxies_json="[]"

	printf '%s' "$use_json" | _clash_sub_jq -e 'type == "array"' > /dev/null 2>&1 || return 1
	printf '%s' "$proxies_json" | _clash_sub_jq -e 'type == "array"' > /dev/null 2>&1 || return 1

	if [ -n "$lazy" ]; then
		if _clash_sub_is_true "$lazy"; then lazy_json="true"; else lazy_json="false"; fi
	fi

	# shellcheck disable=SC2016  # $name и прочее - переменные jq, не шелла
	printf '%s\n' "$config" | _clash_sub_jq \
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

## --- настройки секции -------------------------------------------------------

#######################################
# Подписочная ли это секция.
# Arguments:
#   section: имя секции подкопа
# Returns:
#   0 если proxy_config_type равен subscription
#######################################
clash_sub_section_is_subscription() {
	local section="$1" proxy_config_type

	config_get proxy_config_type "$section" "proxy_config_type"
	[ "$proxy_config_type" = "subscription" ]
}

#######################################
# Ссылки подписки секции, по одной в строке.
#
# Поддерживаются обе формы записи, как в netshift: и "list subscription_url"
# с несколькими ссылками, и скалярное "option subscription_url". config_get
# для списка отдаёт значения через пробел, так что обе формы разбираются
# одинаково.
#
# Заодно отсеиваются нессылки (пользователь вставил токен без схемы) и
# точные дубликаты: два одинаковых провайдера в одной группе - это двойная
# нагрузка на панель и удвоенный список серверов в дашборде.
# Arguments:
#   section: имя секции подкопа
# Outputs:
#   ссылки, по одной в строке
# Returns:
#   1 если годных ссылок не нашлось
# Example:
#   urls=$(clash_sub_section_urls main)
#######################################
clash_sub_section_urls() {
	local section="$1" raw

	config_get raw "$section" "subscription_url"
	[ -n "$raw" ] || return 1

	# Разбор через tr, а не через "for item in $raw": в for пришлось бы
	# гасить подстановку имён файлов, а в ссылках подписок ? и * встречаются
	# постоянно (?token=..., ?flow=*).
	#
	# Перевод строки в конце обязателен: read отдаёт незавершённую последнюю
	# строку с ненулевым кодом, и while её молча теряет - с printf '%s' здесь
	# пропадала ровно одна ссылка, последняя.
	printf '%s\n' "$raw" | tr '\t ' '\n\n' | {
		# Без local: правая часть конвейера и так своя подоболочка, наружу
		# отсюда ничего не утекает, а busybox ash на local вне тела функции
		# ругается по-своему - проверять это на роутере дороже, чем не писать
		seen=""
		while IFS= read -r item; do
			[ -n "$item" ] || continue

			case "$item" in
			http://* | https://*) ;;
			*)
				_clash_sub_log "Секция $section: '$item' не похоже на ссылку подписки, пропущено" "warn"
				continue
				;;
			esac

			case " $seen " in
			*" $item "*) continue ;;
			esac
			seen="$seen $item"

			printf '%s\n' "$item"
		done

		[ -n "$seen" ]
	}
}

#######################################
# Собрать подписки одной секции: провайдеры плюс группа поверх них.
#
# Единственная функция модуля, которая читает UCI и трогает файловую систему
# (создаёт каталог, куда ядро будет складывать скачанное). Всё остальное -
# чистая сборка JSON.
#
# Групп получается две, ровно как у обычной urltest-секции в
# clash_config_builder.sh: url-test меряет задержку и выбирает быстрейший
# сервер, а select поверх него позволяет переключить выбор руками через
# Clash API. Имя select-группы совпадает с именем выхода секции, поэтому
# правила маршрутизации подписку от обычного прокси не отличают.
# Arguments:
#   config: строка (JSON), конфигурация для изменения
#   section: строка, имя секции подкопа
# Outputs:
#   Пишет изменённую конфигурацию в stdout. При любой ошибке печатается
#   ИСХОДНЫЙ конфиг, а не то, что успело собраться: провайдеры без группы -
#   это ссылки, которые ядро будет исправно качать, притом что на них никто
#   не ссылается. Полусобранная подписка хуже отсутствующей, потому что
#   выглядит рабочей.
# Returns:
#   0 при успехе, а также при активном sing-box (конфиг не меняется)
#   1 если ссылок нет или конфиг собрать не удалось
# Example:
#   config=$(clash_sub_configure_section "$config" "main") || exit 1
#######################################
clash_sub_configure_section() {
	# original не меняется до конца функции: это то, что уходит наружу при
	# любой ошибке, чтобы полусобранная подписка не доехала до ядра
	local config="$1" section="$2" original="$1"

	# Подписки - фича clash-ветки. На sing-box их нет и в этой задаче не
	# появится, поэтому конфиг возвращается нетронутым, а не ломается.
	if ! _clash_sub_core_is_clash; then
		_clash_sub_log "Секция $section: подписки поддерживаются только на clash-rs, пропущено" "debug"
		printf '%s' "$original"
		return 0
	fi

	local urls
	urls=$(clash_sub_section_urls "$section") || {
		_clash_sub_log "Секция $section: ссылка подписки не задана" "error"
		printf '%s' "$original"
		return 1
	}

	local user_agent interval filter exclude_filter
	local group_type test_url check_interval tolerance lazy health_enable
	config_get interval "$section" "subscription_update_interval" "$CLASH_SUB_DEFAULT_INTERVAL"
	config_get group_type "$section" "subscription_group_type" "$CLASH_SUB_DEFAULT_GROUP_TYPE"
	config_get test_url "$section" "subscription_test_url" "$CLASH_SUB_DEFAULT_HEALTH_URL"
	config_get check_interval "$section" "subscription_check_interval" "$CLASH_SUB_DEFAULT_HEALTH_INTERVAL"
	config_get tolerance "$section" "subscription_tolerance" "$CLASH_SUB_DEFAULT_TOLERANCE"
	config_get lazy "$section" "subscription_lazy"
	config_get health_enable "$section" "subscription_health_check" "1"

	# Тип группы проверяется здесь, до провайдеров и до каталога: узнать о
	# неверной настройке после того, как половина работы сделана, значит
	# выбрасывать эту половину.
	local group_kind
	case "$group_type" in
	urltest | url-test | url_test) group_kind="urltest" ;;
	selector | select) group_kind="selector" ;;
	*)
		_clash_sub_log "Секция $section: неизвестный тип группы подписки '$group_type'" "error"
		printf '%s' "$original"
		return 1
		;;
	esac

	local health seconds dir
	health=$(clash_sub_health_check_json "$health_enable" "$test_url" "$check_interval" "$lazy") || {
		_clash_sub_log "Секция $section: не собрать health-check подписки" "error"
		printf '%s' "$original"
		return 1
	}
	seconds=$(_clash_sub_interval_to_seconds "$check_interval" "$CLASH_SUB_DEFAULT_HEALTH_INTERVAL") || seconds=""

	# Каталог заводим мы, а не ядро: clash-rs не создаёт недостающие каталоги
	# под path и молча остаётся без подписки.
	dir=$(clash_sub_provider_dir)
	mkdir -p "$dir" 2> /dev/null ||
		_clash_sub_log "Не создать каталог подписок $dir" "warn"

	local url index=1 name path provider names="" new_config
	while IFS= read -r url; do
		[ -n "$url" ] || continue

		name=$(clash_sub_provider_name "$section" "$index")
		path=$(clash_sub_provider_path "$name")

		provider=$(clash_sub_provider_json "$url" "$path" "$interval" "$user_agent" \
			"$filter" "$exclude_filter" "$health") || {
			_clash_sub_log "Секция $section: не собрать описание подписки $index" "error"
			printf '%s' "$original"
			return 1
		}

		new_config=$(clash_sub_add_raw_provider "$config" "$name" "$provider") || {
			_clash_sub_log "Секция $section: не добавить подписку $name в конфиг" "error"
			printf '%s' "$original"
			return 1
		}
		config="$new_config"

		names="${names}${names:+,}$name"
		index=$((index + 1))
	done <<EOF
$urls
EOF

	if [ -z "$names" ]; then
		_clash_sub_log "Секция $section: ни одной годной ссылки подписки" "error"
		printf '%s' "$original"
		return 1
	fi

	local use_json group_name urltest_name
	use_json=$(_clash_sub_json_array "$names")
	group_name=$(clash_sub_group_name "$section")

	case "$group_kind" in
	urltest)
		urltest_name=$(clash_sub_group_name "$section-urltest")

		new_config=$(clash_sub_add_provider_group "$config" "$urltest_name" "url-test" \
			"$use_json" "" "$test_url" "$seconds" "$tolerance" "$lazy") || {
			_clash_sub_log "Секция $section: не собрать url-test-группу подписки" "error"
			printf '%s' "$original"
			return 1
		}
		config="$new_config"

		new_config=$(clash_sub_add_provider_group "$config" "$group_name" "select" \
			"$use_json" "$(_clash_sub_json_array "$urltest_name")" "" "" "" "") || {
			_clash_sub_log "Секция $section: не собрать select-группу подписки" "error"
			printf '%s' "$original"
			return 1
		}
		config="$new_config"
		;;
	*)
		# selector. Ветка по умолчанию, а не по имени: group_kind проверен
		# выше, и попасть сюда с чем-то третьим нельзя - зато при любом
		# недосмотре группа всё равно появится, а не потеряется
		new_config=$(clash_sub_add_provider_group "$config" "$group_name" "select" \
			"$use_json" "" "" "" "" "") || {
			_clash_sub_log "Секция $section: не собрать select-группу подписки" "error"
			printf '%s' "$original"
			return 1
		}
		config="$new_config"
		;;
	esac

	printf '%s' "$config"
}

## --- диагностика ------------------------------------------------------------
#
# Здесь начинается и заканчивается вся наша работа с телом подписки: мы его
# КЛАССИФИЦИРУЕМ, но не разбираем. Задача - объяснить человеку, почему в
# дашборде пусто, а не подменять собой ядро.

#######################################
# На что похоже тело подписки.
#
# Определяется по признакам первого уровня, без декодирования: base64-блоб
# так и остаётся блобом, Xray-JSON - джейсоном. Разворачивать их - работа
# фолбэк-парсера из отдельной задачи, см. шапку модуля.
# Arguments:
#   src: путь к файлу
# Outputs:
#   clash | base64 | uri-list | json | unknown
# Returns:
#   1 если файла нет
# Example:
#   clash_sub_detect_format /tmp/clash-rs/providers/main-sub1.yaml
#######################################
clash_sub_detect_format() {
	local src="$1"

	[ -f "$src" ] || return 1

	awk '
	{
		line = $0
		sub(/\r$/, "", line)
		if (line ~ /^[ \t]*$/) next

		nonempty++
		if (nonempty == 1) first = line

		# ключ proxies: на верхнем уровне - единственное, что clash-rs
		# действительно ищет в теле провайдера
		if (line ~ /^proxies:/) { clash = 1; exit }

		if (line ~ /^(vless|vmess|ss|ssr|trojan|hysteria|hysteria2|hy2|tuic|socks5?):\/\//) uri = 1

		if (line ~ /^[A-Za-z0-9+\/=_-]+$/ && length(line) >= 32) b64++
		else other++
	}
	END {
		if (clash) { print "clash"; exit 0 }
		if (first ~ /^[{[]/) { print "json"; exit 0 }
		if (uri) { print "uri-list"; exit 0 }
		if (b64 > 0 && other == 0) { print "base64"; exit 0 }
		print "unknown"
	}
	' "$src"
}

#######################################
# Проверить, что ядру скормили то, что оно умеет читать.
#
# Зовётся из диагностики, уже ПОСЛЕ старта ядра: файл по пути провайдера
# кладёт clash-rs, а не мы. Сеть здесь не трогается вовсе.
#
# Смысл в сообщении. Симптом у всех перечисленных случаев один - пустая
# группа и никакого трафика в туннеле, а причина каждый раз разная, и
# угадать её по логам ядра нельзя: clash-rs пишет только то, что тело не
# разобралось.
# Arguments:
#   name: имя провайдера (для сообщения)
#   path: путь к скачанному файлу
# Returns:
#   0 если это Clash-YAML, иначе 1
# Example:
#   clash_sub_check_provider_file "main-sub1" "$(clash_sub_provider_path main-sub1)"
#######################################
clash_sub_check_provider_file() {
	local name="$1" path="$2" format message

	if [ ! -s "$path" ]; then
		_clash_sub_log "Подписка $name: ядро ничего не скачало в $path. Проверьте ссылку и доступность панели" "error"
		return 1
	fi

	format=$(clash_sub_detect_format "$path") || return 1

	case "$format" in
	clash) return 0 ;;
	base64) message="панель отдала base64-блоб" ;;
	uri-list) message="панель отдала список ссылок vless://" ;;
	json) message="панель отдала JSON, похоже на формат Xray" ;;
	*) message="формат тела не распознан" ;;
	esac

	_clash_sub_log "Подписка $name: $message, а clash-rs читает только Clash-YAML с ключом proxies:. clash-rs шлёт свой User-Agent (clash-rs/<версия>) и переопределить его нечем, поэтому возьмите у панели ссылку сразу в формате clash" "error"
	return 1
}
