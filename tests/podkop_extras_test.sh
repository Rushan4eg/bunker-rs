#!/bin/sh
# Тесты двух ядронезависимых фич: блокировки DoH и действия Bypass.
#
# Обе фичи упираются в nft и в uci, которых на машине разработчика нет.
# Поэтому uci подменяется заглушкой (как в core_test.sh), а применение правил -
# одной тонкой функцией _podkop_extras_nft_apply, которая вместо роутера пишет
# скрипт в файл. Всё, что проверяется ниже, - это текст правил, а он должен
# получаться одинаковым что на роутере, что здесь.
#
# shellcheck shell=sh
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- заглушка uci -----------------------------------------------------------
# Значения через файлы: генераторы зовутся внутри $( ), из подоболочки обычную
# переменную назад не отдать.
: >"$TMP/block_doh"
: >"$TMP/section_action"

uci() {
	case "$1 $2" in
	"-q get")
		case "$3" in
		podkop.settings.block_doh) cat "$TMP/block_doh" 2>/dev/null ;;
		podkop.*.connection_type) cat "$TMP/section_action" 2>/dev/null ;;
		*) return 1 ;;
		esac
		;;
	"-q show") cat "$TMP/uci_show" 2>/dev/null ;;
	*) return 1 ;;
	esac
	return 0
}

set_block_doh() { printf '%s' "$1" >"$TMP/block_doh"; }
set_section_action() { printf '%s' "$1" >"$TMP/section_action"; }
set_uci_show() { printf '%s\n' "$1" >"$TMP/uci_show"; }

. "$(dirname "$0")/../podkop/files/usr/lib/podkop_extras.sh"

# --- заглушка nft -----------------------------------------------------------
# Переопределяем после подключения: в модуле стоит настоящая, зовущая nft.
NFT_SCRIPT="$TMP/nft_script"
: >"$NFT_SCRIPT"

_podkop_extras_nft_apply() {
	printf '%s\n' "$1" >"$NFT_SCRIPT"
	cat "$TMP/nft_rc" 2>/dev/null | grep -q 1 && return 1
	return 0
}

_podkop_extras_nft_apply_lenient() {
	printf '%s\n' "$1" >>"$NFT_SCRIPT"
	return 0
}

reset_nft() { : >"$NFT_SCRIPT"; }
applied() { cat "$NFT_SCRIPT"; }

# Число непустых элементов в строке «a, b, c»
count_elements() {
	[ -n "$1" ] || {
		echo 0
		return 0
	}
	printf '%s' "$1" | tr ',' '\n' | grep -c '[^ ]'
}

count_lines() {
	[ -n "$1" ] || {
		echo 0
		return 0
	}
	printf '%s\n' "$1" | grep -c ''
}

# ============================ список DoH ====================================

it "список IPv4-резолверов не пустой"
v4_list=$(podkop_extras_doh_addresses v4)
assert_ne "0" "$(count_lines "$v4_list")"

it "список IPv6-резолверов не пустой"
v6_list=$(podkop_extras_doh_addresses v6)
assert_ne "0" "$(count_lines "$v6_list")"

it "в списке IPv4 нет дублей"
assert_eq "" "$(podkop_extras_doh_addresses v4 | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"

it "в списке IPv6 нет дублей"
assert_eq "" "$(podkop_extras_doh_addresses v6 | sort | uniq -d | tr '\n' ' ' | sed 's/ *$//')"

it "v4 и v6 не перепутаны местами"
assert_not_contains ":" "$(podkop_extras_doh_addresses v4)"

it "в списке v6 нет чистых IPv4"
assert_eq "" "$(podkop_extras_doh_addresses v6 | grep -v ':' | tr '\n' ' ' | sed 's/ *$//')"

it "провайдеров в списке больше десяти"
assert_eq "да" "$([ "$(printf '%s' "$PODKOP_X_DOH_PROVIDERS" | wc -w)" -gt 10 ] && echo да || echo нет)"

it "Cloudflare на месте"
assert_contains "
1.1.1.1
" "
$(podkop_extras_doh_addresses v4)
"

it "Google на месте"
assert_contains "
8.8.8.8
" "
$(podkop_extras_doh_addresses v4)
"

