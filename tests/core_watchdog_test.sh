#!/bin/sh
# Тесты сторожа ядра.
#
# Сеть не трогается вовсе: наружу у сторожа торчат ровно шесть тонких обёрток -
# _core_watchdog_process_running, _core_watchdog_http_probe,
# _core_watchdog_dnsmasq_restore, _core_watchdog_core_start, _core_watchdog_now
# и _core_watchdog_sleep, - и здесь подменены все, кроме старта ядра. Старт
# оставлен настоящим сознательно: он идёт через core_service_start, то есть
# через слой ядра, и только так можно проверить, что сторожу безразлично, какое
# ядро активно. Вместо init-скриптов подставлены заглушки.
#
# Часы тоже подменены. Кулдаун меряется десятками секунд, а предохранитель -
# получасовым окном; тест, который честно ждёт полчаса, никто не станет гонять.
#
# Главная проверка файла - порядок восстановления: dnsmasq возвращается на
# рабочий резолвер РАНЬШЕ, чем делается попытка поднять ядро. Обе операции
# пишут в один и тот же журнал действий, поэтому порядок виден построчно.
#
# shellcheck shell=sh
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d 2>/dev/null || mktemp -d -t podkop)
trap 'rm -rf "$TMP"' EXIT

# --- заглушка uci -----------------------------------------------------------
# Значения через файлы: core_current и core_watchdog_enabled зовутся в том
# числе из $( ), а подоболочка переменных наружу не отдаёт.
UCI_DIR="$TMP/uci"
mkdir -p "$UCI_DIR"

set_opt() { printf '%s' "$2" >"$UCI_DIR/$1"; }
get_opt() { cat "$UCI_DIR/$1" 2>/dev/null; }

# Порядок веток значим: "podkop.settings.core" - подстрока
# "podkop.settings.core_watchdog", и наоборот.
uci() {
	case "$*" in
	*podkop.settings.core_watchdog_interval*) get_opt watchdog_interval ;;
	*podkop.settings.core_watchdog*) get_opt watchdog ;;
	*podkop.settings.core*) get_opt core ;;
	*podkop.settings.config_path*) get_opt config_path ;;
	*podkop.settings.dont_touch_dhcp*) get_opt dont_touch_dhcp ;;
	*dnsmasq*) get_opt dnsmasq_server ;;
	*) return 1 ;;
	esac
}

# --- журнал действий и состояние заглушек -----------------------------------
# Всё в файлах: init-скрипт исполняется отдельным процессом, и его следы должны
# быть видны и тесту, и следующей проверке живости.
ACTION_LOG="$TMP/actions.log"
PROC_FILE="$TMP/proc"
API_FILE="$TMP/api"
START_OK_FILE="$TMP/start_ok"
CLOCK_FILE="$TMP/clock"
DNSMASQ_RC_FILE="$TMP/dnsmasq_rc"
export ACTION_LOG PROC_FILE API_FILE START_OK_FILE

set_proc() { printf '%s' "$1" >"$PROC_FILE"; }
set_api() { printf '%s' "$1" >"$API_FILE"; }
set_start_ok() { printf '%s' "$1" >"$START_OK_FILE"; }
set_now() { printf '%s' "$1" >"$CLOCK_FILE"; }
set_dnsmasq_rc() { printf '%s' "$1" >"$DNSMASQ_RC_FILE"; }

# --- заглушки init-скриптов ядра --------------------------------------------
# Успешный старт делает ядро живым сразу: и процесс на месте, и API отвечает.
mk_service() {
	cat >"$1" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$1" >> "$ACTION_LOG"
case "$1" in
start)
	if [ "$(cat "$START_OK_FILE" 2>/dev/null)" = "1" ]; then
		printf '1' > "$PROC_FILE"
		printf '1' > "$API_FILE"
	fi
	;;
esac
exit 0
EOF
	chmod +x "$1"
}

mk_service "$TMP/sing-box"
mk_service "$TMP/clash-rs"

