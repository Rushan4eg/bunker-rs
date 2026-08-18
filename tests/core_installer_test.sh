#!/bin/sh
# Тесты установщика ядра clash-rs.
#
# Сеть не трогается вовсе. Установщик написан так, что наружу торчат ровно
# четыре тонкие обёртки - _core_installer_resolve_url, _core_installer_api_get,
# _core_installer_download и _core_installer_service_running (через заглушку
# init-скрипта), и здесь все они подменены. Остальное - чистые функции:
# определение платформы, сборка URL, разбор ответа API, сравнение версий.
#
# Проверять установщик на живом GitHub нельзя не из принципа: анонимный API
# даёт 60 запросов в час на IP, и набор тестов, гоняемый в CI на каждый пуш,
# выбрал бы лимит за полдня - причём краснеть начали бы чужие сборки.
#
# shellcheck shell=sh
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- заглушка uci -----------------------------------------------------------
# Значение через файл: core_current зовётся в том числе из $( ), а подоболочка
# переменных наружу не отдаёт.
UCI_CORE_FILE="$TMP/uci_core"
printf 'clash-rs' >"$UCI_CORE_FILE"

uci() {
	case "$*" in
	*podkop.settings.core*) cat "$UCI_CORE_FILE" ;;
	*podkop.settings.config_path*) cat "$TMP/uci_path" 2>/dev/null ;;
	*) return 1 ;;
	esac
}

set_core() { printf '%s' "$1" >"$UCI_CORE_FILE"; }

# --- заглушка init-скрипта ядра ---------------------------------------------
# Состояние в файле, а не в переменной: скрипт исполняется отдельным процессом,
# и `stop` должен быть виден следующей проверке `running` - иначе не проверить
# core_installer_update, который на этом переходе и построен.
SERVICE_LOG="$TMP/service.log"
SERVICE_RUNNING_FILE="$TMP/service_running"
export SERVICE_LOG SERVICE_RUNNING_FILE
: >"$SERVICE_LOG"

CORE_CR_SERVICE="$TMP/clash-rs.init"
cat >"$CORE_CR_SERVICE" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$1" >> "$SERVICE_LOG"
case "$1" in
running) exit "$(cat "$SERVICE_RUNNING_FILE" 2>/dev/null || echo 1)" ;;
stop) echo 1 > "$SERVICE_RUNNING_FILE" ;;
start) echo 0 > "$SERVICE_RUNNING_FILE" ;;
esac
exit 0
EOF
chmod +x "$CORE_CR_SERVICE"

# 0 - сервис запущен, 1 - нет (код возврата `running`, как у procd)
set_service_running() { printf '%s\n' "$1" >"$SERVICE_RUNNING_FILE"; }
set_service_running 1

# --- подключение модулей ----------------------------------------------------
# Порядок тот же, что в /usr/bin/podkop: сначала списки правил (в них живёт
# скачивание с ретраями), потом слой ядра, потом установщик.
. "$DIR/../podkop/files/usr/lib/clash_rulesets.sh"
. "$DIR/../podkop/files/usr/lib/core.sh"
. "$DIR/../podkop/files/usr/lib/core_installer.sh"

# Переопределяем после подключения: в модулях стоят значения по умолчанию
CORE_CR_SERVICE="$TMP/clash-rs.init"
CORE_CR_BIN="$TMP/bin/clash-rs-test"
CORE_CR_MIN_VERSION="0.10.0"

CORE_INSTALLER_WORK_DIR="$TMP/work"
CORE_INSTALLER_RELEASE_FILE="$TMP/openwrt_release"
# Заглушка «бинарника» - это shell-скрипт в три десятка байт, настоящая нижняя
# граница отсекла бы её раньше проверок, которые мы и хотим увидеть
CORE_INSTALLER_MIN_BYTES=1

DEST="$TMP/bin/clash-rs-test"
BACKUP="$DEST.podkop-bak"
mkdir -p "$TMP/bin"

