# Установщик ядра clash-rs с GitHub Releases.
#
# clash-rs нет ни в одном фиде OpenWrt: ни в packages, ни в telephony, ни в
# routing. sing-box подкоп получает через DEPENDS, а clash-rs получить неоткуда
# - значит, без «скачать бинарник под свою архитектуру, проверить, положить и
# откатиться при неудаче» ветка живёт только на нашем стенде. Форк netshift
# решает ровно эту задачу для sing-box-extended (updates_resolve_*_arch_suffix,
# updates_extended_asset_url, updates_stable_rollback), форк forkop вообще
# выкинул +sing-box из зависимостей и ставит ядро сам.
#
# Устройство модуля намеренно разделено на два слоя:
#
#   чистые функции  - определение платформы, сборка URL, разбор ответа API,
#                     сравнение версий. Ни одна не ходит в сеть и не пишет на
#                     диск, поэтому проверяются тестами целиком.
#   тонкие обёртки  - всё, что стучится наружу: _core_installer_resolve_url,
#                     _core_installer_api_get, _core_installer_download,
#                     _core_installer_service_running. В тестах подменяются
#                     заглушками, своей логики не содержат.
#
# Скачивание не пишется заново: ретраи с нарастающей паузой и разбором 429 уже
# сделаны в clash_rulesets.sh (clash_rs_download_list), и второй такой же
# механизм здесь был бы просто вторым местом, где чинить один и тот же баг.
#
# Зависимости: core.sh (пути и имена ядра), clash_rulesets.sh (скачивание),
# curl и jq - оба уже в DEPENDS пакета.
#
# Использование:
#   core_installer_update            # остановить сервис, поставить последнюю, поднять
#   core_installer_install v0.10.8   # поставить конкретную версию
#   core_installer_rollback          # вернуть предыдущий бинарник
#
# shellcheck shell=ash
# shellcheck disable=SC2034

## --- параметры ---------------------------------------------------------------
# Всё через :- чтобы переопределялось снаружи: из podkop, из тестов или руками
# при отладке на роутере.

CORE_INSTALLER_REPO="${CORE_INSTALLER_REPO:-Watfaq/clash-rs}"
CORE_INSTALLER_GITHUB_URL="${CORE_INSTALLER_GITHUB_URL:-https://github.com}"
CORE_INSTALLER_API_URL="${CORE_INSTALLER_API_URL:-https://api.github.com}"

# Ассеты релиза называются clash-rs-<триплет>, без расширений и без архивов:
# в релизе лежит голый бинарник, распаковывать нечего.
CORE_INSTALLER_ASSET_PREFIX="${CORE_INSTALLER_ASSET_PREFIX:-clash-rs-}"

# Куда класть бинарник. Каталог отдельным параметром: на роутерах с 16 МБ флеша
# в overlay двадцати мегабайт нет, и единственный выход - положить ядро в tmpfs
# (так делает netshift) ценой перекачивания после каждой перезагрузки.
CORE_INSTALLER_BIN_DIR="${CORE_INSTALLER_BIN_DIR:-/usr/bin}"

# Рабочий каталог под скачанный файл - в tmpfs, чтобы не жечь флеш.
CORE_INSTALLER_WORK_DIR="${CORE_INSTALLER_WORK_DIR:-/tmp/podkop-core-install}"

# Суффикс бэкапа. Бэкап лежит рядом с бинарником, а не в /tmp: откат должен
# пережить перезагрузку, иначе от него нет пользы ровно в тот момент, когда он
# нужен - роутер ушёл в ребут с нерабочим ядром.
CORE_INSTALLER_BACKUP_SUFFIX="${CORE_INSTALLER_BACKUP_SUFFIX:-.podkop-bak}"

CORE_INSTALLER_TIMEOUT="${CORE_INSTALLER_TIMEOUT:-20}"
CORE_INSTALLER_RETRIES="${CORE_INSTALLER_RETRIES:-4}"

# Нижняя граница вменяемости скачанного файла. Самый маленький musl-ассет
# clash-rs 0.10.8 - armv7, 18.5 МБ; страница ошибки GitHub или обрезанная
# закачка в мегабайт не укладываются заведомо.
CORE_INSTALLER_MIN_BYTES="${CORE_INSTALLER_MIN_BYTES:-1048576}"

# Откуда читать архитектуру. Файл, а не команда: подменяется в тестах одной
# переменной, без заглушки на uname.
CORE_INSTALLER_RELEASE_FILE="${CORE_INSTALLER_RELEASE_FILE:-/etc/openwrt_release}"

# HTTP-прокси для скачивания, если у роутера нет прямого доступа к GitHub.
CORE_INSTALLER_PROXY="${CORE_INSTALLER_PROXY:-}"