it "Quad9 на месте"
assert_contains "
9.9.9.9
" "
$(podkop_extras_doh_addresses v4)
"

it "AdGuard на месте"
assert_contains "
94.140.14.14
" "
$(podkop_extras_doh_addresses v4)
"

it "NextDNS взят подсетью, а не адресом"
assert_contains "
45.90.28.0/24
" "
$(podkop_extras_doh_addresses v4)
"

it "Mullvad на месте"
assert_contains "
194.242.2.0/24
" "
$(podkop_extras_doh_addresses v4)
"

it "Cloudflare есть и в IPv6"
assert_contains "
2606:4700:4700::1111
" "
$(podkop_extras_doh_addresses v6)
"

it "ни один IPv4-адрес не выброшен валидацией"
assert_eq "$(count_lines "$v4_list")" "$(count_elements "$(podkop_extras_doh_elements v4)")"

it "ни один IPv6-адрес не выброшен валидацией"
assert_eq "$(count_lines "$v6_list")" "$(count_elements "$(podkop_extras_doh_elements v6)")"

it "элементы для nft разделены запятой"
assert_contains ", " "$(podkop_extras_doh_elements v4)"

# ============================ генерация DoH =================================

doh=$(podkop_extras_doh_gen_rules)

it "набор IPv4 создаётся с нужным типом"
assert_contains "add set inet PodkopTable podkop_doh_v4 { type ipv4_addr; flags interval; auto-merge; }" "$doh"

it "набор IPv6 создаётся с нужным типом"
assert_contains "add set inet PodkopTable podkop_doh_v6 { type ipv6_addr; flags interval; auto-merge; }" "$doh"

it "наборы чистятся перед наполнением"
assert_contains "flush set inet PodkopTable podkop_doh_v4" "$doh"

it "адреса заливаются в набор IPv4"
assert_contains "add element inet PodkopTable podkop_doh_v4 { 1.1.1.1," "$doh"

it "адреса заливаются в набор IPv6"
assert_contains "add element inet PodkopTable podkop_doh_v6 { 2606:4700:4700::1111," "$doh"

it "цепочка блокировки висит на forward"
assert_contains "add chain inet PodkopTable doh_block { type filter hook forward priority -10; policy accept; }" "$doh"

it "правило отказа для IPv4"
assert_contains "add rule inet PodkopTable doh_block ip daddr @podkop_doh_v4 tcp dport 443 counter reject with tcp reset" "$doh"

it "правило отказа для IPv6"
assert_contains "add rule inet PodkopTable doh_block ip6 daddr @podkop_doh_v6 tcp dport 443 counter reject with tcp reset" "$doh"

it "DoH3 поверх QUIC тоже режется"
assert_contains "add rule inet PodkopTable doh_block ip daddr @podkop_doh_v4 udp dport 443 counter reject" "$doh"

it "udp/443 режется и для IPv6"
assert_contains "add rule inet PodkopTable doh_block ip6 daddr @podkop_doh_v6 udp dport 443 counter reject" "$doh"

it "обычный DNS по udp/53 не трогается"
assert_not_contains "dport 53" "$doh"

it "DoT по tcp/853 не трогается"
assert_not_contains "dport 853" "$doh"

it "DoH не заворачивается в ядро: return в mangle раньше метки"
assert_contains "insert rule inet PodkopTable mangle ip daddr @podkop_doh_v4 tcp dport 443 counter return" "$doh"

it "то же для трафика самого роутера в mangle_output"
assert_contains "insert rule inet PodkopTable mangle_output ip daddr @podkop_doh_v4 tcp dport 443 counter return" "$doh"

it "skip-правила есть и для IPv6"
assert_contains "insert rule inet PodkopTable mangle ip6 daddr @podkop_doh_v6 udp dport 443 counter return" "$doh"

it "skip-правила не ставят метку"
assert_not_contains "meta mark set" "$doh"

it "цепочка на output по умолчанию не создаётся"
assert_not_contains "hook output" "$doh"

it "таблица создаётся, если её ещё нет"
assert_contains "add table inet PodkopTable" "$doh"

it "имя таблицы берётся из аргумента"
assert_contains "add table inet MyTable" "$(podkop_extras_doh_gen_rules MyTable)"