# --- подключение модулей ----------------------------------------------------
# Порядок тот же, что в /usr/bin/podkop: константы, слой ядра, потом сторож.
. "$DIR/../podkop/files/usr/lib/constants.sh"
. "$DIR/../podkop/files/usr/lib/core.sh"
. "$DIR/../podkop/files/usr/lib/core_watchdog.sh"

# Переопределяем после подключения: в модулях стоят значения по умолчанию
CORE_SB_SERVICE="$TMP/sing-box"
CORE_CR_SERVICE="$TMP/clash-rs"
CORE_WATCHDOG_STATE_FILE="$TMP/watchdog.state"

# Адрес API задан явно: конфига ядра на машине разработчика нет, а проверять мы
# хотим не разбор конфига (для него есть отдельные тесты ниже), а поведение.
CORE_WATCHDOG_API_ADDRESS="127.0.0.1:9090"

# Один промах = падение. Дебаунс проверяется отдельно, в остальных тестах он
# только удваивал бы число проходов.
CORE_WATCHDOG_MISSES=1

# --- подмена тонких обёрток -------------------------------------------------

_core_watchdog_process_running() { [ "$(cat "$PROC_FILE" 2>/dev/null)" = "1" ]; }
_core_watchdog_http_probe() { [ "$(cat "$API_FILE" 2>/dev/null)" = "1" ]; }
_core_watchdog_now() { cat "$CLOCK_FILE" 2>/dev/null || printf '0'; }
_core_watchdog_sleep() { :; }

_core_watchdog_dnsmasq_restore() {
	printf 'dnsmasq-restore\n' >>"$ACTION_LOG"
	[ "$(cat "$DNSMASQ_RC_FILE" 2>/dev/null)" = "0" ]
}

# --- служебное --------------------------------------------------------------

# Исходное состояние: сторож включён, ядро clash-rs живо, dnsmasq перенастроен
# на резолвер ядра, часы на 1000.
reset_all() {
	: >"$ACTION_LOG"
	rm -f "$CORE_WATCHDOG_STATE_FILE"
	set_proc 1
	set_api 1
	set_start_ok 1
	set_now 1000
	set_dnsmasq_rc 0
	set_opt watchdog 1
	set_opt watchdog_interval ""
	set_opt dont_touch_dhcp 0
	set_opt dnsmasq_server "127.0.0.42"
	set_opt core "clash-rs"
	set_opt config_path ""
}

tick() {
	core_watchdog_tick
	RC=$?
}

actions() { cat "$ACTION_LOG" 2>/dev/null; }
action_line() { sed -n "$1p" "$ACTION_LOG" 2>/dev/null; }

# Ядро упало: процесс ещё виден, API уже молчит - самый частый и самый
# коварный вид падения
kill_core() {
	set_proc 1
	set_api 0
}

reset_all

# ============================ чистые функции ================================

it "первая попытка ждёт базовую паузу"
assert_eq "30" "$(core_watchdog_backoff 1)"

it "вторая попытка ждёт вдвое дольше"
assert_eq "60" "$(core_watchdog_backoff 2)"

it "третья попытка ждёт вчетверо дольше"
assert_eq "120" "$(core_watchdog_backoff 3)"

it "пауза упирается в потолок и дальше не растёт"
assert_eq "300" "$(core_watchdog_backoff 9)"

it "нулевая попытка даёт базовую паузу"
assert_eq "30" "$(core_watchdog_backoff 0)"

it "мусор вместо числа попыток не ломает расчёт паузы"
assert_eq "30" "$(core_watchdog_backoff 'ой')"

it "пустой интервал даёт значение по умолчанию"
assert_eq "30" "$(core_watchdog_clamp_interval '')"

it "мусор в интервале даёт значение по умолчанию"
assert_eq "30" "$(core_watchdog_clamp_interval 'каждую минуту')"

it "интервал в одну секунду поднимается до нижней границы"
assert_eq "5" "$(core_watchdog_clamp_interval 1)"