## --- коды возврата -----------------------------------------------------------
#
#   0 - установлено (в том числе «нужная версия уже стоит»)
#   1 - общая ошибка
#   2 - платформа не поддержана
#   3 - сервис запущен, установка отменена
#   4 - не удалось получить релиз или скачать ассет
#   5 - скачанное не прошло проверку (изменения откачены)

## --- служебное ---------------------------------------------------------------

# Логи есть только внутри подкопа; в тестах и при ручном запуске модуль должен
# работать молча, а не падать на отсутствующей функции log. Проверяется именно
# функция: command -v для функции печатает её имя, а для внешней программы -
# путь, и посторонний бинарник с именем log в PATH нас бы обманул.
_core_installer_log() {
	case "$(command -v log 2> /dev/null)" in
	log) log "$1" "${2:-info}" ;;
	esac
	return 0
}

# Ошибка идёт и в системный лог, и на stderr: установщик зовут руками из
# консоли, а там молчаливый ненулевой код бесполезен.
_core_installer_fail() {
	_core_installer_log "$1" "error"
	printf '%s\n' "$1" >&2
	return 1
}

# jq на роутере системный, в тестах подсовывается через JQ=
_core_installer_jq() {
	"${JQ:-jq}" "$@"
}

# Возврат каретки. На роутере его в выводе jq нет вовсе, но нативный jq.exe под
# Windows, на котором гоняется часть тестов, дописывает \r в конец строки - и
# точное сравнение имени ассета из-за одного невидимого байта не срабатывало бы.
_CORE_INSTALLER_CR=$(printf '\r')

## --- платформа ---------------------------------------------------------------

#######################################
# Архитектура системы.
# Сначала DISTRIB_ARCH из /etc/openwrt_release: там лежит именно та строка,
# которой OpenWrt называет свою сборку (aarch64_cortex-a53), и по ней видно
# подвариант ARM. uname -m остаётся фолбэком: он отдаёт armv7l и не отличает
# cortex-a7 от cortex-a9, но этого хватает для выбора триплета.
# Outputs:
#   строка архитектуры
# Returns:
#   1, если не удалось определить вовсе
#######################################
core_installer_arch() {
	local arch=""

	if [ -r "$CORE_INSTALLER_RELEASE_FILE" ]; then
		arch=$(sed -n "s/^DISTRIB_ARCH=[\"']\{0,1\}\([^\"']*\)[\"']\{0,1\}.*/\1/p" \
			"$CORE_INSTALLER_RELEASE_FILE" 2> /dev/null | head -n1)
	fi

	[ -n "$arch" ] || arch=$(uname -m 2> /dev/null)
	[ -n "$arch" ] || return 1

	printf '%s\n' "$arch"
}

#######################################
# Архитектура OpenWrt -> триплет Rust.
#
# Соответствие проверено по списку ассетов релиза, а не выведено из общих
# соображений: в релизах clash-rs есть musl-сборки только под aarch64, armv7hf,
# mips, mipsel, i686 и x86_64. Всё остальное (armv5/armv6, mips64, powerpc)
# сборки не имеет вовсе, а riscv64 собран только под gnu - на musl-системе
# такой бинарник не запустится, и обещать его установку нельзя.
#
# Arguments:
#   arch: DISTRIB_ARCH или вывод uname -m
# Outputs:
#   триплет Rust
# Returns:
#   1, если сборки под платформу нет; причина пишется на stderr
#######################################
core_installer_triplet() {
	local arch="$1"

	case "$arch" in
	'')
		_core_installer_fail "Не удалось определить архитектуру роутера"
		return 1
		;;

	# 64-битный ARM: aarch64_cortex-a53 (mediatek/filogic), aarch64_cortex-a72,
	# aarch64_cortex-a76, aarch64_generic
	aarch64 | aarch64_* | arm64)
		printf 'aarch64-unknown-linux-musl\n'
		;;

	# 32-битный ARM с аппаратным FPU. В OpenWrt это cortex-a5/a7/a8/a9/a15/a17;
	# ассет один - armv7 hard-float, ABI у всех перечисленных совместимый.
	armv7 | armv7l | armv7hl | \
		arm_cortex-a5 | arm_cortex-a5_* | \
		arm_cortex-a7 | arm_cortex-a7_* | \
		arm_cortex-a8 | arm_cortex-a8_* | \
		arm_cortex-a9 | arm_cortex-a9_* | \
		arm_cortex-a15 | arm_cortex-a15_* | \
		arm_cortex-a17 | arm_cortex-a17_*)
		printf 'armv7-unknown-linux-musleabihf\n'
		;;

	# 64-битный MIPS отсекается раньше 32-битных веток: у него n64-ABI, и
	# o32-бинарник из релиза на нём не запустится, хотя имя похоже
	mips64* | mipsel64* | octeon*)
		_core_installer_fail "Для '$arch' сборки clash-rs нет: в релизах только 32-битный mips"
		return 1
		;;

	# mipsel_24kc - ramips, самая распространённая MIPS-платформа OpenWrt
	mipsel | mipsel_* | mips32el | mipsle)
		printf 'mipsel-unknown-linux-musl\n'
		;;

	mips | mips_* | mips32)
		printf 'mips-unknown-linux-musl\n'
		;;

	x86_64 | amd64)
		printf 'x86_64-unknown-linux-musl\n'
		;;

	# 32-битный x86: i386_pentium4, i386_pentium-mmx, i486, i686
	i386 | i386_* | i486 | i586 | i686 | x86 | x86_generic)
		printf 'i686-unknown-linux-musl\n'
		;;

	# Явные отказы с причиной - чтобы человек в логе увидел, почему не поставилось
	riscv64 | riscv64_*)
		_core_installer_fail "Для '$arch' в релизах clash-rs есть только gnu-сборка, на musl-системе она не запустится"
		return 1
		;;
	arm_arm* | arm_mpcore* | arm_xscale* | arm_fa526* | armv5* | armv6*)
		_core_installer_fail "Для '$arch' сборки clash-rs нет: ассеты начинаются с armv7 hard-float"
		return 1
		;;
	*)
		_core_installer_fail "Архитектура '$arch' не поддержана установщиком clash-rs"
		return 1
		;;
	esac
}