it "имя таблицы по умолчанию берётся из NFT_TABLE_NAME"
NFT_TABLE_NAME="FromConstants"
assert_contains "add table inet FromConstants" "$(podkop_extras_doh_gen_rules)"
NFT_TABLE_NAME=""

# --- покрытие роутера, выключенное по умолчанию ---

it "с включённым покрытием роутера появляется цепочка на output"
PODKOP_X_DOH_COVER_ROUTER=1
doh_router=$(podkop_extras_doh_gen_rules)
assert_contains "add chain inet PodkopTable doh_block_output { type filter hook output priority -10; policy accept; }" "$doh_router"

it "своему ядру резолвер не режем: трафик с меткой ядра пропускается"
assert_contains "add rule inet PodkopTable doh_block_output meta mark and 0x00200000 == 0x00200000 counter return" "$doh_router"

it "цепочка на output тоже режет оба семейства"
assert_contains "add rule inet PodkopTable doh_block_output ip6 daddr @podkop_doh_v6 tcp dport 443 counter reject with tcp reset" "$doh_router"
PODKOP_X_DOH_COVER_ROUTER=0

# --- снятие ---

teardown=$(podkop_extras_doh_gen_teardown)

it "снятие удаляет цепочку блокировки"
assert_contains "delete chain inet PodkopTable doh_block" "$teardown"

it "снятие чистит наборы, но не удаляет их"
assert_contains "flush set inet PodkopTable podkop_doh_v4" "$teardown"

it "наборы не удаляются: на них ссылаются правила подкопа"
assert_not_contains "delete set" "$teardown"

it "снятие блокировки доходит до nft"
reset_nft
podkop_extras_doh_clear
assert_contains "delete chain inet PodkopTable doh_block_output" "$(applied)"

it "снятие блокировки не зависит от того, включена ли опция"
set_block_doh "0"
reset_nft
podkop_extras_doh_clear
assert_contains "flush set inet PodkopTable podkop_doh_v6" "$(applied)"

# ============================ опция block_doh ===============================

it "выключенная опция не даёт правил"
set_block_doh "0"
reset_nft
podkop_extras_doh_apply
assert_eq "" "$(applied)"

it "отсутствующая опция тоже не даёт правил"
set_block_doh ""
reset_nft
podkop_extras_doh_apply
assert_eq "" "$(applied)"

it "мусор в опции считается выключенным"
set_block_doh "потом"
reset_nft
podkop_extras_doh_apply
assert_eq "" "$(applied)"

it "включённая опция даёт правила"
set_block_doh "1"
reset_nft
podkop_extras_doh_apply
assert_contains "add rule inet PodkopTable doh_block" "$(applied)"

it "опция понимает не только единицу"
set_block_doh "true"
reset_nft
podkop_extras_doh_apply
assert_contains "add rule inet PodkopTable doh_block" "$(applied)"

it "выключенная опция - не ошибка"
set_block_doh "0"
podkop_extras_doh_apply && r=да || r=нет
assert_eq "да" "$r"

it "провал nft виден вызывающему"
set_block_doh "1"
printf '1' >"$TMP/nft_rc"
podkop_extras_doh_apply && r=да || r=нет
rm -f "$TMP/nft_rc"
assert_eq "нет" "$r"

# ============================ вердикт секции ================================

it "bypass не ставит метку"
assert_eq "counter return" "$(podkop_extras_section_verdict bypass)"

it "exclusion метку ставит: трафик всё равно заходит в ядро"
assert_eq "meta mark set 0x00100000 counter" "$(podkop_extras_section_verdict exclusion)"

it "bypass и exclusion - разные вердикты"
assert_ne "$(podkop_extras_section_verdict exclusion)" "$(podkop_extras_section_verdict bypass)"

it "для nft exclusion неотличим от proxy"
assert_eq "$(podkop_extras_section_verdict proxy)" "$(podkop_extras_section_verdict exclusion)"

it "block тоже заходит в ядро"
assert_eq "$(podkop_extras_section_verdict proxy)" "$(podkop_extras_section_verdict block)"

it "неизвестное действие вердикта не даёт"
assert_eq "" "$(podkop_extras_section_verdict wat)"