# Роутер, под который всё это писалось: mediatek/filogic, aarch64_cortex-a53
cat >"$TMP/openwrt_release" <<'EOF'
DISTRIB_ID='OpenWrt'
DISTRIB_RELEASE='24.10.0'
DISTRIB_REVISION='r28427-6df0e3d02a'
DISTRIB_TARGET='mediatek/filogic'
DISTRIB_ARCH='aarch64_cortex-a53'
EOF

cat >"$TMP/openwrt_release_ppc" <<'EOF'
DISTRIB_ARCH='powerpc_8540'
EOF

# --- служебное --------------------------------------------------------------

count_lines_file() {
	[ -s "$1" ] || {
		echo 0
		return 0
	}
	grep -c '' "$1"
}

# Заглушка ядра: отвечает на -v тем же форматом, что настоящий clash-rs
mk_core_bin() {
	cat >"$1" <<EOF
#!/bin/sh
echo "clash-rs v$2"
EOF
	chmod +x "$1"
}

# Ответ GitHub API - урезанный до используемых полей, имена ассетов настоящие
API_JSON='{"tag_name":"v0.10.8","assets":[
	{"name":"clash-rs-aarch64-unknown-linux-musl"},
	{"name":"clash-rs-armv7-unknown-linux-musleabihf"},
	{"name":"clash-rs-mipsel-unknown-linux-musl"},
	{"name":"clash-rs-x86_64-unknown-linux-gnu"},
	{"name":"clash-rs-x86_64-unknown-linux-gnu-static-crt"},
	{"name":"clash-rs-x86_64-unknown-linux-musl"},
	{"name":"LICENSE"}]}'

# ======================== определение платформы =============================

it "aarch64_cortex-a53 - роутер, ради которого всё затевалось"
assert_eq "aarch64-unknown-linux-musl" "$(core_installer_triplet aarch64_cortex-a53)"

it "aarch64_cortex-a72"
assert_eq "aarch64-unknown-linux-musl" "$(core_installer_triplet aarch64_cortex-a72)"

it "aarch64_generic"
assert_eq "aarch64-unknown-linux-musl" "$(core_installer_triplet aarch64_generic)"

it "голый aarch64 из uname -m"
assert_eq "aarch64-unknown-linux-musl" "$(core_installer_triplet aarch64)"

it "arm_cortex-a7 - самый массовый 32-битный ARM в OpenWrt"
assert_eq "armv7-unknown-linux-musleabihf" "$(core_installer_triplet arm_cortex-a7)"

it "arm_cortex-a7_neon-vfpv4"
assert_eq "armv7-unknown-linux-musleabihf" "$(core_installer_triplet arm_cortex-a7_neon-vfpv4)"

it "arm_cortex-a9_vfpv3-d16"
assert_eq "armv7-unknown-linux-musleabihf" "$(core_installer_triplet arm_cortex-a9_vfpv3-d16)"

it "arm_cortex-a15_neon-vfpv4"
assert_eq "armv7-unknown-linux-musleabihf" "$(core_installer_triplet arm_cortex-a15_neon-vfpv4)"

it "armv7l из uname -m"
assert_eq "armv7-unknown-linux-musleabihf" "$(core_installer_triplet armv7l)"

it "mipsel_24kc - ramips"
assert_eq "mipsel-unknown-linux-musl" "$(core_installer_triplet mipsel_24kc)"

it "голый mipsel"
assert_eq "mipsel-unknown-linux-musl" "$(core_installer_triplet mipsel)"

it "mips_24kc - big-endian ath79"
assert_eq "mips-unknown-linux-musl" "$(core_installer_triplet mips_24kc)"

it "mips_4kec"
assert_eq "mips-unknown-linux-musl" "$(core_installer_triplet mips_4kec)"

it "x86_64"
assert_eq "x86_64-unknown-linux-musl" "$(core_installer_triplet x86_64)"

it "i386_pentium4 - 32-битный x86"
assert_eq "i686-unknown-linux-musl" "$(core_installer_triplet i386_pentium4)"

it "i686 из uname -m"
assert_eq "i686-unknown-linux-musl" "$(core_installer_triplet i686)"

# --- платформы, под которые ассета нет --------------------------------------

it "неизвестная архитектура - ненулевой код возврата"
core_installer_triplet powerpc_8540 >/dev/null 2>&1
assert_eq "1" "$?"