#######################################
# Триплет для текущей машины: определение архитектуры плюс отображение.
# Outputs:
#   триплет Rust
#######################################
core_installer_platform() {
	local arch

	arch=$(core_installer_arch 2> /dev/null)
	core_installer_triplet "$arch"
}

## --- адреса ------------------------------------------------------------------

#######################################
# Имя ассета в релизе. В релизах clash-rs это голый бинарник clash-rs-<триплет>
# без расширения: ни tar, ни gz, распаковывать нечего.
#######################################
core_installer_asset_name() {
	local triplet="$1"

	[ -n "$triplet" ] || return 1
	printf '%s%s\n' "$CORE_INSTALLER_ASSET_PREFIX" "$triplet"
}

#######################################
# Прямая ссылка на ассет конкретного релиза.
# Arguments:
#   tag: тег релиза, например v0.10.8
#   triplet: триплет Rust
#######################################
core_installer_asset_url() {
	local tag="$1" triplet="$2" asset

	[ -n "$tag" ] || return 1
	asset=$(core_installer_asset_name "$triplet") || return 1

	printf '%s/%s/releases/download/%s/%s\n' \
		"$CORE_INSTALLER_GITHUB_URL" "$CORE_INSTALLER_REPO" "$tag" "$asset"
}

#######################################
# Ссылка на ассет последнего релиза без обращения к API.
# GitHub сам уводит редиректом на конкретный тег, и этот путь под лимит в
# 60 запросов в час не подпадает - в отличие от api.github.com, куда роутеры
# за CGNAT упираются не по своей вине (фича №40 в docs/forks-features.md).
#######################################
core_installer_latest_asset_url() {
	local triplet="$1" asset

	asset=$(core_installer_asset_name "$triplet") || return 1

	printf '%s/%s/releases/latest/download/%s\n' \
		"$CORE_INSTALLER_GITHUB_URL" "$CORE_INSTALLER_REPO" "$asset"
}

# Страница последнего релиза; редирект с неё и даёт тег
core_installer_latest_url() {
	printf '%s/%s/releases/latest\n' "$CORE_INSTALLER_GITHUB_URL" "$CORE_INSTALLER_REPO"
}

core_installer_api_latest_url() {
	printf '%s/repos/%s/releases/latest\n' "$CORE_INSTALLER_API_URL" "$CORE_INSTALLER_REPO"
}

core_installer_api_release_url() {
	local tag="$1"

	[ -n "$tag" ] || return 1
	printf '%s/repos/%s/releases/tags/%s\n' "$CORE_INSTALLER_API_URL" "$CORE_INSTALLER_REPO" "$tag"
}

## --- разбор ответов ----------------------------------------------------------

#######################################
# Тег релиза из адреса, на который увёл редирект.
# Понимает обе формы, потому что редирект бывает и со страницы релиза, и с
# прямой ссылки на ассет:
#   .../releases/tag/v0.10.8
#   .../releases/download/v0.10.8/clash-rs-aarch64-unknown-linux-musl
# Outputs:
#   тег
# Returns:
#   1, если в адресе тега нет
#######################################
core_installer_tag_from_url() {
	local url="$1" tag

	case "$url" in
	*/releases/tag/*)
		tag="${url##*/releases/tag/}"
		tag="${tag%%/*}"
		;;
	*/releases/download/*)
		tag="${url##*/releases/download/}"
		tag="${tag%%/*}"
		;;
	*)
		return 1
		;;
	esac

	# хвост запроса и якорь GitHub иногда дописывает сам
	tag="${tag%%\?*}"
	tag="${tag%%#*}"

	[ -n "$tag" ] || return 1
	printf '%s\n' "$tag"
}