it "нулевой интервал не превращает сторож в busy-loop"
assert_eq "5" "$(core_watchdog_clamp_interval 0)"

it "слишком большой интервал срезается до верхней границы"
assert_eq "3600" "$(core_watchdog_clamp_interval 99999)"

it "разумный интервал берётся как есть"
assert_eq "45" "$(core_watchdog_clamp_interval 45)"

it "живое ядро - приговор alive"
assert_eq "alive" "$(core_watchdog_verdict 1 0)"

it "один промах при пороге в два - ещё не падение"
CORE_WATCHDOG_MISSES=2
assert_eq "watch" "$(core_watchdog_verdict 0 1)"

it "второй промах подряд - падение"
assert_eq "dead" "$(core_watchdog_verdict 0 2)"
CORE_WATCHDOG_MISSES=1

it "выключенный сторож не решает ничего"
assert_eq "disabled" "$(core_watchdog_decide 0 1 1000 0 0 0)"

it "живое ядро - вмешиваться не во что"
assert_eq "ok" "$(core_watchdog_decide 1 0 1000 0 0 0)"

it "первое падение - сразу восстановление"
assert_eq "recover" "$(core_watchdog_decide 1 1 1000 0 0 0)"

it "сразу после попытки - кулдаун"
assert_eq "wait" "$(core_watchdog_decide 1 1 1010 1 1000 1000)"

it "после кулдауна - снова восстановление"
assert_eq "recover" "$(core_watchdog_decide 1 1 1031 1 1000 1000)"

it "исчерпанные попытки внутри окна - предохранитель"
assert_eq "fuse" "$(core_watchdog_decide 1 1 1500 5 1000 1400)"

it "по истечении окна попытки начинаются заново"
assert_eq "recover" "$(core_watchdog_decide 1 1 3000 5 1000 1400)"

it "часы, ушедшие назад, не запирают сторож в кулдауне"
assert_eq "recover" "$(core_watchdog_decide 1 1 500 1 1000 1000)"

it "окно ещё не начиналось - считается истёкшим"
core_watchdog_window_expired 1000 0 && r=да || r=нет
assert_eq "да" "$r"

it "свежее окно не считается истёкшим"
core_watchdog_window_expired 1100 1000 && r=да || r=нет
assert_eq "нет" "$r"

# ============================ адрес Clash API ===============================

it "0.0.0.0 не адрес для стука - подменяется локалхостом"
assert_eq "127.0.0.1:9090" "$(core_watchdog_normalize_address '0.0.0.0:9090')"

it "адрес LAN остаётся как есть"
assert_eq "192.168.1.1:9090" "$(core_watchdog_normalize_address '192.168.1.1:9090')"

it "адрес без порта дополняется портом контроллера"
assert_eq "192.168.1.1:9090" "$(core_watchdog_normalize_address '192.168.1.1')"

it "пустой хост - это локалхост"
assert_eq "127.0.0.1:9090" "$(core_watchdog_normalize_address ':9090')"

it "IPv6-заглушка тоже подменяется локалхостом"
assert_eq "127.0.0.1:9090" "$(core_watchdog_normalize_address '[::]:9090')"

it "IPv6-адрес остаётся в скобках"
assert_eq "[fd00::1]:9090" "$(core_watchdog_normalize_address '[fd00::1]:9090')"

it "порт контроллера берётся из констант подкопа"
assert_eq "9090" "$CORE_WATCHDOG_API_PORT"

it "резолвер ядра берётся из констант подкопа"
assert_eq "127.0.0.42" "$CORE_WATCHDOG_DNS_ADDRESS"

# Конфиги ядер: ключ контроллера у них разный, и сторож обязан знать оба
printf '%s' '{"external-controller":"192.168.1.1:9090","proxies":[]}' >"$TMP/clash.json"
printf '%s' '{"experimental":{"clash_api":{"external_controller":"192.168.5.1:9090"}}}' >"$TMP/sb.json"
printf '%s' '{"proxies":[]}' >"$TMP/no-api.json"