it "неизвестная архитектура называется в ошибке, а не проваливается молча"
msg=$(core_installer_triplet powerpc_8540 2>&1 >/dev/null)
assert_contains "powerpc_8540" "$msg"

it "armv6 отвергается: ассеты начинаются с armv7"
core_installer_triplet arm_arm1176jzf-s_vfp >/dev/null 2>&1
assert_eq "1" "$?"

it "и объясняет, почему именно"
msg=$(core_installer_triplet arm_arm1176jzf-s_vfp 2>&1 >/dev/null)
assert_contains "armv7" "$msg"

it "riscv64 отвергается: в релизах только gnu-сборка"
core_installer_triplet riscv64_riscv64 >/dev/null 2>&1
assert_eq "1" "$?"

it "про riscv64 в ошибке сказано про musl"
msg=$(core_installer_triplet riscv64_riscv64 2>&1 >/dev/null)
assert_contains "musl" "$msg"

it "mips64 не выдаётся за 32-битный mips"
core_installer_triplet mips64_octeonplus >/dev/null 2>&1
assert_eq "1" "$?"

it "пустая архитектура - ошибка"
core_installer_triplet "" >/dev/null 2>&1
assert_eq "1" "$?"

# --- источник архитектуры ---------------------------------------------------

it "архитектура читается из /etc/openwrt_release"
assert_eq "aarch64_cortex-a53" "$(core_installer_arch)"

it "кавычки вокруг значения снимаются"
printf 'DISTRIB_ARCH=x86_64\n' >"$TMP/release_bare"
r=$(CORE_INSTALLER_RELEASE_FILE="$TMP/release_bare" core_installer_arch)
assert_eq "x86_64" "$r"

it "без openwrt_release работает фолбэк на uname -m"
r=$(CORE_INSTALLER_RELEASE_FILE="$TMP/нет-такого-файла" core_installer_arch)
assert_eq "$(uname -m)" "$r"

it "платформа целиком: файл роутера -> триплет"
assert_eq "aarch64-unknown-linux-musl" "$(core_installer_platform)"

it "платформа на неподдержанной арке даёт ошибку"
(CORE_INSTALLER_RELEASE_FILE="$TMP/openwrt_release_ppc" core_installer_platform) >/dev/null 2>&1
assert_eq "1" "$?"

# ======================== сборка адресов ====================================

it "имя ассета - clash-rs-<триплет>, без расширения и без архива"
assert_eq "clash-rs-aarch64-unknown-linux-musl" \
	"$(core_installer_asset_name aarch64-unknown-linux-musl)"

it "имя ассета без триплета не собирается"
core_installer_asset_name "" >/dev/null 2>&1
assert_eq "1" "$?"

it "ссылка на ассет конкретного релиза"
assert_eq "https://github.com/Watfaq/clash-rs/releases/download/v0.10.8/clash-rs-aarch64-unknown-linux-musl" \
	"$(core_installer_asset_url v0.10.8 aarch64-unknown-linux-musl)"

it "ссылка на ассет для armv7"
assert_eq "https://github.com/Watfaq/clash-rs/releases/download/v0.10.8/clash-rs-armv7-unknown-linux-musleabihf" \
	"$(core_installer_asset_url v0.10.8 armv7-unknown-linux-musleabihf)"

it "без тега ссылка на ассет не собирается"
core_installer_asset_url "" aarch64-unknown-linux-musl >/dev/null 2>&1
assert_eq "1" "$?"

it "ссылка на последний релиз идёт через redirect-путь, минуя API"
assert_eq "https://github.com/Watfaq/clash-rs/releases/latest/download/clash-rs-mipsel-unknown-linux-musl" \
	"$(core_installer_latest_asset_url mipsel-unknown-linux-musl)"

it "адрес страницы последнего релиза"
assert_eq "https://github.com/Watfaq/clash-rs/releases/latest" "$(core_installer_latest_url)"

it "адрес API последнего релиза"
assert_eq "https://api.github.com/repos/Watfaq/clash-rs/releases/latest" \
	"$(core_installer_api_latest_url)"