#######################################
# Тег релиза из ответа GitHub API.
# Arguments:
#   json: тело ответа
#######################################
core_installer_tag_from_api() {
	local json="$1" tag

	[ -n "$json" ] || return 1

	tag=$(printf '%s' "$json" | _core_installer_jq -r '.tag_name // empty' 2> /dev/null)
	tag="${tag%"$_CORE_INSTALLER_CR"}"
	[ -n "$tag" ] || return 1

	printf '%s\n' "$tag"
}

#######################################
# Имена ассетов из ответа GitHub API, по одному в строке.
#######################################
core_installer_assets_from_api() {
	local json="$1" names

	[ -n "$json" ] || return 1

	names=$(printf '%s' "$json" | _core_installer_jq -r '.assets[]?.name // empty' 2> /dev/null)
	[ -n "$names" ] || return 1

	printf '%s\n' "$names"
}

#######################################
# Есть ли в списке имён (stdin, по одному в строке) ассет под триплет.
# Сравнение точное, а не по подстроке: имена ассетов вложены друг в друга
# (x86_64-unknown-linux-gnu и x86_64-unknown-linux-gnu-static-crt), и поиск
# подстрокой выбрал бы не то.
# Arguments:
#   triplet
# Outputs:
#   имя ассета
#######################################
core_installer_select_asset() {
	local triplet="$1" want line

	want=$(core_installer_asset_name "$triplet") || return 1

	while IFS= read -r line; do
		line="${line%"$_CORE_INSTALLER_CR"}"
		case "$line" in
		"$want")
			printf '%s\n' "$want"
			return 0
			;;
		esac
	done

	return 1
}

## --- версии ------------------------------------------------------------------

#######################################
# Тег -> версия. Теги clash-rs выглядят как v0.10.8, а `clash-rs -v` печатает
# версию без ведущей v - сравнивать надо приведённые к одному виду.
#######################################
core_installer_version_of_tag() {
	local tag="$1"

	[ -n "$tag" ] || return 1
	printf '%s\n' "${tag#v}"
}

#######################################
# have >= want?
#
# Своя реализация, а не is_min_package_version из helpers.sh: тот модуль тащит
# за собой башизмы апстрима ([[ =~ ]], $RANDOM), и подключать его ради четырёх
# строк сравнения означало бы, что установщик нельзя проверить в отрыве от них.
# Логика та же самая - sort -V и сравнение с младшим.
#
# Если sort не умеет -V (урезанный busybox), сравнение считается пройденным:
# отказать в установке из-за отсутствующего ключа сортировки хуже, чем поставить.
#######################################
core_installer_version_ge() {
	local have="$1" want="$2" lowest

	[ -n "$have" ] || return 1
	[ -n "$want" ] || return 0

	lowest=$(printf '%s\n%s\n' "$have" "$want" | sort -V 2> /dev/null | head -n1)
	[ -n "$lowest" ] || return 0

	[ "$lowest" = "$want" ]
}

## --- стыковка со слоем ядра --------------------------------------------------