it "адрес контроллера clash-rs читается из поля верхнего уровня"
set_opt core "clash-rs"
assert_eq "192.168.1.1:9090" "$(core_watchdog_config_api_address "$TMP/clash.json")"

it "адрес контроллера sing-box читается из experimental.clash_api"
set_opt core "sing-box"
assert_eq "192.168.5.1:9090" "$(core_watchdog_config_api_address "$TMP/sb.json")"

it "несуществующий конфиг не выдумывает адрес"
set_opt core "clash-rs"
core_watchdog_config_api_address "$TMP/нет-такого.json" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

it "конфиг без контроллера не выдумывает адрес"
core_watchdog_config_api_address "$TMP/no-api.json" >/dev/null 2>&1 && r=да || r=нет
assert_eq "нет" "$r"

it "URL проверки собирается из адреса и пути"
assert_eq "http://127.0.0.1:9090/version" "$(core_watchdog_api_url)"

# ============================ живость ядра ==================================

it "процесс есть и API отвечает - ядро живо"
reset_all
core_watchdog_core_alive && r=да || r=нет
assert_eq "да" "$r"

# Ради этой проверки сторож и ходит в API. Ядро умеет висеть, не обрабатывая
# запросы: pidof доволен, а DNS не резолвится и трафик не идёт - для
# пользователя это неотличимо от падения.
it "процесс есть, но API молчит - ядро считается мёртвым"
reset_all
set_api 0
core_watchdog_core_alive && r=да || r=нет
assert_eq "нет" "$r"

it "нет процесса - ядро мёртво независимо от API"
reset_all
set_proc 0
set_api 1
core_watchdog_core_alive && r=да || r=нет
assert_eq "нет" "$r"

it "не настроенный API не повод объявлять живое ядро мёртвым"
reset_all
set_api 0
CORE_WATCHDOG_API_ADDRESS=""
set_opt config_path "$TMP/нет-такого.json"
core_watchdog_core_alive && r=да || r=нет
CORE_WATCHDOG_API_ADDRESS="127.0.0.1:9090"
assert_eq "да" "$r"

# ============================ опция =========================================

it "по умолчанию сторож выключен"
reset_all
set_opt watchdog ""
core_watchdog_enabled && r=да || r=нет
assert_eq "нет" "$r"

it "выключенный сторож при мёртвом ядре не делает ничего"
reset_all
set_opt watchdog ""
kill_core
tick
assert_eq "" "$(actions)"

it "выключенный сторож сообщает об этом кодом возврата"
assert_eq "1" "$RC"

it "включение опции единицей включает сторож"
reset_all
set_opt watchdog "1"
core_watchdog_enabled && r=да || r=нет
assert_eq "да" "$r"

it "живое ядро не вызывает никаких действий"
reset_all
tick
assert_eq "" "$(actions)"

it "живое ядро отдаёт нулевой код"
assert_eq "0" "$RC"

it "интервал проверки берётся из конфига"
reset_all
set_opt watchdog_interval "60"
assert_eq "60" "$(core_watchdog_interval)"

it "без настройки интервал берётся по умолчанию"
set_opt watchdog_interval ""
assert_eq "30" "$(core_watchdog_interval)"

# ============================ dnsmasq =======================================

it "перенастроенный на ядро dnsmasq опознаётся"
reset_all
set_opt dnsmasq_server "127.0.0.42"
core_watchdog_dnsmasq_hijacked && r=да || r=нет
assert_eq "да" "$r"

it "обычный резолвер в dnsmasq не путается с ядром"
set_opt dnsmasq_server "192.168.1.1"
core_watchdog_dnsmasq_hijacked && r=да || r=нет
assert_eq "нет" "$r"

it "при dont_touch_dhcp dnsmasq не считается нашим"
set_opt dont_touch_dhcp 1
core_watchdog_dnsmasq_managed && r=да || r=нет
assert_eq "нет" "$r"