it "неизвестное действие - ошибка, а не тихий пропуск"
podkop_extras_section_verdict wat >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

it "трафик bypass в ядро не заходит"
podkop_extras_action_enters_core bypass && r=да || r=нет
assert_eq "нет" "$r"

it "трафик exclusion в ядро заходит"
podkop_extras_action_enters_core exclusion && r=да || r=нет
assert_eq "да" "$r"

# ============================ правила bypass ================================

bypass=$(podkop_extras_bypass_gen "" main "10.20.0.0/16 2001:db8::/32")

it "набор IPv4 секции создаётся"
assert_contains "add set inet PodkopTable podkop_bypass_main_v4 { type ipv4_addr; flags interval; auto-merge; }" "$bypass"

it "набор IPv6 секции создаётся"
assert_contains "add set inet PodkopTable podkop_bypass_main_v6 { type ipv6_addr; flags interval; auto-merge; }" "$bypass"

it "правило bypass для IPv4"
assert_contains "insert rule inet PodkopTable mangle ip daddr @podkop_bypass_main_v4 counter return" "$bypass"

it "правило bypass для IPv6"
assert_contains "insert rule inet PodkopTable mangle ip6 daddr @podkop_bypass_main_v6 counter return" "$bypass"

it "правило bypass ставится и на трафик роутера"
assert_contains "insert rule inet PodkopTable mangle_output ip daddr @podkop_bypass_main_v4 counter return" "$bypass"

it "bypass не ставит tproxy-метку - этим он и отличается от exclusion"
assert_not_contains "meta mark set" "$bypass"

it "правило именно insert: оно должно стоять раньше правил с меткой"
assert_not_contains "add rule inet PodkopTable mangle " "$bypass"

it "адреса раскладываются по семействам: IPv4"
assert_contains "add element inet PodkopTable podkop_bypass_main_v4 { 10.20.0.0/16 }" "$bypass"

it "адреса раскладываются по семействам: IPv6"
assert_contains "add element inet PodkopTable podkop_bypass_main_v6 { 2001:db8::/32 }" "$bypass"

it "элементов ровно четыре правила: два семейства на две цепочки"
assert_eq "4" "$(printf '%s\n' "$bypass" | grep -c '^insert rule')"

it "список через запятую тоже принимается"
assert_contains "{ 10.0.0.0/8, 192.168.5.0/24 }" "$(podkop_extras_bypass_gen_elements "" main "10.0.0.0/8,192.168.5.0/24")"

it "мусор в списке адресов выбрасывается, а не уезжает в nft"
dirty=$(podkop_extras_bypass_gen_elements "" main "10.0.0.0/8 ; rm -rf / не-адрес 2001:db8::1")
assert_not_contains "rm -rf" "$dirty"

it "из мусора остаются только настоящие адреса"
assert_contains "add element inet PodkopTable podkop_bypass_main_v4 { 10.0.0.0/8 }" "$dirty"

it "IPv6 из того же списка тоже уцелел"
assert_contains "add element inet PodkopTable podkop_bypass_main_v6 { 2001:db8::1 }" "$dirty"

it "секция без адресов даёт правила, но не даёт элементов"
empty_section=$(podkop_extras_bypass_gen "" main)
assert_not_contains "add element" "$empty_section"

it "секция без адресов всё равно получает правила"
assert_contains "insert rule inet PodkopTable mangle ip daddr @podkop_bypass_main_v4 counter return" "$empty_section"

it "без имени секции генерация не работает"
podkop_extras_bypass_gen "" "" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

# ============================ применение bypass =============================

it "секция не bypass - правила не ставятся"
set_section_action "exclusion"
reset_nft
podkop_extras_bypass_apply "" main "10.0.0.0/8"
assert_eq "" "$(applied)"

it "секция proxy тоже не получает bypass-правил"
set_section_action "proxy"
reset_nft
podkop_extras_bypass_apply "" main "10.0.0.0/8"
assert_eq "" "$(applied)"

it "секция bypass правила получает"
set_section_action "bypass"
reset_nft
podkop_extras_bypass_apply "" main "10.0.0.0/8"
assert_contains "insert rule inet PodkopTable mangle ip daddr @podkop_bypass_main_v4 counter return" "$(applied)"