it "адрес API конкретного релиза"
assert_eq "https://api.github.com/repos/Watfaq/clash-rs/releases/tags/v0.10.8" \
	"$(core_installer_api_release_url v0.10.8)"

it "репозиторий переопределяется снаружи"
r=$(CORE_INSTALLER_REPO="fork/clash-rs" core_installer_latest_url)
assert_eq "https://github.com/fork/clash-rs/releases/latest" "$r"

# ======================== разбор редиректа ==================================

it "тег из адреса страницы релиза"
assert_eq "v0.10.8" \
	"$(core_installer_tag_from_url https://github.com/Watfaq/clash-rs/releases/tag/v0.10.8)"

it "тег из адреса ассета"
assert_eq "v0.10.8" \
	"$(core_installer_tag_from_url https://github.com/Watfaq/clash-rs/releases/download/v0.10.8/clash-rs-aarch64-unknown-linux-musl)"

it "хвост запроса в тег не попадает"
assert_eq "v0.10.8" \
	"$(core_installer_tag_from_url 'https://github.com/Watfaq/clash-rs/releases/tag/v0.10.8?utm=1')"

it "якорь в тег не попадает"
assert_eq "v0.10.8" \
	"$(core_installer_tag_from_url 'https://github.com/Watfaq/clash-rs/releases/tag/v0.10.8#assets')"

it "адрес без тега - ошибка, а не пустая строка за версию"
core_installer_tag_from_url "https://github.com/Watfaq/clash-rs" >/dev/null 2>&1
assert_eq "1" "$?"

it "пустой адрес - ошибка"
core_installer_tag_from_url "" >/dev/null 2>&1
assert_eq "1" "$?"

it "оборванный адрес без самого тега - ошибка"
core_installer_tag_from_url "https://github.com/Watfaq/clash-rs/releases/tag/" >/dev/null 2>&1
assert_eq "1" "$?"

# ======================== разбор ответа API =================================

it "тег из ответа API"
assert_eq "v0.10.8" "$(core_installer_tag_from_api "$API_JSON")"

it "битый JSON тегом не притворяется"
core_installer_tag_from_api "{не json" >/dev/null 2>&1
assert_eq "1" "$?"

it "пустой ответ - ошибка"
core_installer_tag_from_api "" >/dev/null 2>&1
assert_eq "1" "$?"

it "ответ без tag_name - ошибка"
core_installer_tag_from_api '{"assets":[]}' >/dev/null 2>&1
assert_eq "1" "$?"

it "имена ассетов вынимаются все"
printf '%s' "$(core_installer_assets_from_api "$API_JSON")" >"$TMP/assets"
assert_eq "7" "$(count_lines_file "$TMP/assets")"

it "среди ассетов есть сборка под aarch64"
assert_contains "clash-rs-aarch64-unknown-linux-musl" "$(core_installer_assets_from_api "$API_JSON")"

it "ответ без assets - ошибка"
core_installer_assets_from_api '{"tag_name":"v1"}' >/dev/null 2>&1
assert_eq "1" "$?"

it "ассет под платформу находится в списке"
r=$(core_installer_assets_from_api "$API_JSON" | core_installer_select_asset aarch64-unknown-linux-musl)
assert_eq "clash-rs-aarch64-unknown-linux-musl" "$r"

it "совпадение точное: gnu не выдаётся за gnu-static-crt"
r=$(core_installer_assets_from_api "$API_JSON" | core_installer_select_asset x86_64-unknown-linux-gnu)
assert_eq "clash-rs-x86_64-unknown-linux-gnu" "$r"

it "ассета под платформу нет - ненулевой код"
core_installer_assets_from_api "$API_JSON" | core_installer_select_asset riscv64gc-unknown-linux-musl >/dev/null 2>&1
assert_eq "1" "$?"

it "поиск по пустому списку - ненулевой код"
printf '' | core_installer_select_asset aarch64-unknown-linux-musl >/dev/null 2>&1
assert_eq "1" "$?"

# ======================== версии ============================================