it "при dont_touch_dhcp чужой dnsmasq не трогается"
reset_all
set_opt dont_touch_dhcp 1
kill_core
tick
assert_not_contains "dnsmasq-restore" "$(actions)"

it "но ядро при dont_touch_dhcp всё равно поднимается"
assert_contains "clash-rs start" "$(actions)"

it "уже восстановленный dnsmasq второй раз не трогается"
reset_all
set_opt dnsmasq_server "192.168.1.1"
kill_core
tick
assert_not_contains "dnsmasq-restore" "$(actions)"

# ============================ ПОРЯДОК =======================================
#
# Ради этого сторож и написан. Подкоп переводит dnsmasq на резолвер ядра, и
# мёртвое ядро означает не «проксирование отвалилось», а «DNS нет вообще» -
# роутер без интернета и без единой подсказки, почему. Ядро при этом может
# стартовать секунды, а может не стартовать никогда. Значит, dnsmasq
# возвращается ПЕРВЫМ, и только потом делается попытка поднять ядро.

it "при падении ядра выполняются ровно два действия"
reset_all
kill_core
tick
assert_eq "2" "$(actions | grep -c '')"

it "ПЕРВЫМ действием dnsmasq возвращается на рабочий резолвер"
assert_eq "dnsmasq-restore" "$(action_line 1)"

it "ВТОРЫМ действием поднимается ядро"
assert_eq "clash-rs start" "$(action_line 2)"

it "старта ядра раньше восстановления dnsmasq не бывает"
assert_ne "clash-rs start" "$(action_line 1)"

it "неудача восстановления dnsmasq не отменяет подъём ядра"
reset_all
set_dnsmasq_rc 1
kill_core
tick
assert_eq "clash-rs start" "$(action_line 2)"

it "порядок сохраняется и при неудаче восстановления dnsmasq"
assert_eq "dnsmasq-restore" "$(action_line 1)"

it "успешное восстановление отдаёт код «ядро поднялось»"
reset_all
kill_core
tick
assert_eq "5" "$RC"

it "не поднявшееся ядро отдаёт свой код"
reset_all
kill_core
set_start_ok 0
tick
assert_eq "6" "$RC"

it "но dnsmasq возвращён даже если ядро не поднялось"
assert_eq "dnsmasq-restore" "$(action_line 1)"

# ============================ кулдаун =======================================

it "сразу после попытки сторож не долбит ядро снова"
reset_all
kill_core
set_start_ok 0
tick
: >"$ACTION_LOG"
set_now 1010
tick
assert_eq "" "$(actions)"

it "и сообщает об этом кодом кулдауна"
assert_eq "3" "$RC"

it "по истечении паузы попытка повторяется"
set_now 1031
tick
assert_eq "clash-rs start" "$(action_line 2)"

it "вторая пауза вдвое длиннее первой"
: >"$ACTION_LOG"
set_now 1080
tick
assert_eq "3" "$RC"

# Ядро в этом блоке не поднимается (set_start_ok 0), поэтому код 6, а не 5:
# проверяем именно то, что попытка снова разрешена
it "после удвоенной паузы попытка снова разрешена"
set_now 1092
tick
assert_eq "6" "$RC"

it "и это была настоящая попытка, а не запись в лог"
assert_eq "clash-rs start" "$(action_line 2)"

# ============================ предохранитель ================================

# Пять попыток за окно - и сторож замолкает до конца окна, оставив DNS в
# рабочем состоянии. Иначе падающее по кругу ядро превращает сторож в
# бесконечный цикл рестартов.
it "пять попыток укладываются в разрешённые"
reset_all
kill_core
set_start_ok 0
set_now 1000 && tick
set_now 1400 && tick
set_now 1500 && tick
set_now 1700 && tick
set_now 2100 && tick
assert_eq "5" "$(core_watchdog_state_get attempts)"

it "шестая попытка упирается в предохранитель"
: >"$ACTION_LOG"
set_now 2500
tick
assert_eq "4" "$RC"

it "предохранитель означает бездействие, а не тихий рестарт"
assert_eq "" "$(actions)"