#######################################
# Куда ставим бинарник.
#
# Имя берётся из core.sh (CORE_CR_BIN), а не зашито здесь. Именно CORE_CR_BIN,
# а не core_binary: core_binary отдаёт АКТИВНОЕ ядро, и при выбранном sing-box
# установщик положил бы clash-rs поверх чужого бинарника. Когда активное ядро -
# clash-rs, обе величины совпадают.
#
# Если в CORE_CR_BIN лежит путь (тесты, ручная отладка) - берём как есть.
#######################################
core_installer_dest() {
	local bin="${CORE_CR_BIN:-clash-rs}"

	case "$bin" in
	*/*) printf '%s\n' "$bin" ;;
	*) printf '%s/%s\n' "${CORE_INSTALLER_BIN_DIR%/}" "$bin" ;;
	esac
}

# Init-скрипт ядра: тоже из core.sh, по той же причине, что и путь бинарника
core_installer_service() {
	printf '%s\n' "${CORE_CR_SERVICE:-/etc/init.d/clash-rs}"
}

# Минимальная версия, с которой подкоп умеет работать - из core.sh
core_installer_min_version() {
	printf '%s\n' "${CORE_CR_MIN_VERSION:-0.10.0}"
}

core_installer_backup_path() {
	printf '%s%s\n' "$(core_installer_dest)" "$CORE_INSTALLER_BACKUP_SUFFIX"
}

core_installer_is_installed() {
	[ -x "$(core_installer_dest)" ]
}

## --- тонкие обёртки наружу ---------------------------------------------------
# Ниже - всё, что стучится в сеть, в процессы и в df. Своей логики здесь нет,
# в тестах эти четыре функции подменяются заглушками.

#######################################
# Адрес, на который в итоге увёл редирект. HEAD, а не GET: тело страницы релиза
# нам не нужно, а на слабом канале это разница в сотню килобайт.
#######################################
_core_installer_resolve_url() {
	local url="$1" proxy="${2:-$CORE_INSTALLER_PROXY}" out

	command -v curl > /dev/null 2>&1 || return 1

	if [ -n "$proxy" ]; then
		out=$(curl -sIL --max-time "$CORE_INSTALLER_TIMEOUT" -x "http://$proxy" \
			-o /dev/null -w '%{url_effective}' "$url" 2> /dev/null)
	else
		out=$(curl -sIL --max-time "$CORE_INSTALLER_TIMEOUT" \
			-o /dev/null -w '%{url_effective}' "$url" 2> /dev/null)
	fi

	[ -n "$out" ] || return 1
	printf '%s\n' "$out"
}

# Запрос к GitHub API. Зовётся только фолбэком: у анонимного API 60 запросов в
# час на IP, и роутеры за общим NAT выбирают лимит чужими руками.
_core_installer_api_get() {
	local url="$1" proxy="${2:-$CORE_INSTALLER_PROXY}"

	command -v curl > /dev/null 2>&1 || return 1

	if [ -n "$proxy" ]; then
		curl -sS -L --max-time "$CORE_INSTALLER_TIMEOUT" \
			-H 'Accept: application/vnd.github+json' \
			-x "http://$proxy" "$url" 2> /dev/null
	else
		curl -sS -L --max-time "$CORE_INSTALLER_TIMEOUT" \
			-H 'Accept: application/vnd.github+json' "$url" 2> /dev/null
	fi
}

#######################################
# Скачивание ассета.
# Ретраи с нарастающей паузой и разбором 429 уже написаны в clash_rulesets.sh -
# второй такой же механизм здесь означал бы два места, где чинить один баг.
#######################################
_core_installer_download() {
	local url="$1" dst="$2" proxy="${3:-$CORE_INSTALLER_PROXY}"

	if ! command -v clash_rs_download_list > /dev/null 2>&1; then
		_core_installer_fail "clash_rulesets.sh не подключён: скачивать нечем"
		return 1
	fi

	clash_rs_download_list "$url" "$dst" "$proxy" "$CORE_INSTALLER_RETRIES"
}

#######################################
# Запущен ли сервис ядра.
# procd-скрипты отдают `running`, но полагаться только на него нельзя: если
# init-скрипт команду не знает, rc.common вернёт ненулевой код, и мы решим, что
# ядро стоит, тогда как оно работает. Поэтому вторым заходом смотрим процесс.
#######################################
_core_installer_service_running() {
	local service="$1" name="$2"

	if [ -x "$service" ]; then
		"$service" running > /dev/null 2>&1 && return 0
	fi

	[ -n "$name" ] || return 1
	pidof "$name" > /dev/null 2>&1
}

# Свободно килобайт в каталоге. Пусто, если разобрать вывод df не вышло
_core_installer_free_kb() {
	df -k "$1" 2> /dev/null | awk 'NR > 1 && $4 ~ /^[0-9]+$/ { print $4; exit }'
}

# Размер файла в килобайтах
_core_installer_size_kb() {
	du -k "$1" 2> /dev/null | awk '{ print $1; exit }'
}

## --- проверки ----------------------------------------------------------------

#######################################
# Похоже ли на исполняемый файл ELF.
# Проверяются первые четыре байта: 0x7f E L F. HTML-страница ошибки GitHub,
# обрезанная закачка и текст «Not Found» этот тест не проходят, а именно они и
# приезжают вместо бинарника, когда ассета под платформу не существует.
#######################################
core_installer_is_elf() {
	local path="$1" magic

	[ -f "$path" ] || return 1

	magic=$(head -c 4 "$path" 2> /dev/null | od -An -tx1 2> /dev/null | tr -d ' \t\n\r')
	[ "$magic" = "7f454c46" ]
}

#######################################
# Версия бинарника по указанному пути.
#
# Разбор тот же, что в core_version (core.sh): `clash-rs v0.10.8` - последнее
# поле первой строки без ведущей v. Здесь он повторён не ради удобства:
# core_version спрашивает АКТИВНОЕ ядро через PATH, а установщику надо спросить
# конкретный файл, в том числе только что скачанный во временный каталог и ещё
# никуда не положенный.
#######################################
core_installer_probe_version() {
	local path="$1" raw version

	[ -x "$path" ] || return 1

	raw=$("$path" -v 2> /dev/null || "$path" --version 2> /dev/null)
	[ -n "$raw" ] || return 1

	version=$(printf '%s' "$raw" | head -n1 | awk '{ print $NF }' | tr -d '\r')
	version="${version#v}"

	case "$version" in
	'' | *[!0-9.]*) return 1 ;;
	esac

	printf '%s\n' "$version"
}

#######################################
# Версия уже установленного ядра.
# Когда clash-rs выбран активным ядром, спрашиваем слой ядра: разбор вывода там
# уже есть. Когда активен sing-box, слой ядра ответил бы про него, поэтому
# смотрим прямо на файл - установщик должен работать и до переключения.
# Returns:
#   1, если ядро не установлено
#######################################
core_installer_installed_version() {
	if core_is_clash 2> /dev/null; then
		core_version 2> /dev/null && return 0
	fi

	core_installer_probe_version "$(core_installer_dest)"
}

#######################################
# Хватит ли места в каталоге.
# Если df разобрать не удалось - считаем, что хватит: отказать в установке из-за
# нечитаемого вывода df хуже, чем попытаться и получить честную ошибку записи.
# Arguments:
#   dir, need_kb
#######################################
core_installer_has_space() {
	local dir="$1" need_kb="$2" free

	free=$(_core_installer_free_kb "$dir")
	[ -n "$free" ] || return 0

	[ "$free" -ge "$need_kb" ]
}

#######################################
# Проверка скачанного файла до того, как он куда-то положен.
#
# Порядок от дешёвого к дорогому: размер, магия ELF, запуск. Запуск последним
# не из экономии - запускать неизвестный файл имеет смысл только после того,
# как мы убедились, что это вообще бинарник, а не HTML со словом «Error».
#
# Arguments:
#   path: файл
#   want_version: ожидаемая версия (необязательно); при несовпадении - отказ
# Returns:
#   0, если файлу можно доверять
#######################################
core_installer_verify_binary() {
	local path="$1" want_version="$2"
	local size version min

	if [ ! -f "$path" ]; then
		_core_installer_fail "Скачанного файла нет: $path"
		return 1
	fi

	size=$(_core_installer_size_kb "$path")
	case "$size" in
	'' | *[!0-9]*) size=0 ;;
	esac
	if [ $((size * 1024)) -lt "$CORE_INSTALLER_MIN_BYTES" ]; then
		_core_installer_fail "Скачанный файл слишком мал (${size}K) - это не бинарник clash-rs"
		return 1
	fi

	if ! core_installer_is_elf "$path"; then
		_core_installer_fail "Скачанный файл не ELF: под платформу приехало что-то другое"
		return 1
	fi

	chmod 0755 "$path" 2> /dev/null

	version=$(core_installer_probe_version "$path")
	if [ -z "$version" ]; then
		_core_installer_fail "Скачанный бинарник не отвечает на -v: запустить его на этой платформе нельзя"
		return 1
	fi

	min=$(core_installer_min_version)
	if ! core_installer_version_ge "$version" "$min"; then
		_core_installer_fail "Версия $version младше минимальной $min, подкоп с ней не работает"
		return 1
	fi

	if [ -n "$want_version" ] && [ "$version" != "$want_version" ]; then
		_core_installer_fail "В ассете версия $version, а ожидалась $want_version"
		return 1
	fi

	printf '%s\n' "$version"
}

## --- подмена и откат ---------------------------------------------------------

#######################################
# Положить проверенный файл на место старого.
#
# Копия сначала кладётся РЯДОМ с целью, и только потом переименовывается:
# mv из /tmp в /usr/bin - это разные файловые системы, то есть copy+unlink, и
# переименование перестаёт быть атомарным. Оборвись питание посередине - на
# флеше остался бы обрубок вместо ядра. Переименование в пределах одной ФС либо
# произошло целиком, либо не произошло вовсе.
#
# Arguments:
#   src: проверенный файл
#   dest: куда
# Returns:
#   0 при успехе; при неудаче после подмены выполняется откат
#######################################
core_installer_swap() {
	local src="$1" dest="$2"
	local dir staged backup need

	dir=$(dirname "$dest")
	mkdir -p "$dir" 2> /dev/null || {
		_core_installer_fail "Не удалось создать каталог $dir"
		return 1
	}

	# Место: нужен staged-файл плюс бэкап старого, то есть примерно два размера
	need=$(_core_installer_size_kb "$src")
	case "$need" in
	'' | *[!0-9]*) need=0 ;;
	esac
	if ! core_installer_has_space "$dir" $((need * 2)); then
		_core_installer_fail "В $dir не хватает места: нужно ~$((need * 2))K"
		return 1
	fi

	staged="$dest.podkop-new"
	backup=$(core_installer_backup_path)

	rm -f "$staged"
	if ! cp "$src" "$staged" 2> /dev/null; then
		rm -f "$staged"
		_core_installer_fail "Не удалось скопировать бинарник в $staged"
		return 1
	fi
	chmod 0755 "$staged" 2> /dev/null

	# Бэкап делается ПОСЛЕ успешной копии: если места не хватило, старое ядро
	# должно остаться нетронутым вместе со своим прежним бэкапом.
	if [ -e "$dest" ]; then
		rm -f "$backup"
		if ! cp "$dest" "$backup" 2> /dev/null; then
			rm -f "$staged"
			_core_installer_fail "Не удалось сохранить бэкап в $backup"
			return 1
		fi
	fi

	if ! mv -f "$staged" "$dest" 2> /dev/null; then
		rm -f "$staged"
		_core_installer_fail "Не удалось подменить $dest"
		return 1
	fi

	# Проверка уже на месте: подмена могла удаться, а бинарник - не запуститься
	# (кончилось место при копировании, слетели права, попал чужой ассет).
	if ! core_installer_probe_version "$dest" > /dev/null 2>&1; then
		_core_installer_fail "Новый бинарник на месте не запускается, откатываюсь"
		core_installer_rollback "$dest"
		return 1
	fi

	return 0
}

#######################################
# Вернуть предыдущий бинарник из бэкапа.
# Через тот же staged-файл и переименование, что и установка: откат не должен
# оставить после себя обрубок, ради которого он и делается.
# Arguments:
#   dest: путь к бинарнику (необязательно)
#######################################
core_installer_rollback() {
	local dest="${1:-$(core_installer_dest)}"
	local backup staged

	backup="$dest$CORE_INSTALLER_BACKUP_SUFFIX"

	if [ ! -f "$backup" ]; then
		_core_installer_fail "Бэкапа нет ($backup), откатываться не к чему"
		return 1
	fi

	staged="$dest.podkop-rollback"
	rm -f "$staged"
	if ! cp "$backup" "$staged" 2> /dev/null; then
		rm -f "$staged"
		_core_installer_fail "Не удалось подготовить откат из $backup"
		return 1
	fi
	chmod 0755 "$staged" 2> /dev/null

	if ! mv -f "$staged" "$dest" 2> /dev/null; then
		rm -f "$staged"
		_core_installer_fail "Не удалось вернуть бинарник из $backup"
		return 1
	fi

	_core_installer_log "Ядро откачено из $backup" "warn"
	return 0
}

## --- получение релиза --------------------------------------------------------

#######################################
# Тег последнего релиза.
# Сначала редирект со страницы релиза - он лимита API не касается. API остаётся
# фолбэком на случай, если редирект не разобрался (сменилась схема адресов,
# прокси схлопнул перенаправление).
#######################################
core_installer_latest_tag() {
	local url tag json

	url=$(_core_installer_resolve_url "$(core_installer_latest_url)" 2> /dev/null)
	if [ -n "$url" ]; then
		tag=$(core_installer_tag_from_url "$url" 2> /dev/null)
		if [ -n "$tag" ]; then
			printf '%s\n' "$tag"
			return 0
		fi
	fi

	_core_installer_log "Редирект GitHub не разобрался, иду в API" "warn"

	json=$(_core_installer_api_get "$(core_installer_api_latest_url)" 2> /dev/null)
	tag=$(core_installer_tag_from_api "$json" 2> /dev/null)
	if [ -n "$tag" ]; then
		printf '%s\n' "$tag"
		return 0
	fi

	_core_installer_fail "Не удалось узнать последнюю версию clash-rs"
	return 1
}

#######################################
# Есть ли в релизе ассет под нашу платформу.
# Зовётся только при разборе неудачи: обычный путь установки списка ассетов не
# запрашивает вовсе, чтобы не тратить лимит API на то, что и так видно по коду
# ответа при скачивании.
# Arguments:
#   tag, triplet
#######################################
core_installer_asset_available() {
	local tag="$1" triplet="$2" json names

	json=$(_core_installer_api_get "$(core_installer_api_release_url "$tag")" 2> /dev/null)
	names=$(core_installer_assets_from_api "$json" 2> /dev/null) || return 1

	printf '%s\n' "$names" | core_installer_select_asset "$triplet" > /dev/null
}

# Почему не скачалось: нет ассета или проблема со связью. Ответ идёт в лог,
# потому что разница для пользователя принципиальная - во втором случае надо
# просто повторить.
_core_installer_explain_download_failure() {
	local tag="$1" triplet="$2"

	if core_installer_asset_available "$tag" "$triplet"; then
		_core_installer_log "Ассет в релизе $tag есть - похоже, не хватило связи с GitHub" "error"
	else
		_core_installer_log "В релизе $tag нет ассета $(core_installer_asset_name "$triplet")" "error"
	fi
}

## --- установка ---------------------------------------------------------------

#######################################
# Поставить clash-rs.
#
# Под работающим сервисом ничего не подменяется: mv поверх работающего файла в
# лучшем случае даст ETXTBSY, в худшем - оставит процесс с половиной старого
# ядра в памяти и новым на диске. Останавливать сервис молча установщик тоже не
# должен: он не знает, что через этот роутер сейчас идёт. Останавливает
# core_installer_update, который зовут осознанно.
#
# Arguments:
#   tag: тег релиза (необязательно, иначе последний)
#   force: 1 - ставить, даже если такая версия уже стоит
# Returns:
#   0 успех, 2 платформа, 3 сервис запущен, 4 сеть/релиз, 5 проверка не прошла
#######################################
core_installer_install() {
	local tag="$1" force="$2"
	local triplet dest version installed url tmp asset

	triplet=$(core_installer_platform) || return 2

	dest=$(core_installer_dest)

	if _core_installer_service_running "$(core_installer_service)" "$(basename "$dest")"; then
		_core_installer_fail "Сервис $(core_installer_service) запущен: остановите его или зовите core_installer_update"
		return 3
	fi

	if [ -z "$tag" ]; then
		tag=$(core_installer_latest_tag) || return 4
	fi

	version=$(core_installer_version_of_tag "$tag") || return 4

	installed=$(core_installer_installed_version 2> /dev/null)
	if [ "$force" != "1" ] && [ -n "$installed" ] && [ "$installed" = "$version" ]; then
		_core_installer_log "clash-rs $version уже установлен, скачивать нечего" "info"
		return 0
	fi

	asset=$(core_installer_asset_name "$triplet") || return 2
	url=$(core_installer_asset_url "$tag" "$triplet") || return 2

	mkdir -p "$CORE_INSTALLER_WORK_DIR" 2> /dev/null || {
		_core_installer_fail "Не удалось создать $CORE_INSTALLER_WORK_DIR"
		return 1
	}
	tmp="$CORE_INSTALLER_WORK_DIR/$asset"
	rm -f "$tmp"

	_core_installer_log "Качаю clash-rs $version ($triplet) из $url" "info"
	if ! _core_installer_download "$url" "$tmp"; then
		rm -f "$tmp"
		_core_installer_explain_download_failure "$tag" "$triplet"
		_core_installer_fail "Не удалось скачать $asset из релиза $tag"
		return 4
	fi

	if ! core_installer_verify_binary "$tmp" "$version" > /dev/null; then
		rm -f "$tmp"
		_core_installer_log "Проверка не пройдена, установленное ядро не тронуто" "error"
		return 5
	fi

	if ! core_installer_swap "$tmp" "$dest"; then
		rm -f "$tmp"
		return 5
	fi
	rm -f "$tmp"

	_core_installer_log "clash-rs $version установлен в $dest" "info"
	return 0
}

#######################################
# Обновить ядро: остановить сервис, поставить, вернуть как было.
# Сервис поднимается обратно в любом случае, включая неудачу установки: после
# отката на месте лежит рабочий прежний бинарник, и оставлять роутер без ядра
# из-за неудавшегося обновления нельзя.
# Arguments:
#   tag, force - как у core_installer_install
#######################################
core_installer_update() {
	local tag="$1" force="$2"
	local service dest was_running=0 rc version installed

	service=$(core_installer_service)
	dest=$(core_installer_dest)

	if [ -z "$tag" ]; then
		tag=$(core_installer_latest_tag) || return 4
	fi
	version=$(core_installer_version_of_tag "$tag") || return 4

	# Сверяемся с установленным ДО остановки сервиса. Иначе обновление, которому
	# нечего делать, всё равно рвало бы соединения: остановили, выяснили, что
	# версия та же, подняли обратно.
	installed=$(core_installer_installed_version 2> /dev/null)
	if [ "$force" != "1" ] && [ -n "$installed" ] && [ "$installed" = "$version" ]; then
		_core_installer_log "clash-rs $version уже установлен, обновлять нечего" "info"
		return 0
	fi

	if _core_installer_service_running "$service" "$(basename "$dest")"; then
		was_running=1
		_core_installer_log "Останавливаю $service на время подмены ядра" "info"
		"$service" stop > /dev/null 2>&1
	fi

	core_installer_install "$tag" "$force"
	rc=$?

	if [ "$was_running" = "1" ]; then
		"$service" start > /dev/null 2>&1
	fi

	return "$rc"
}