it "тег v0.10.8 - это версия 0.10.8"
assert_eq "0.10.8" "$(core_installer_version_of_tag v0.10.8)"

it "тег без ведущей v тоже понимается"
assert_eq "0.10.8" "$(core_installer_version_of_tag 0.10.8)"

it "пустой тег - ошибка"
core_installer_version_of_tag "" >/dev/null 2>&1
assert_eq "1" "$?"

it "0.10.8 не младше 0.10.0"
core_installer_version_ge 0.10.8 0.10.0 && r=да || r=нет
assert_eq "да" "$r"

it "равные версии проходят"
core_installer_version_ge 0.10.0 0.10.0 && r=да || r=нет
assert_eq "да" "$r"

it "0.9.9 младше 0.10.0 - сравнение числовое, а не строковое"
core_installer_version_ge 0.9.9 0.10.0 && r=да || r=нет
assert_eq "нет" "$r"

it "пустая версия не проходит проверку"
core_installer_version_ge "" 0.10.0 && r=да || r=нет
assert_eq "нет" "$r"

# ======================== проверка файла ====================================
# Настоящая проверка магии ELF - здесь, до того как её подменят заглушкой:
# дальше «скачанный бинарник» будет shell-скриптом, и ELF в нём взяться неоткуда.

ELF="$TMP/fake.elf"
printf '\177ELF\002\001\001\000' >"$ELF"
printf 'заполнение\n' >>"$ELF"

it "файл с магией ELF опознаётся"
core_installer_is_elf "$ELF" && r=да || r=нет
assert_eq "да" "$r"

it "HTML-страница ошибки GitHub за бинарник не проходит"
printf '<!DOCTYPE html><html>Not Found</html>' >"$TMP/notfound.html"
core_installer_is_elf "$TMP/notfound.html" && r=да || r=нет
assert_eq "нет" "$r"

it "пустой файл не ELF"
: >"$TMP/zero"
core_installer_is_elf "$TMP/zero" && r=да || r=нет
assert_eq "нет" "$r"

it "несуществующего файла не ELF"
core_installer_is_elf "$TMP/нет-такого" && r=да || r=нет
assert_eq "нет" "$r"

# ======================== стыковка со слоем ядра ============================

it "путь установки берётся из слоя ядра (CORE_CR_BIN)"
assert_eq "$DEST" "$(core_installer_dest)"

it "голое имя ядра превращается в путь внутри каталога установки"
r=$(CORE_CR_BIN=clash-rs CORE_INSTALLER_BIN_DIR=/usr/bin core_installer_dest)
assert_eq "/usr/bin/clash-rs" "$r"

it "каталог установки переопределяется - для роутеров с крошечным overlay"
r=$(CORE_CR_BIN=clash-rs CORE_INSTALLER_BIN_DIR=/tmp core_installer_dest)
assert_eq "/tmp/clash-rs" "$r"

# Важнее, чем выглядит: core_binary отдаёт АКТИВНОЕ ядро, и возьми установщик
# её - при выбранном sing-box он положил бы clash-rs поверх чужого бинарника.
it "при активном sing-box установщик всё равно целится в clash-rs"
set_core "sing-box"
assert_eq "$DEST" "$(core_installer_dest)"

it "и init-скрипт берёт клэшевый, а не активного ядра"
assert_eq "$CORE_CR_SERVICE" "$(core_installer_service)"
set_core "clash-rs"

it "минимальная версия берётся из слоя ядра"
assert_eq "0.10.0" "$(core_installer_min_version)"

it "путь бэкапа лежит рядом с бинарником, а не в /tmp"
assert_eq "$BACKUP" "$(core_installer_backup_path)"

# ======================== делегирование скачивания ==========================
# Проверяется до подмены обёртки: установщик обязан звать clash_rs_download_list
# из clash_rulesets.sh, а не заводить второй механизм ретраев под 429.

it "скачивание делегируется clash_rs_download_list"
out=$(
	clash_rs_download_list() { printf 'url=%s dst=%s retries=%s' "$1" "$2" "$4"; }
	CORE_INSTALLER_RETRIES=4 _core_installer_download "https://example/asset" "$TMP/none"
)
assert_contains "url=https://example/asset" "$out"