it "по истечении окна сторож пробует снова"
: >"$ACTION_LOG"
set_now 3000
tick
assert_eq "clash-rs start" "$(action_line 2)"

it "и снова начинает с восстановления dnsmasq"
assert_eq "dnsmasq-restore" "$(action_line 1)"

it "и счётчик попыток начинается заново"
assert_eq "1" "$(core_watchdog_state_get attempts)"

# ============================ дебаунс =======================================

it "первый промах при пороге в два только запоминается"
reset_all
CORE_WATCHDOG_MISSES=2
kill_core
tick
assert_eq "" "$(actions)"

it "и отдаёт код подозрения"
assert_eq "2" "$RC"

it "второй промах подряд уже вызывает восстановление"
set_now 1030
tick
assert_eq "dnsmasq-restore" "$(action_line 1)"

it "ожившее ядро сбрасывает накопленные промахи"
reset_all
kill_core
tick
set_proc 1
set_api 1
tick
assert_eq "0" "$(core_watchdog_state_get misses)"
CORE_WATCHDOG_MISSES=1

# ============================ состояние =====================================

it "состояние переживает перезапуск сторожа"
reset_all
kill_core
set_start_ok 0
tick
# «перезапуск»: всё, что сторож помнил в переменных, потеряно - остался файл
assert_eq "1" "$(core_watchdog_state_get attempts)"

it "время попытки тоже сохранено"
assert_eq "1000" "$(core_watchdog_state_get last_attempt)"

it "живое ядро закрывает историю падений"
set_proc 1
set_api 1
set_now 2000
tick
assert_eq "0" "$(core_watchdog_state_get attempts)"

it "выключение опции стирает накопленные счётчики"
reset_all
kill_core
set_start_ok 0
tick
set_opt watchdog ""
tick
assert_eq "0" "$(core_watchdog_state_get attempts)"

it "битое состояние читается как ноль, а не роняет сторож"
printf 'attempts=внезапно\n' >"$CORE_WATCHDOG_STATE_FILE"
assert_eq "0" "$(core_watchdog_state_get attempts)"

# ============================ оба ядра ======================================
#
# Сторож не знает, какое ядро активно: имя бинарника и init-скрипт он берёт из
# core.sh. Здесь это и проверяется - один и тот же код поднимает то ядро,
# которое выбрано.

it "при clash-rs поднимается clash-rs"
reset_all
set_opt core "clash-rs"
kill_core
tick
assert_contains "clash-rs start" "$(actions)"

it "при clash-rs sing-box не трогается"
assert_not_contains "sing-box" "$(actions)"

it "при sing-box поднимается sing-box"
reset_all
set_opt core "sing-box"
kill_core
tick
assert_contains "sing-box start" "$(actions)"

it "при sing-box clash-rs не трогается"
assert_not_contains "clash-rs" "$(actions)"

it "порядок восстановления одинаков для sing-box"
assert_eq "dnsmasq-restore" "$(action_line 1)"

it "и старт sing-box идёт вторым"
assert_eq "sing-box start" "$(action_line 2)"

it "ядро по умолчанию (пустая настройка) - тоже sing-box"
reset_all
set_opt core ""
kill_core
tick
assert_eq "sing-box start" "$(action_line 2)"

# ============================ цикл ==========================================

it "цикл делает столько проходов, сколько задано"
reset_all
kill_core
set_start_ok 0
CORE_WATCHDOG_TICKS=3
core_watchdog_loop
CORE_WATCHDOG_TICKS=0
# Первый проход восстанавливает, второй и третий упираются в кулдаун:
# часы стоят на месте
assert_eq "1" "$(core_watchdog_state_get attempts)"

it "цикл не выходит из-за выключенной опции"
reset_all
set_opt watchdog ""
CORE_WATCHDOG_TICKS=2
core_watchdog_loop && r=да || r=нет
CORE_WATCHDOG_TICKS=0
assert_eq "да" "$r"

finish