it "чужая секция - не ошибка"
set_section_action "proxy"
podkop_extras_bypass_apply "" main && r=да || r=нет
assert_eq "да" "$r"

it "провал nft виден вызывающему и здесь"
set_section_action "bypass"
printf '1' >"$TMP/nft_rc"
podkop_extras_bypass_apply "" main "10.0.0.0/8" && r=да || r=нет
rm -f "$TMP/nft_rc"
assert_eq "нет" "$r"

it "очистка секции чистит оба набора"
reset_nft
podkop_extras_bypass_clear "" main
assert_eq "flush set inet PodkopTable podkop_bypass_main_v4
flush set inet PodkopTable podkop_bypass_main_v6" "$(applied)"

it "очистка без имени секции - ошибка"
podkop_extras_bypass_clear "" "" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

# ============================ чтение конфига ================================

it "тип секции читается из конфига"
set_section_action "bypass"
assert_eq "bypass" "$(podkop_extras_section_action main)"

it "без имени секции тип не читается"
podkop_extras_section_action "" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

it "bypass-секции находятся в конфиге"
set_uci_show "podkop.main.connection_type='proxy'
podkop.home.connection_type='bypass'
podkop.work.connection_type='bypass'
podkop.dead.connection_type='exclusion'"
assert_eq "home
work" "$(podkop_extras_bypass_sections)"

it "если bypass-секций нет, список пуст"
set_uci_show "podkop.main.connection_type='proxy'"
assert_eq "" "$(podkop_extras_bypass_sections)"

# ============================ спецсимволы в именах ==========================

it "точка с запятой в имени секции превращается в подчёркивание"
assert_eq "podkop_bypass_main__flush_ruleset_v4" "$(podkop_extras_bypass_set_name 'main; flush ruleset' v4)"

it "подстановка команды не доезжает до скрипта nft"
evil=$(podkop_extras_bypass_gen "" 'a$(reboot)b' "10.0.0.0/8")
assert_not_contains '$(' "$evil"

it "скобок от подстановки тоже не остаётся"
assert_not_contains ')' "$evil"

it "обратные кавычки тоже не доезжают"
assert_not_contains '`' "$(podkop_extras_bypass_gen "" 'a`reboot`b' "10.0.0.0/8")"

it "имя секции со спецсимволами не ломает генерацию"
assert_contains "insert rule inet PodkopTable mangle ip daddr @podkop_bypass_a__reboot_b_v4 counter return" "$evil"

it "кавычки и пробелы в имени секции безопасны"
assert_eq "" "$(printf '%s' "$(podkop_extras_bypass_set_name "it's a \"name\"" v4)" | tr -d 'A-Za-z0-9_')"

it "кириллица не даёт недопустимого имени набора"
assert_eq "" "$(printf '%s' "$(podkop_extras_bypass_set_name 'секция' v4)" | tr -d 'A-Za-z0-9_')"

it "перевод строки в имени секции не разрывает скрипт"
multi=$(podkop_extras_bypass_gen "" "$(printf 'a\nb')" "10.0.0.0/8")
assert_eq "8" "$(count_lines "$multi")"

it "перевод строки в имени секции стал подчёркиванием"
assert_contains "@podkop_bypass_a_b_v4 " "$multi"

it "имя из одних спецсимволов остаётся допустимым идентификатором"
assert_eq "podkop_bypass_____v4" "$(podkop_extras_bypass_set_name '!!!' v4)"

it "пустое имя не даёт набора без имени"
assert_eq "podkop_bypass_unnamed_v4" "$(podkop_extras_bypass_set_name '' v4)"

it "длинное имя обрезается"
assert_eq "podkop_bypass_aaaaaaaaaaaaaaaaaaaaaaaa_v4" \
	"$(podkop_extras_bypass_set_name 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' v4)"

it "семейство по умолчанию - v4"
assert_eq "podkop_bypass_main_v4" "$(podkop_extras_bypass_set_name main)"

it "неизвестное семейство считается v6"
assert_eq "podkop_bypass_main_v6" "$(podkop_extras_bypass_set_name main ipv6)"

it "санитайзер оставляет нормальное имя как есть"
assert_eq "main_2" "$(podkop_extras_nft_ident 'main_2')"

finish