it "и получает число попыток из настройки установщика"
assert_contains "retries=4" "$out"

# ======================== место на диске ====================================

it "нехватка места видна до подмены"
core_installer_has_space "$TMP" 999999999999 && r=да || r=нет
assert_eq "нет" "$r"

it "места хватает - проверка не мешает"
core_installer_has_space "$TMP" 1 && r=да || r=нет
assert_eq "да" "$r"

it "нечитаемый вывод df установку не блокирует"
r=$(
	_core_installer_free_kb() { printf ''; }
	core_installer_has_space "$TMP" 999999999999 && echo да || echo нет
)
assert_eq "да" "$r"

# ======================== заглушки сети =====================================
# Дальше идёт установка целиком. Всё, что стучится наружу, подменено здесь.

RESOLVE_OUT="$TMP/resolve_out"
RESOLVE_LOG="$TMP/resolve.log"
API_OUT="$TMP/api_out"
API_LOG="$TMP/api.log"
DL_PAYLOAD="$TMP/payload"
DL_RC_FILE="$TMP/dl_rc"
DL_LOG="$TMP/download.log"

: >"$RESOLVE_LOG"
: >"$API_LOG"
: >"$DL_LOG"
echo 0 >"$DL_RC_FILE"
printf '%s' "$API_JSON" >"$API_OUT"

_core_installer_resolve_url() {
	printf '%s\n' "$1" >>"$RESOLVE_LOG"
	cat "$RESOLVE_OUT" 2>/dev/null
}

_core_installer_api_get() {
	printf '%s\n' "$1" >>"$API_LOG"
	cat "$API_OUT" 2>/dev/null
}

_core_installer_download() {
	local rc
	printf '%s\n' "$1" >>"$DL_LOG"
	rc=$(cat "$DL_RC_FILE" 2>/dev/null)
	[ "$rc" = "0" ] || return "$rc"
	cp "$DL_PAYLOAD" "$2"
	chmod 0755 "$2"
}

# Заглушка ядра - shell-скрипт, магии ELF в нём нет. Настоящая проверка магии
# уже сделана выше на отдельном файле.
core_installer_is_elf() { [ -s "$1" ]; }

set_redirect_tag() {
	printf 'https://github.com/Watfaq/clash-rs/releases/tag/%s\n' "$1" >"$RESOLVE_OUT"
}

reset_logs() {
	: >"$RESOLVE_LOG"
	: >"$API_LOG"
	: >"$DL_LOG"
	: >"$SERVICE_LOG"
}

# ======================== получение тега ====================================

it "тег берётся из редиректа"
set_redirect_tag v0.10.8
reset_logs
assert_eq "v0.10.8" "$(core_installer_latest_tag)"

it "редирект сработал - в API не ходим вовсе"
assert_eq "0" "$(count_lines_file "$API_LOG")"

it "редирект не разобрался - фолбэк на API"
: >"$RESOLVE_OUT"
reset_logs
assert_eq "v0.10.8" "$(core_installer_latest_tag)"

it "и API был запрошен ровно один раз"
assert_eq "1" "$(count_lines_file "$API_LOG")"

it "не отвечает ни редирект, ни API - ошибка"
: >"$RESOLVE_OUT"
: >"$API_OUT"
core_installer_latest_tag >/dev/null 2>&1
assert_eq "1" "$?"

printf '%s' "$API_JSON" >"$API_OUT"
set_redirect_tag v0.10.8

# ======================== установка =========================================

it "чистая установка проходит"
rm -f "$DEST" "$BACKUP"
mk_core_bin "$DL_PAYLOAD" "0.10.8"
set_service_running 1
reset_logs
core_installer_install
assert_eq "0" "$?"

it "бинарник лежит на месте и отвечает нужной версией"
assert_eq "0.10.8" "$(core_installer_probe_version "$DEST")"

it "скачивание было ровно одно"
assert_eq "1" "$(count_lines_file "$DL_LOG")"

it "качали ассет нужного релиза под нужную платформу"
assert_contains "releases/download/v0.10.8/clash-rs-aarch64-unknown-linux-musl" "$(cat "$DL_LOG")"

it "временный файл после установки не остаётся"
[ -e "$CORE_INSTALLER_WORK_DIR/clash-rs-aarch64-unknown-linux-musl" ] && r=да || r=нет
assert_eq "нет" "$r"

it "промежуточный staged-файл тоже убран"
[ -e "$DEST.podkop-new" ] && r=да || r=нет
assert_eq "нет" "$r"

# --- повторная установка ----------------------------------------------------

it "повторная установка той же версии не качает заново"
reset_logs
core_installer_install
assert_eq "0" "$(count_lines_file "$DL_LOG")"

it "и всё равно отвечает успехом"
reset_logs
core_installer_install
assert_eq "0" "$?"

it "с флагом force скачивание происходит"
reset_logs
core_installer_install "" "1"
assert_eq "1" "$(count_lines_file "$DL_LOG")"

# --- обновление с бэкапом ---------------------------------------------------

it "обновление до новой версии проходит"
mk_core_bin "$DL_PAYLOAD" "0.10.9"
set_redirect_tag v0.10.9
reset_logs
core_installer_install
assert_eq "0" "$?"

it "на месте новая версия"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "предыдущий бинарник сохранён в бэкап"
assert_eq "0.10.8" "$(core_installer_probe_version "$BACKUP")"

# --- работающий сервис ------------------------------------------------------

it "под работающим сервисом установка отменяется"
set_service_running 0
mk_core_bin "$DL_PAYLOAD" "0.11.0"
set_redirect_tag v0.11.0
reset_logs
core_installer_install
assert_eq "3" "$?"

it "и до скачивания дело не доходит"
assert_eq "0" "$(count_lines_file "$DL_LOG")"

it "установленное ядро при этом не тронуто"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "отказ объясняется человеку, а не только кодом возврата"
msg=$(core_installer_install 2>&1 >/dev/null)
assert_contains "запущен" "$msg"

set_service_running 1

# --- негодный бинарник ------------------------------------------------------

it "бинарник, не отвечающий на -v, не устанавливается"
cat >"$DL_PAYLOAD" <<'EOF'
#!/bin/sh
echo "куда-то не туда"
EOF
chmod 0755 "$DL_PAYLOAD"
set_redirect_tag v0.11.0
reset_logs
core_installer_install
assert_eq "5" "$?"

it "после неудачной проверки на месте остаётся прежнее ядро"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "и бэкап не перезаписан мусором"
assert_eq "0.10.8" "$(core_installer_probe_version "$BACKUP")"

it "версия младше минимальной не устанавливается"
mk_core_bin "$DL_PAYLOAD" "0.9.9"
set_redirect_tag v0.9.9
reset_logs
core_installer_install
assert_eq "5" "$?"

it "прежнее ядро на месте и после этого"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "версия в ассете не совпала с тегом - установка отменяется"
mk_core_bin "$DL_PAYLOAD" "0.10.5"
set_redirect_tag v0.11.0
reset_logs
core_installer_install
assert_eq "5" "$?"

it "слишком маленький файл отбрасывается по размеру"
mk_core_bin "$DL_PAYLOAD" "0.11.0"
r=$(
	CORE_INSTALLER_MIN_BYTES=104857600
	core_installer_verify_binary "$DL_PAYLOAD" >/dev/null 2>&1 && echo да || echo нет
)
assert_eq "нет" "$r"

it "проверка годного файла отдаёт его версию"
assert_eq "0.11.0" "$(core_installer_verify_binary "$DL_PAYLOAD")"

# --- неудача скачивания -----------------------------------------------------

it "не скачалось - код 4"
echo 1 >"$DL_RC_FILE"
set_redirect_tag v0.11.0
reset_logs
core_installer_install
assert_eq "4" "$?"

it "после неудачного скачивания ядро на месте"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "неудача разбирается по списку ассетов релиза"
assert_contains "releases/tags/v0.11.0" "$(cat "$API_LOG")"

echo 0 >"$DL_RC_FILE"

# --- неподдержанная платформа -----------------------------------------------

it "на неподдержанной платформе установка не начинается"
r=$(
	CORE_INSTALLER_RELEASE_FILE="$TMP/openwrt_release_ppc"
	core_installer_install >/dev/null 2>&1
	echo "$?"
)
assert_eq "2" "$r"

it "и сеть при этом не трогается"
reset_logs
(
	CORE_INSTALLER_RELEASE_FILE="$TMP/openwrt_release_ppc"
	core_installer_install
) >/dev/null 2>&1
assert_eq "0" "$(count_lines_file "$DL_LOG")"

# ======================== откат =============================================

it "откат возвращает бинарник из бэкапа"
mk_core_bin "$DEST" "0.11.0"
mk_core_bin "$BACKUP" "0.10.9"
core_installer_rollback "$DEST"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "после отката бинарник исполняемый"
[ -x "$DEST" ] && r=да || r=нет
assert_eq "да" "$r"

it "откат без бэкапа - честная ошибка, а не порча файла"
rm -f "$BACKUP"
core_installer_rollback "$DEST" >/dev/null 2>&1
assert_eq "1" "$?"

it "и бинарник при этом не пострадал"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

it "подмена на неработающий бинарник откатывается сама"
mk_core_bin "$BACKUP" "0.10.9"
printf 'не бинарник\n' >"$TMP/broken"
chmod 0755 "$TMP/broken"
core_installer_swap "$TMP/broken" "$DEST" >/dev/null 2>&1
assert_eq "1" "$?"

it "после самостоятельного отката работает прежняя версия"
assert_eq "0.10.9" "$(core_installer_probe_version "$DEST")"

# ======================== обновление с сервисом =============================

it "обновление останавливает работающий сервис"
mk_core_bin "$DEST" "0.10.9"
mk_core_bin "$DL_PAYLOAD" "0.11.0"
set_redirect_tag v0.11.0
set_service_running 0
reset_logs
core_installer_update
assert_contains "stop" "$(cat "$SERVICE_LOG")"

it "и поднимает его обратно"
assert_contains "start" "$(cat "$SERVICE_LOG")"

it "новая версия установлена"
assert_eq "0.11.0" "$(core_installer_probe_version "$DEST")"

it "обновление при остановленном сервисе его не запускает"
mk_core_bin "$DL_PAYLOAD" "0.11.1"
set_redirect_tag v0.11.1
set_service_running 1
reset_logs
core_installer_update
assert_not_contains "start" "$(cat "$SERVICE_LOG")"

it "но версию всё равно ставит"
assert_eq "0.11.1" "$(core_installer_probe_version "$DEST")"

# Ради этого проверка версии в core_installer_update и вынесена ДО остановки:
# иначе обновление, которому нечего делать, рвало бы живые соединения.
it "обновление до уже установленной версии не трогает сервис"
set_service_running 0
reset_logs
core_installer_update
assert_eq "" "$(cat "$SERVICE_LOG")"

it "и не качает ничего"
assert_eq "0" "$(count_lines_file "$DL_LOG")"

it "возвращая при этом успех"
set_service_running 0
core_installer_update
assert_eq "0" "$?"

it "с force обновление рвётся к работе даже на той же версии"
set_service_running 0
reset_logs
core_installer_update "" "1"
assert_eq "1" "$(count_lines_file "$DL_LOG")"

it "и сервис при этом всё-таки перезапущен"
assert_contains "stop" "$(cat "$SERVICE_LOG")"

# ======================== состояние =========================================

it "установленное ядро видно"
core_installer_is_installed && r=да || r=нет
assert_eq "да" "$r"

it "версия установленного читается через слой ядра"
set_core "clash-rs"
assert_eq "0.11.1" "$(core_installer_installed_version)"

it "и читается даже когда активное ядро - sing-box"
set_core "sing-box"
assert_eq "0.11.1" "$(core_installer_installed_version)"
set_core "clash-rs"

it "снесённое ядро не выдумывает версию"
rm -f "$DEST"
core_installer_installed_version >/dev/null 2>&1
assert_eq "1" "$?"

it "и не считается установленным"
core_installer_is_installed && r=да || r=нет
assert_eq "нет" "$r"

finish
