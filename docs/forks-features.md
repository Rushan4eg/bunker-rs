# Фичи форков podkop: netshift и forkop

Что есть у двух живых форков podkop и чего нет в апстриме `itdoginfo/podkop`.
Смотрим с нашей колокольни: у нас ветка `feature/clash-core`, два ядра
(sing-box и clash-rs), и главный вопрос по каждой фиче — переживёт ли она
смену ядра.

Срез: netshift — коммит `40d2be7` (релиз 0.9.6, 7 июля 2026),
forkop — коммит `dd48329` (релиз 1.0.5, 18 июля 2026),
апстрим — `a64923d`, то есть ровно наша база. Нового в апстриме нет.

## Резюме

Найдено **45 фич**. Распределение: у netshift 21, у forkop 30, пересекаются 6.

Два форка устроены принципиально по-разному, и это важнее списка фич.

**netshift** (`yandexru45/netshift`, бывший `podkop-evolution`) — это подкоп
с тем же shell-бэкендом. Файлы те же (`sing_box_config_manager.sh`,
`sing_box_config_facade.sh`, `nft.sh`, `rulesets.sh`), функции те же,
просто их стало больше: 345 против наших 295. Отсюда следствие: **фичи
netshift можно тащить к нам почти дословно**, они лягут на наш код. Проект
в бете и фактически заморожен: 0.9.6 — это откат к коду 0.9.2, последний
коммит 7 июля.

**forkop** (`ushan0v/forkop`, бывший Podkop Plus) — это переписанный с нуля
бэкенд на ucode: 44 тысячи строк в 60 модулях вместо шелла, плюс фронтенд
на TypeScript с юнит-тестами (374 файла). Оттуда **нельзя скопировать ни
строчки** — можно только брать идею и реализовывать заново. Зато идей там
на порядок больше, и часть из них попадает ровно в наши болевые точки
(менеджер компонентов, механизм миграций, действие Bypass).

Ключевое наблюдение для нас: forkop **выкинул `+sing-box` из зависимостей
пакета** и ставит ядро сам, через свой менеджер компонентов. У нас та же
проблема в квадрате — clash-rs в репозиториях OpenWrt нет вообще, и без
механизма установки бинарника наша ветка не поедет дальше стенда.

## Что это за форки

| | netshift | forkop |
|---|---|---|
| репозиторий | `yandexru45/netshift` | `ushan0v/forkop` |
| версия | 0.9.6 (= код 0.9.2) | 1.0.5 |
| последний коммит | 7 июля 2026 | 18 июля 2026, активен |
| бэкенд | shell, форк нашего | ucode, переписан |
| строк бэкенда | ~6 400 | ~44 500 |
| фронтенд | тот же, +1 вкладка | TypeScript + vitest, 4 вкладки |
| зависимости пакета | `+sing-box +curl +jq +kmod-nft-tproxy +coreutils-base64 +bind-dig` | `+ucode +ucode-mod-fs +ucode-mod-uci +curl +nftables +kmod-nft-tproxy +kmod-nft-nat +kmod-inet-diag +kmod-netlink-diag +kmod-tun +ip-full +ca-bundle +bind-dig +coreutils-base64` — **без sing-box и без jq** |
| статус | бета, заморожен, был серьёзный откат | активная разработка |

## Сводная таблица

Сложность — это оценка переноса **к нам**, с учётом того, что у нас два
ядра и генератор конфига раздвоен.

| # | Фича | Где | Сложность | Зависимость от ядра |
|---|---|---|---|---|
| **Подписки** ||||
| 1 | Подписки (Subscription URL) | оба | тяжело | на clash-rs частично нативно |
| 2 | Несколько подписок в секции, слияние и дедуп | netshift | средне | нет |
| 3 | Фильтр серверов по ключевым словам | оба | тривиально | нет |
| 4 | Фильтры по стране / протоколу / транспорту / security / regex | forkop | средне | нет |
| 5 | Группировка узлов по флагу или префиксу + «⚡ Самый быстрый» | netshift | средне | нет |
| 6 | HWID для запроса подписки | оба | тривиально | нет |
| 7 | Подбор User-Agent и выбор формата подписки | netshift | средне | **да**, на clash-rs меняет всё |
| 8 | Небезопасный TLS при скачивании подписки | netshift | тривиально | нет |
| 9 | gzip-подписки | netshift | тривиально | нет |
| 10 | Кэш подписок на постоянной ФС + retry-воркер | netshift | средне | нет |
| 11 | Автообновление подписок по cron | оба | тривиально | нет |
| 12 | Сброс кэша подписки из диагностики | netshift | тривиально | нет |
| 13 | Префикс к именам узлов | forkop | тривиально | нет |
| 14 | Импорт URLTest-групп провайдера, скрытие служебных узлов | forkop | средне | нет |
| 15 | Selector / URLTest вставкой списка ссылок в текстовое поле | netshift | тривиально | нет |
| 16 | VMess | оба | средне | нет, оба ядра умеют |
| 17 | XHTTP-транспорт и sing-box-extended | оба | средне | **только sing-box** |
| **Группы, выбор, наблюдение** ||||
| 18 | Несколько независимых URLTest-групп на секцию | forkop | средне | нет |
| 19 | Группы приоритета (failover по уровням) | forkop | тяжело | на clash-rs почти нативно |
| 20 | Сортировка по задержке и ручной тест задержки | forkop | средне | нет, Clash API |
| 21 | Каскадные подключения (цепочка через другую секцию) | forkop | средне | нет, есть в обоих |
| 22 | Фильтр серверов, показываемых на дашборде | forkop | средне | нет, только LuCI |
| 23 | Определение страны сервера (флаг, country.is) | forkop | средне | нет |
| 24 | Мониторинг соединений (вкладка Monitoring) | forkop | средне | нет, Clash API |
| **Маршрутизация** ||||
| 25 | Global Proxy — весь неопознанный трафик в секцию | netshift | средне | нет |
| 26 | Действие Bypass — трафик мимо ядра | forkop | средне | нет |
| 27 | Условия в правиле: домен / IP / порты / устройство | forkop | тяжело | **да**, форма правил разная |
| 28 | Несколько интерфейсов и JSON-outbound на секцию | forkop | средне | частично |
| 29 | Маршрутизация и DNS по устройствам | forkop | средне | нет |
| 30 | Блокировка публичных DoH-серверов | netshift | тривиально | нет |
| 31 | IPv6 | оба | тяжело | **да**, у clash-rs дыры |
| **DNS** ||||
| 32 | DNS через прокси / через секцию | оба | средне | на clash-rs нативно |
| 33 | Резервные DNS с автопереключением и возвратом | forkop | тяжело | на clash-rs частично нативно |
| 34 | Отдельные DNS-серверы для доменов (действие `dns`) | forkop | средне | нет, есть в обоих |
| **Обход DPI** ||||
| 35 | Zapret / Zapret2 через NFQUEUE как действие секции | forkop | тяжело | нет |
| 36 | ByeDPI как действие секции | forkop | средне | нет |
| **Свой сервер** ||||
| 37 | VLESS Reality / MTProto / Tailscale / JSON-inbound на роутере | forkop | тяжело | **только sing-box** |
| **Эксплуатация** ||||
| 38 | Самообновление пакета из LuCI | оба | средне | нет |
| 39 | Менеджер компонентов: установка и переключение ядра | оба | средне | **критично для нас** |
| 40 | Обход rate-limit GitHub API через redirect-пути | netshift | тривиально | нет |
| 41 | Watchdog ядра с восстановлением dnsmasq | netshift | тривиально | нет |
| 42 | Механизм миграций конфига (`config_version`) | forkop | средне | нет |
| 43 | Сохранение выбранного сервера между перезагрузками | netshift (откачено) | средне | нет |
| 44 | Маскирование секретов в диагностике | forkop | тривиально | нет |
| 45 | Пароль на mixed-прокси и на YACD, доступ с WAN | forkop | тривиально | нет |

---

## Подробный разбор

### 1. Подписки и источники серверов

#### 1. Подписки (Subscription URL) — оба

Главная фича обоих форков. Секция получает не одну ссылку `vless://`, а URL
панели (remnawave, marzban, 3x-ui, Xray-JSON у Happ). Форк скачивает тело,
распознаёт формат, разворачивает в список outbound'ов и собирает из них
selector или urltest.

**netshift.** `proxy_config_type=subscription`, ссылка в
`subscription_url` (список или скаляр — поддерживаются обе формы).
Конвейер: `download_subscription` → `maybe_gunzip_subscription_file` →
`validate_subscription_file` → `normalize_subscription_to_singbox` — всё в
`netshift/files/usr/lib/helpers.sh` (1612 строк против наших 355).
Форматы: base64-блоб, плоский список URI, Xray-JSON (через
`xray_json_to_uri_lines`), vmess-ссылка через `vmess_link_to_json`.
Сборка outbound'ов — `sing_box_cf_add_subscription_outbounds` и
`sing_box_cf_try_subscription_batch` в `sing_box_config_facade.sh`
(900 строк против наших 335). Кэш в `/etc/netshift/subscriptions`, имя
файла — `<секция>.<md5(url)>.<ext>`.

**forkop.** Подписка — не тип секции, а отдельная дочерняя секция
`config subscription_url` с полями `url`, `user_agent`, `auto_hwid`,
`subscription_update_interval`, `download_via_proxy_enabled`,
`prefix_nodes`, `include_urltest_groups`, `hide_urltest_group_outbounds`,
`hide_detour_outbounds`. Парсер — `forkop/files/usr/lib/subscription/parser.uc`
(3007 строк), кэш — `subscription/cache.uc` (2621 строка).

**Перенос: тяжело.** Это самая большая фича из всех. Парсер форматов —
1000+ строк даже в аккуратном виде, плюс кэш, плюс cron, плюс поведение
при недоступности фида.

**Ядро.** Здесь начинается интересное. У clash-rs есть `proxy-providers`:

```yaml
proxy-providers:
  sub1:
    type: http
    url: "https://panel.example/api/sub"
    interval: 3600
    path: ./providers/sub1.yaml
    health-check: { enable: true, url: "...", interval: 300 }
```

Ядро само качает, само обновляет по интервалу, само health-check'ает.
Но `proxy_set_provider.rs` парсит тело **только как Clash-YAML** с ключом
`proxies:` (`serde_yaml::from_slice` в `ProviderScheme`) — base64 и
Xray-JSON он не поймёт. Спасает то, что панели отдают формат по
User-Agent: с UA `clash-meta` почти любая панель вернёт готовый Clash-YAML.

Вывод: **на clash-rs подписка — это три строки конфига вместо тысячи строк
парсера**, если ходить с клэшевым UA. Парсер нужен только как фолбэк для
панелей, отдающих исключительно base64/Xray. На sing-box альтернативы
парсеру нет.

#### 2. Несколько подписок в одной секции — netshift

`list subscription_url` в одной секции: каждый фид качается и валидируется
независимо, узлы сливаются в одну группу с дедупом по имени. Мёртвый фид не
роняет остальные — секция блокируется, только если упали все.
`_collect_subscription_url_handler`, `get_subscription_urls_for_section`
в `bin/netshift`.

**Перенос: средне.** Поверх готовой фичи №1 — небольшая надстройка.
**Ядро:** безразлично. На clash-rs это просто несколько провайдеров в
одной группе через `use: [sub1, sub2]`.

#### 3. Фильтр серверов по ключевым словам — оба

`subscription_filter_include_keywords` / `..._exclude_keywords` — список
подстрок, регистронезависимо, работает и по эмодзи. Include-список пустой —
берём всё. У netshift собирается в JSON
(`build_subscription_filter_keywords_json`) и применяется при разборе
подписки.

**Перенос: тривиально.** Фильтрация списка тегов перед сборкой группы.
**Ядро:** безразлично — и на clash-rs фильтровать придётся нам, потому что
у clash-rs 0.10.8 **нет поля `filter` в proxy-group** (в отличие от mihomo):
в структурах `OutboundGroupUrlTest`/`Select` есть только `proxies`, `use`,
`url`, `interval`, `lazy`, `tolerance`, `icon`.

#### 4. Фильтры по стране, протоколу, транспорту, security, regex — forkop

То же, но богаче: в секции `config urltest` есть
`include_countries` / `exclude_countries`, `include_outbounds` /
`exclude_outbounds`, `include_regex` / `exclude_regex`, плюс отдельно
фильтры по типу протокола, транспорту и типу шифрования. Режимы:
«все», «все кроме выбранных», «только выбранные», «только выбранные кроме
исключений».

**Перенос: средне.** Логика простая, но матрица режимов большая, и это
много работы в LuCI. **Ядро:** безразлично.

#### 5. Группировка узлов и «⚡ Самый быстрый» — netshift

`subscription_group_mode` = `off` | `country` | `prefix`. В режиме
`country` узлы кластеризуются по ведущему эмодзи флага (пара regional
indicator'ов, коды 127462–127487), в режиме `prefix` — по первым N
кодпоинтам имени (`subscription_group_prefix_len`, по умолчанию 2).
На каждую группу строится свой URLTest, а сверху — ещё один URLTest над
URLTest'ами с тегом `⚡ Fastest`, который становится выбором по умолчанию.
Реализация — одна большая jq-программа `sing_box_build_subscription_groups`
в `bin/netshift`.

**Перенос: средне.** jq-программа переносится почти как есть, но у нас
надо продублировать её вывод в YAML для clash-rs.
**Ядро:** безразлично, вложенные группы есть в обоих. На clash-rs
`proxy-groups` может ссылаться на другую группу по имени, так что
двухуровневый url-test строится ровно так же.

#### 6. HWID — оба

Панели вроде remnawave считают устройства по HWID. netshift генерирует его
из MAC (`eth0`, иначе `br-lan`) и модели устройства: `md5sum`, первые 16
символов, формат `xxxx-xxxx-xxxx-xxxx`. Функция `generate_hwid` в
`helpers.sh`, модель — `get_device_model`. У forkop то же самое плюс
ручной ввод: `auto_hwid` / поле HWID в секции подписки.

**Перенос: тривиально.** 20 строк. **Ядро:** безразлично, это про HTTP-запрос.

#### 7. Подбор User-Agent и выбор формата подписки — netshift

Панель отдаёт разный конфиг разным клиентам. netshift перебирает UA до
успеха: `SUBSCRIPTION_USER_AGENT_CANDIDATES="v2rayN Happ Hiddify Clash.Meta
ClashMetaForAndroid"`, отдельный список для Xray-JSON —
`Happ/1.0.0 v2rayN/7.0.0 v2rayNG/1.9.0`. Победивший UA кэшируется.
`subscription_format_preference` = `auto` | `xray` | `singbox` меняет
порядок перебора; явный `subscription_user_agent` отключает перебор.
`build_subscription_user_agent_candidates` в `helpers.sh`.

**Перенос: средне.** **Ядро: да, и это важно.** Для clash-rs нужен ещё один
режим — `clash`, с UA `clash-meta`, и он должен быть по умолчанию, потому
что именно он даёт формат, который clash-rs съест сам через
`proxy-providers`. Наличие уже готового механизма выбора UA — половина
работы по подпискам на clash-стороне.

#### 8–9. Небезопасный TLS и gzip — netshift

`subscription_insecure` добавляет `wget --no-check-certificate` (для панелей
на голом IP с самоподписанным сертификатом), `maybe_gunzip_subscription_file`
разжимает тело, если пришёл gzip.

**Перенос: тривиально** оба. **Ядро:** безразлично.

#### 10. Кэш подписок на постоянной ФС и retry-воркер — netshift

Кэш переехал из `/tmp` в `/etc/netshift/subscriptions`
(`migrate_subscription_cache_from_tmp`), чтобы переживать перезагрузку.
На старте, пока сети ещё нет, поднимается фоновый воркер
`start_subscription_startup_retry_worker`, который дотягивает подписки
позже. Если кэша нет и скачать не вышло, секция помечается
`mark_subscription_outbound_unavailable` и её правила подменяются на
`reject`, чтобы трафик не утёк мимо туннеля.

**Перенос: средне.** Логика «нет подписки — не выпускаем трафик наружу»
важна с точки зрения утечек, и её стоит взять вместе с самой подпиской.
**Ядро:** безразлично.

#### 11–12. Cron и сброс кэша — netshift/forkop

`add_subscription_cron_job` пишет crontab по
`subscription_update_interval` (30m / 1h / 3h / 6h / 12h / 1d), причём не в
:00, а в :17 — чтобы не бить в панель всем миром одновременно.
`subscription_clear_cache_and_redownload` вызывается кнопкой из диагностики.

**Перенос: тривиально.** **Ядро:** безразлично. На clash-rs интервал
обновления вообще уезжает в `proxy-providers.interval` и cron не нужен.

#### 13–14. Префиксы и импорт групп провайдера — forkop

`prefix_nodes` / `node_prefix` дописывают текст к имени каждого узла из
подписки — чтобы потом фильтровать по нему. `include_urltest_groups`
импортирует URLTest-группы, которые вернула сама панель;
`hide_urltest_group_outbounds` прячет из дашборда узлы, уже входящие в эти
группы; `hide_detour_outbounds` прячет промежуточные узлы, используемые
другими как detour (см. `subscription_hidden_outbound` в
`singbox/generator.uc`).

**Перенос: тривиально / средне.** **Ядро:** безразлично.

#### 15. Selector и URLTest вставкой списка ссылок — netshift

`proxy_config_type` = `selector_text` | `urltest_text`, и вместо
DynamicList — одна textarea, куда вставляется список ссылок по одной в
строке. Битые строки пропускаются с предупреждением, остальные собираются.
Это фича релиза 0.9.2 (коммит `ce3c917`).

**Перенос: тривиально.** Разбор построчно + переиспользование существующего
`add_proxy_outbound`. **Ядро:** безразлично, парсер ссылок у нас и так
раздваивается по ядрам.

#### 16. VMess — оба

Апстрим vmess не умеет. netshift добавил `sing_box_cm_add_vmess_outbound`,
`vmess_link_to_json` (декодирование base64(JSON) формы v2rayN) и
`_add_vmess_transport_and_security`.

**Перенос: средне.** Один протокол — это разбор ссылки + генерация
outbound'а в обоих генераторах. **Ядро:** безразлично, vmess есть и в
sing-box, и в clash-rs (`proxy_set_provider.rs` перечисляет
`hysteria2, reject, socks, trojan, vless, vmess`).

#### 17. XHTTP-транспорт и sing-box-extended — оба

Транспорт xhttp есть только в форке ядра
[sing-box-extended](https://github.com/EikeiDev/OpenWRT-sing-box-extended).
netshift добавил `sing_box_cm_set_xhttp_transport_for_outbound` и
`sing_box_cm_set_http_transport_for_outbound`, детект ядра
(`is_sing_box_extended`) и переключение стабильное ↔ extended из LuCI.

**Перенос: средне** на sing-box-ветке. **Ядро: только sing-box.** У clash-rs
xhttp нет. Для нашей ветки это тупик — см. раздел «Бессмысленно на clash-rs».

### 2. Группы, выбор сервера и наблюдение

#### 18. Несколько URLTest-групп на секцию — forkop

В апстрипе URLTest — это свойство секции, одна штука. У forkop это дочерние
секции `config urltest` с полем `section`, у каждой свои `name`,
`check_interval`, `tolerance`, `testing_url`, `idle_timeout`,
`interrupt_exist_connections`, `pin_dashboard` и весь набор фильтров из
пункта 4.

**Перенос: средне.** Требует перехода от «опция на секции» к «дочерняя
секция», то есть трогает схему UCI и LuCI-модель.
**Ядро:** безразлично, url-test-группы есть в обоих.

#### 19. Группы приоритета (failover) — forkop

Уровни: верхний — главный, ниже — резервы. Пока верхний жив, работает он;
упал — переключаемся вниз; поднялся — возвращаемся. Настройки: интервал
проверки текущего уровня, интервал перепроверки старших уровней,
«при переходе тестировать все серверы и брать быстрейший, а не первый
живой», «рвать существующие соединения при переключении».
`singbox/priority.uc` (492 строки) — это отдельный демон с pid-файлом
(`/var/run/forkop/priority.pid`), который опрашивает состояние и дёргает
селектор.

**Перенос: тяжело** на sing-box (у sing-box нет типа outbound'а
«fallback», его приходится эмулировать демоном).
**Ядро: на clash-rs почти нативно** — там есть готовый тип группы
`fallback` (`OutboundGroupFallback` с `proxies`, `use`, `url`, `interval`,
`lazy`), который делает ровно это внутри ядра, без демона. То есть на нашей
clash-ветке фича стоит «средне» и сводится к генерации одной группы.

#### 20. Сортировка по задержке и ручной тест — forkop

`sort_by_latency` в секции сортирует серверы в дашборде по замеренной
задержке, `latency_test_url` в настройках задаёт URL проверки, кнопка
«Test latency» гоняет тест по требованию.

**Перенос: средне** (фронт + RPC-метод). **Ядро:** безразлично, задержки
берутся из Clash API, а он есть у обоих (`clash-lib/src/app/api/handlers/`:
`proxy.rs`, `group.rs`, `connection.rs`, `traffic.rs`, `memory.rs`).

#### 21. Каскадные подключения — forkop

`outbound_detour_enabled` / `outbound_detour_section`: подключаться к
серверам этой секции через другую секцию. Плюс отдельно
`download_lists_via_proxy_section` и `download_components_via_proxy_section`
— качать списки и компоненты через выбранную секцию.

**Перенос: средне.** **Ядро:** безразлично по смыслу, по-разному по форме:
sing-box — поле `detour` у outbound'а, clash-rs — `dialer-proxy`
(в коде оно называется `connect_via`, см. `CommonConfigOptions` в
`config/internal/proxy.rs`). Важное ограничение clash-rs: `dialer-proxy`
работает только на «сыром» прокси, не на группе, и не может указывать на
имя внутри proxy-provider.

#### 22–23. Дашборд: фильтр серверов и страна — forkop

`dashboard_filter_mode`, `dashboard_include_outbounds` /
`dashboard_exclude_outbounds`, `dashboard_include_groups` /
`dashboard_exclude_groups` — что показывать на дашборде, независимо от
того, что реально в конфиге. `detect_server_country` = `flag_emoji`
(парсить флаг из имени) или запрос к country.is;
`singbox/country.uc` + `renderFlagEmojis.ts` со шрифтом
`TwemojiCountryFlags.woff2` (Chrome под Windows флаги не рисует).

**Перенос: средне**, чисто фронтендовая работа. **Ядро:** безразлично.

#### 24. Мониторинг соединений — forkop

Отдельная вкладка: активные и закрытые соединения, uplink/downlink, объём
трафика, память, кнопки «закрыть соединение» и «закрыть все». Данные —
Clash API (`socket.service.ts` + `config/connections.uc`), для сетевой
статистики подключены `kmod-inet-diag` / `kmod-netlink-diag`.

**Перенос: средне** (вкладка + RPC). **Ядро:** безразлично — у clash-rs
есть и `/connections`, и `/traffic`, и `/memory`.

### 3. Маршрутизация

#### 25. Global Proxy — netshift

Флаг `global_proxy` на секции: весь трафик, не подошедший ни под чьи
списки, уходит в эту секцию (`route.final` → её outbound), плюс nft
заворачивает в ядро вообще всё. Глобальной может быть только одна секция.
`_determine_global_proxy_section`, `get_global_proxy_section`,
`_check_global_proxy_direct_needed` в `bin/netshift`, плюс правки в
`nft.sh`. Работает в связке с секциями `exclusion` — то, что надо оставить
напрямую, перечисляется в них.

**Перенос: средне.** Меняется хвост маршрутизации и nft — обе вещи у нас
общие для ядер. **Ядро:** безразлично: sing-box — `route.final`,
clash-rs — `MATCH,<группа>` последним правилом. Побочно: у clash-rs есть
даже режим `mode: global`, но он глобальный на весь конфиг, а не на секцию,
так что для подкоповской модели не подходит.

**Осторожно:** именно эту фичу netshift сломал в 0.9.3, см. отдельный раздел.

#### 26. Действие Bypass — forkop

В апстрипе действие `direct` заворачивает трафик в sing-box и там выпускает
через `direct-out`. forkop переименовал его в Bypass и поменял смысл:
трафик по возможности **вообще не попадает в ядро** — nft просто не ставит
метку tproxy. В `nft/apply.uc` это видно в `section_priority_action`:
`bypass` даёт вердикт `counter accept` без `meta mark set`, тогда как все
«захватывающие» действия (`connection`, `block`, `zapret`, `zapret2`,
`byedpi`) метку ставят.

**Перенос: средне.** Правки локализованы в `nft.sh` и в логике
маршрутизации, новых подсистем не нужно.
**Ядро: безразлично полностью** — это чистый nftables, ядро о таком трафике
даже не знает. Приятный бонус: меньше трафика через ядро — меньше
нагрузка на роутер и меньше поверхность для багов clash-rs.

#### 27. Условия маршрутизации в правиле — forkop

Вместо «секция = набор списков» у forkop правила с условиями: домен
(с префиксами `full:`, `keyword:`, `regex:`), IP или подсеть, порт или
диапазон портов, устройство-источник. Правила перетаскиваются мышью,
верхнее проверяется первым. Разбор и нормализация — `config/rule.uc`
(`rule_condition_csv_value`, `normalize_port_range_value`,
`prefixed_domain_kind_value` и т. д.).

**Перенос: тяжело.** Это смена модели конфига, а не добавление опции: у нас
секция описывается списками, а тут — упорядоченным набором правил.
**Ядро: да**, форма правил принципиально разная (JSON-объекты против
строк `DOMAIN-KEYWORD,foo,PROXY`), хотя набор условий выражается в обоих.

#### 28. Несколько интерфейсов и JSON-outbound на секцию — forkop

`config section_interface` — дочерние секции с именем интерфейса и своим
`domain_resolver`; `list outbound_jsons` — несколько сырых JSON-outbound'ов
в одной секции.

**Перенос: средне.** **Ядро:** частично — сырой JSON-outbound на clash-rs
превращается в «сырой YAML-прокси», это у нас в mapping.md уже
предусмотрено (`add_raw_outbound`).

#### 29. Маршрутизация и DNS по устройствам — forkop

`local_devices.js` в LuCI + условие «Device or IP» в правиле: применять
секцию только к перечисленным локальным адресам, с подстановкой имён из
DHCP-аренд. В 1.0.5 то же расширили на действие `dns` («Add device-aware
DNS actions», «Add source-aware DNS routing»).

**Перенос: средне.** Реализуется на nft через `SRC-IP` наборы — то есть
там же, где у нас уже живут `fully_routed_ips`.
**Ядро:** безразлично. Более того, это **прямое решение нашего пробела из
mapping.md** («правила по инбаунду не выражаются в clash-rs, обход —
`SRC-IP-CIDR`»): forkop уже показал, что модель «секция привязана к
устройствам» рабочая.

#### 30. Блокировка публичных DoH — netshift

`block_doh`: чтобы приложения не обходили DNS роутера через собственный
DoH. Реализация — `sing_box_cm_add_doh_block_route_rule` в
`sing_box_config_manager.sh`: inline-ruleset со списком известных адресов
(Cloudflare, Google, Quad9, OpenDNS, AdGuard, Яндекс — 13 IPv4 и 12 IPv6,
константы `DOH_BLOCK_IPV4_CIDRS` / `DOH_BLOCK_IPV6_CIDRS`) и правило
`action: reject` на tproxy-инбаунде.

**Перенос: тривиально.** Список констант + одно правило.
**Ядро:** безразлично: на clash-rs это `IP-CIDR,1.1.1.1/32,REJECT` и далее
по списку, или один `rule-provider` с `behavior: ipcidr`.
В LuCI netshift честно предупреждает: включать только после перевода
апстрим-DNS на UDP или DoT, иначе отрежешь сам себе резолвер.

#### 31. IPv6 — оба

`enable_ipv6`: v6-tproxy, v6 DNS-инбаунд, v6 FakeIP, ipv6-наборы в nft
(`nft_create_ipv6_set`, `nft_add_set_elements_from_file_chunked_v6` в
`nft.sh` — файл вырос с 69 строк до 144). Плюс защита от включения без
рабочей связности: `has_global_ipv6_addr`, `has_ipv6_default_route`,
`ipv6_appears_usable`, `should_force_wget_ipv4`.

**Перенос: тяжело.** Дублирование всей цепочки для второго семейства.
**Ядро: да, и на clash-rs есть дыры.** У clash-rs `dns.ipv6` — это булев
флаг «отвечать ли на AAAA», а `fake_ip_range` один и по умолчанию
`198.18.0.1/16`, то есть v4-only: отдельного v6-FakeIP-пула нет.
tproxy-порт скалярный, `bind-address` один. Прежде чем браться, надо
проверить на живом трафике, что clash-rs вообще принимает v6 на tproxy.

### 4. DNS

#### 32. DNS через прокси / через секцию — оба

Апстрим-DNS ходит не напрямую, а через туннель. У netshift это
`dns_via_outbound` + `dns_outbound_section` (`_get_dns_detour_tag` в
`bin/netshift`, с фолбэком на первую подходящую секцию, если указанная
невалидна). Bootstrap-DNS всегда остаётся прямым — иначе курица и яйцо.
У forkop — `dns_detour_enabled` / `dns_detour_section`.

**Перенос: средне.** **Ядро: на clash-rs нативно и даже приятнее.**
clash-rs парсит фрагмент URL сервера: `parse_outbound_proxy` вытаскивает
`proxy=<имя>` из `#`-фрагмента, `parse_outbound_interface` — `interface=`.
То есть достаточно написать:

```yaml
dns:
  nameserver: ["tls://1.1.1.1#proxy=MyVLESS"]
```

Это стоит внести в `docs/mapping.md` — в таблице DNS у нас этой строки нет.

#### 33. Резервные DNS с автопереключением — forkop

Список основных и bootstrap DNS-серверов, приоритет по порядку. Отдельный
демон `singbox/dns_failover.uc` (379 строк, pid в
`/var/run/forkop/dns-failover.pid`) резолвит `example.com` каждые
`dns_check_interval` (по умолчанию 10s) с таймаутом `dns_check_timeout`
(2s), при провале переключается на следующий, и каждые
`dns_recovery_check_interval` (60s) проверяет, не ожил ли более
приоритетный.

**Перенос: тяжело** на sing-box — нужен свой демон и перегенерация конфига
на лету. **Ядро: на clash-rs частично нативно** — там есть
`dns.fallback` + `dns.fallback_filter`, то есть базовый фолбэк ядро делает
само. Возврат к приоритетному серверу — уже поведение конкретной реализации,
надо проверять.

#### 34. Отдельные DNS-серверы для доменов — forkop

Секция с `action=dns`: для перечисленных доменов использовать указанный
DNS-сервер, с выбором протокола (UDP / DoT / DoH), опционально через другую
секцию, опционально только для указанных устройств (1.0.5).
`dns/apply.uc` + `singbox/dns.uc`.

**Перенос: средне.** **Ядро:** безразлично: sing-box — правила в `dns.rules`,
clash-rs — `dns.nameserver-policy` (`HashMap<String, String>`) плюс тот же
`#proxy=`. Фильтр по устройствам в `nameserver-policy` не выражается — эту
часть придётся решать через nft/отдельный DNS-листенер.

### 5. Обход DPI

#### 35. Zapret и Zapret2 как действие секции — forkop

Секция с `action=zapret` или `zapret2`: трафик, попавший под её условия,
отправляется в NFQUEUE, где его обрабатывает `nfqws` из пакета zapret. То
есть DPI-десинхронизация применяется точечно, к выбранным доменам, а не ко
всему трафику. Номер очереди назначает сам forkop
(`providers/nfqueue/runtime.uc`, 705 строк), стратегия проверяется
валидатором (`providers/nfqueue/validator.uc`, 382 строки): запрещены
`--daemon`, `--dry-run`, `--version`, свой `fwmark`, свой номер очереди,
hostlist-шаблоны и выбор ресурсов внутри nfqws — потому что ресурсы уже
выбраны sing-box'ом. Диагностика ловит конфликт с самостоятельным сервисом
zapret (`providers/zapret/check.uc`).

**Перенос: тяжело.** Целая подсистема: провайдер, жизненный цикл процесса,
валидатор стратегий, диагностика, интеграция в nft.
**Ядро: безразлично полностью** — трафик по этому пути в ядро не заходит
вовсе. Это единственная крупная фича forkop, которую можно делать один раз
и сразу для обоих ядер.

**Риск:** тянет внешние пакеты (`zapret`) и требует `kmod-nfqueue`.

#### 36. ByeDPI как действие секции — forkop

То же, но проще: `ciadpi` поднимается локально как SOCKS-прокси на порту
`1080+N`, и в конфиг ядра добавляется socks-outbound на `127.0.0.1:<порт>`
плюс правило маршрутизации. `providers/byedpi/runtime.uc` (555 строк) +
`has_socks_outbound` / `has_route_rule` для самопроверки.

**Перенос: средне** — заметно легче zapret, потому что вся стыковка с ядром
сводится к socks-outbound'у.
**Ядро: безразлично** — socks-выход есть и в sing-box, и в clash-rs.

### 6. Свой сервер на роутере

#### 37. VLESS Reality / MTProto / Tailscale / JSON-inbound — forkop

`config server` поднимает на роутере **входящий** сервер: VLESS+Reality
(с генерацией keypair через `sing-box generate reality-keypair`, полями
`reality_private_key`, `reality_public_key`, `reality_short_id`,
`reality_handshake_server`), MTProto-прокси для Telegram (secret, FakeTLS,
padding, domain fronting), Tailscale-endpoint (control URL, auth key,
advertise routes / exit node), или произвольный JSON-inbound. Плюс генерация
клиентской ссылки и QR-кода, подсказки по открытию порта на firewall.
`server/service.uc` (1088 строк) + `luci-app-forkop/.../server.js` (89 КБ).

**Перенос: тяжело.** Отдельная сущность в UCI, отдельная вкладка, генерация
ключей, QR.
**Ядро: только sing-box, и это не обойти.** У clash-rs есть `listeners` с
типами `http`, `socks`, `mixed`, `tproxy`, `redir`, `tunnel`, `shadowsocks`,
`anytls` (плюс `inbound-providers`) — ни VLESS-сервера, ни Reality, ни
MTProto, ни Tailscale там нет. Максимум, что воспроизводится на clash-rs, —
shadowsocks-сервер.

### 7. Эксплуатация

#### 38. Самообновление пакета из LuCI — оба

netshift: `updater.sh` (1958 строк) — `updates_check_podkop`,
`updates_self_update_podkop`, скачивание ассетов, бэкап конфига,
восстановление после подмены (`updates_restore_after_swap`), джобы с
состоянием в файлах (`updates_write_running_job_state`), асинхронный
фронтенд, откат (`updates_stable_rollback`), самолечение связности
(`updates_selfheal_connectivity`, `updates_write_temp_resolver`).
Умеет и opkg/ipk, и apk. forkop: `components/updater.uc` + `updates.uc`
(2960 строк) — то же плюс обновление сторонних компонентов.

**Перенос: средне.** Кода много, но он изолированный и почти не трогает
основной конвейер. **Ядро:** безразлично.

**Риск:** обновление себя из-под себя — классический источник кирпичей.
Нужен бэкап конфига и проверка целостности до подмены
(`updates_backup_is_complete`, `updates_verify_copy`).

#### 39. Менеджер компонентов — оба

netshift: вкладка Component Manager (`manager.js`) переключает ядро
стабильное ↔ sing-box-extended в один клик, с бэкапом старого бинарника,
проверкой версии, откатом и восстановлением сети после подмены
(`_updates_install_sing_box_extended_core`, `updates_stable_rollback`,
`b9cd602 добавил самовосстановление сети при смене ядер`). Ставит ядро в
tmpfs, чтобы влезало в маленький overlay.
forkop: вкладка Updates + `component_update_check_enabled` /
`component_update_check_interval` — автопроверка обновлений всех
компонентов; и главное — **из зависимостей пакета убран `+sing-box`**,
ядро ставится менеджером.

**Перенос: средне.** **Ядро: для нас это критично.** clash-rs в
репозиториях OpenWrt нет — значит, без механизма «скачать бинарник с
GitHub-релиза под нужную архитектуру, проверить, положить, откатиться при
неудаче» нашу ветку нельзя раздать людям. netshift даёт готовый шаблон:
`updates_resolve_sing_box_extended_arch_suffix`, `updates_system_uses_musl`,
`updates_extended_asset_url` — ровно эта задача, только под другой репозиторий.

#### 40. Обход rate-limit GitHub API — netshift

Анонимный GitHub API даёт 60 запросов в час на IP, и роутеры за CGNAT
упираются в лимит не по своей вине. netshift читает версию и качает ассеты
через redirect-пути `github.com/.../releases/latest` →
`releases/tag/<tag>` → `releases/download/<tag>/<asset>`, которые под лимит
не подпадают; API оставлен фолбэком.
`updates_github_resolve_redirect` в `updater.sh`.

**Перенос: тривиально.** 30 строк. **Ядро:** безразлично.
Нам это нужно и без обновлятора: списки правил мы тоже тянем с GitHub.

#### 41. Watchdog ядра — netshift

`monitor_sing_box` в `bin/netshift` — отцепленный через setsid процесс,
пишет свой pid в `/var/run/netshift_monitor.pid`, каждые 10 секунд
проверяет, жив ли sing-box. Умер — восстанавливает dnsmasq
(чтобы роутер не остался без DNS), ждёт с экспоненциальной паузой
(10, 20, 40… до 300 секунд) и перезапускает. После 5 подряд падений
сдаётся, оставив DNS в рабочем состоянии. Штатную остановку отличает по
флагу `shutdown_correctly`.

**Перенос: тривиально-средне.** ~100 строк шелла.
**Ядро: безразлично.** Для нас это даже ценнее, чем для netshift:
clash-rs у нас новый и непроверенный, и «упал — подняли, DNS вернули»
снимает худший сценарий (роутер без интернета).

#### 42. Механизм миграций конфига — forkop

`option config_version '1.0.5'` + `list applied_migrations` со списком
уже применённых миграций по имени (`interface_sections`,
`enable_component_checks`, `http_connection_urls`), плюс
`config/migration.uc` (1584 строки), который их применяет идемпотентно.

**Перенос: средне.** **Ядро:** безразлично. Для нас важно на будущее: мы
уже добавляем в конфиг новые ключи (выбор ядра, переключатель `.srs`/текст),
и рано или поздно понадобится менять их форму на живых установках.
Сравните с netshift, у которого миграции разовые и захардкоженные
(`migrate_legacy_subscription_url_option`) — и который из-за этого поймал
баг «Outbound section not found» в 0.9.0.

#### 43. Сохранение выбранного сервера между перезагрузками — netshift, откачено

sing-box хранит выбор в `cache.db`, а тот лежит в tmpfs и вычищается при
перезагрузке — после ребута селектор откатывался на дефолт. Фикс
(PR #21 + доработка): снапшот живого кэша в overlay
(`/etc/netshift/cache.db`) при чистой остановке и после успешного PATCH
через Clash API, восстановление обратно в `/tmp` при старте, критическая
секция под `flock` против гонки двух одновременных выборов, и сравнение
через `cmp`, чтобы не жечь флеш зря.

**Перенос: средне.** Сама по себе фича здравая.
**Ядро:** безразлично по смыслу; у clash-rs аналог — `profile.store-selected`
(и `store-fake-ip`), причём файл кладётся рядом с конфигом, то есть при
конфиге в `/etc` проблема tmpfs не возникает вовсе. То есть на clash-стороне
это, скорее всего, вообще не наша забота.

**Внимание:** попало под откат 0.9.6 — в текущем коде netshift этого нет.

#### 44–45. Мелочи безопасности — forkop

Маскирование ссылок подписки и ключей WireGuard в выводе диагностики
(`helpers/maskDiagnostics.ts` + `e3f1619c Mask subscription URLs and
WireGuard keys in diagnostics`) — полезно, потому что диагностику люди
несут в чат. Пароль на mixed-прокси (`mixed_proxy_username` /
`mixed_proxy_password`), секретный ключ и доступ с WAN для YACD
(`yacd_secret_key`).

**Перенос: тривиально.** **Ядро:** безразлично — у clash-rs
`external-controller` + `secret` штатные, а `authentication` для
mixed-порта есть в корне конфига.

---

## Бессмысленно на clash-rs

Тут либо ядро делает это само, либо не умеет вовсе и не будет.

| Фича | Почему |
|---|---|
| **XHTTP-транспорт, переключение на sing-box-extended** | у clash-rs нет xhttp и нет «расширенного» форка ядра. Тупиковая ветка для нашего конфига |
| **Свой сервер VLESS Reality / MTProto / Tailscale** | у clash-rs `listeners` только `http`, `socks`, `mixed`, `tproxy`, `redir`, `tunnel`, `shadowsocks`, `anytls`. Ни Reality, ни MTProto, ни Tailscale не будет |
| **Парсер форматов подписки** (base64 / Xray-JSON / UA-перебор) | наполовину лишний: панели по UA `clash-meta` отдают готовый Clash-YAML, а его clash-rs скармливает себе сам через `proxy-providers` — с обновлением по интервалу и health-check'ом. Парсер нужен только фолбэком |
| **Скачивание и расписание обновления подписки, cron** | `proxy-providers: {type: http, url, interval}` делает это внутри ядра |
| **Группы приоритета (failover-демон)** | есть штатный тип группы `fallback` — ровно та же семантика, без внешнего демона и без опроса |
| **Тонкая настройка URLTest** (интервал, tolerance, ленивость) | `url-test` с `interval`, `tolerance`, `lazy` — нативно |
| **DNS через прокси** | нативно: `nameserver: ["tls://1.1.1.1#proxy=Имя"]` (`parse_outbound_proxy` в `app/dns/config.rs`) |
| **Резервные DNS** | `dns.fallback` + `dns.fallback-filter` частично закрывают |
| **Снапшот `cache.db` в overlay** | у clash-rs `profile.store-selected` пишется рядом с конфигом, а не в tmpfs |

Обратное предупреждение, чтобы не обмануться: **фильтрация серверов
(по стране, ключевым словам, regex) на clash-rs НЕ бесплатна**. В mihomo у
proxy-group есть `filter`, а в clash-rs 0.10.8 его нет — в
`OutboundGroupUrlTest` и `OutboundGroupSelect` только `proxies`, `use`,
`url`, `interval`, `lazy`, `tolerance`, `icon`. Значит группировку и
фильтрацию мы всё равно делаем сами при генерации.

## Что netshift откатил и почему

Релиз 0.9.6 — это дословный код 0.9.2 (коммит `ce3c917`), переупакованный
под новым номером, чтобы застрявшие на битых 0.9.3–0.9.5 могли «обновиться»
назад. В истории репозитория 0.9.3 и 0.9.4 остались тегами, но в `main` их
нет.

**Что произошло.** Судя по `git log 0.9.2..0.9.3`, в 0.9.3 автор влил
пачку сторонних PR целиком, включая PR #22 от стороннего контрибьютора,
который притащил историю **другого ребрендинга подкопа** («Padkap» —
коммиты `baeb226 Rebrand project to Padkap`, `a3c8d66 Fix ShellCheck
directives for Padkap libraries`) вместе с его собственными изменениями
маршрутизации: `5121509 Пропуск списков для глобального прокси` и
`90d9091 Global proxy lists act as exclusions`.

**Что сломалось.** Именно эти два коммита. Идея была «если включён
global_proxy, списки секции не нужны — всё и так идёт в туннель», и
`configure_routing_for_section_lists` стала возвращаться сразу:

```sh
if [ "$global_proxy" -eq 1 ]; then
    log "Global proxy mode enabled ...: skipping routing list configuration." "info"
    return 0
fi
```

В результате `route_rule_tag` не создавался вовсе, правило со списками в
`.route.rules` не появлялось, и весь трафик, подошедший под
`community_lists` и прочие списки, проваливался в `route.final` → на
`direct-out`. То есть **включённый «глобальный прокси» отправлял всё
напрямую** — прямо противоположное обещанному, и без единой ошибки в логах.
Хотфикс 0.9.4 (`c25ea85`) вернул создание правила обратно, но, по словам
автора релиза, «на как минимум одной сообщённой конфигурации не помог», и
проще оказалось откатить всё.

**Что попало под откат заодно** — эти вещи сами по себе не виноваты, но в
текущем коде netshift их нет:

- `dns_outbound_mode` = `single` | `multi` | `paranoid` (`3ab85e5`) —
  правило `dns.rules` с `inbound: [dns-in]`, гонящее запросы с внутреннего
  резолвера `127.0.0.42:53` через outbound секции;
- `detect_wan_device()` — определение egress-устройства через
  `ip route show default` вместо захардкоженного
  `ubus call network.interface.wan status`, с фолбэком на
  `auto_detect_interface: true`. Лечило i/o timeout на мульти-WAN
  (wan2 / wanb / cellular);
- снапшот `cache.db` в overlay (пункт 43 выше);
- транспорт `httpupgrade` в подписочных outbound'ах
  (`sing_box_cm_set_httpupgrade_transport_for_outbound`);
- защита `backup_sing_box_cache` от рассинхрона констант.

**Вывод для нас.** Опасен не список фич, а **конкретный паттерн**: «раз
включён глобальный режим, можно не строить правила». Правила надо строить
всегда, а глобальность выражать только хвостом (`route.final` / `MATCH`).
Остальные четыре пункта из отката — нормальные, их можно рассматривать
самостоятельно, просто помня, что в живом netshift они не обкатаны.

И отдельно, оргвывод: 0.9.3 сломался потому, что в основную ветку влили
чужую ветку целиком, вместе с чужим ребрендингом. Нам, с двумя ядрами и
раздвоенным генератором, такое противопоказано вдвойне.

## Что уже есть у нас или в апстриме

Переносить нечего, проверено по нашему `podkop/files/etc/config/podkop`,
`luci-app-podkop/.../section.js` и `settings.js`:

- секции `proxy` / `vpn` / `block` / `exclusion`, типы `url` / `selector` /
  `urltest` / `outbound`;
- URLTest с `check_interval`, `tolerance`, `testing_url`;
- Hysteria2 (включая диапазоны портов — `1365feb`, `1543d97`), VLESS,
  Shadowsocks, Trojan, SOCKS4/4a/5;
- community-списки, `user_domains` / `user_subnets` (dynamic и text),
  `local_*_lists`, `remote_*_lists`;
- `fully_routed_ips`, `routing_excluded_ips`;
- mixed-прокси (`mixed_proxy_enabled`, `mixed_proxy_port`) — но без пароля;
- `domain_resolver_enabled` + тип и адрес резолвера на секцию;
- `download_lists_via_proxy` + выбор секции (`4146804`, `34f49c3`);
- мониторинг Bad WAN (`enable_badwan_interface_monitoring`,
  `badwan_monitored_interfaces`, `badwan_reload_delay`);
- `enable_output_network_interface` / `output_network_interface`;
- YACD (`enable_yacd`) — но без секрета и без доступа с WAN;
- `disable_quic`, `exclude_ntp`, `dont_touch_dhcp`, `shutdown_correctly`,
  `dns_rewrite_ttl`, `log_level`, `update_interval`;
- дашборд и диагностика на Clash API;
- у нас сверх апстрима — слой выбора ядра (`258a140`), генератор Clash
  (`b11a001`), переезд списков на текстовый формат (`82b56dc`, `5ca1bf5`),
  харнесс юнит-тестов (`872a63c`).

## Что предлагаю делать в первую очередь

Приоритет считаю по трём вещам: разблокирует ли это нашу основную задачу
(clash-rs), сколько стоит, и не сломает ли совместимость с конфигом podkop.

### Сначала — то, без чего ветка не выходит к людям

**1. Менеджер компонентов, урезанный до установки ядра** (№39, №40).
Это не «фича», это условие поставки. clash-rs нет ни в одном фиде OpenWrt,
и пока мы не умеем скачать бинарник под нужную архитектуру, проверить его,
положить и откатиться при неудаче, ветка живёт только на нашем стенде.
netshift даёт готовый шаблон: `updates_resolve_sing_box_extended_arch_suffix`,
`updates_system_uses_musl`, `updates_extended_asset_url`,
`updates_stable_rollback`, `updates_selfheal_connectivity` в
`netshift/files/usr/lib/updater.sh` — надо поменять репозиторий и имена
ассетов. Сразу берём и обход rate-limit через redirect-пути (№40, тридцать
строк): он нужен и для списков правил, которые мы и так тянем с GitHub.
Форк forkop подтверждает направление — он вообще выкинул `+sing-box` из
`DEPENDS` и ставит ядро сам.
Сложность: средне. Зависимость от ядра: нет. Риск: подмена бинарника
из-под работающего сервиса — обязателен бэкап и откат.

**2. Watchdog ядра** (№41).
Сто строк шелла, `monitor_sing_box` в `netshift/files/usr/bin/netshift`,
переносится почти дословно. Ценность у нас выше, чем у netshift: clash-rs
для нас новый, падений мы ещё не видели, а цена падения — роутер без DNS,
потому что dnsmasq остаётся перенастроенным на мёртвый резолвер. Watchdog
восстанавливает dnsmasq **до** попытки перезапуска — это и есть главное в
нём, а не сам рестарт.
Сложность: тривиально. Зависимость от ядра: нет.

### Затем — то, что даёт максимум пользы на единицу работы

**3. Подписки, но по clash-первому маршруту** (№1, №2, №3, №6, №7, №11).
Самая востребованная фича обоих форков и единственная причина, по которой
люди уходят с подкопа. Но делать её надо не так, как netshift.

Порядок такой: сначала clash-ветка, где подписка — это
`proxy-providers: {type: http, url, interval, health-check}` и запрос с UA
`clash-meta`; парсер не нужен вовсе, обновление и проверку живости делает
ядро. Это буквально десятки строк генерации. Уже на этом этапе фича
работает у пользователей clash-rs целиком.

Потом, отдельной задачей, — фолбэк-парсер для панелей, которые Clash-формат
не отдают: base64 и Xray-JSON, механизм перебора UA (№7) из
`build_subscription_user_agent_candidates`, HWID (№6), фильтр по ключевым
словам (№3), несколько фидов со слиянием (№2). Вот этот кусок уже общий для
обоих ядер и по объёму сравним со всем остальным списком вместе взятым.

Важно взять и защиту от утечки: если подписка не скачалась и кэша нет,
секция должна отдавать `reject`, а не молча выпускать трафик мимо туннеля
(`mark_subscription_outbound_unavailable`, пункт 10).
Сложность: средне на clash, тяжело на sing-box.
Риск для совместимости: новый `proxy_config_type` — аддитивное изменение,
старые конфиги не ломает.

**4. Блокировка DoH** (№30) и **действие Bypass** (№26).
Две дешёвые вещи с непропорционально большой отдачей.

DoH-блок — список из 25 констант плюс одно reject-правило; на clash-rs
вообще один `rule-provider` с `behavior: ipcidr`. Закрывает реальную дыру:
браузер с включённым DoH обходит всю маршрутизацию подкопа целиком.

Bypass — переделка действия «direct» так, чтобы трафик не заходил в ядро, а
просто не получал tproxy-метку в nft. Это чистый nftables, ядру всё равно,
и у нас он даст двойную выгоду: меньше трафика через clash-rs — меньше шансов
напороться на его незрелые места, плюс заметно меньше нагрузка на слабый
роутер. Смотреть `nft_priority_verdict_args` и `section_priority_action` в
`forkop/files/usr/lib/nft/apply.uc`.
Сложность: тривиально и средне. Зависимость от ядра: нет у обеих.

### Потом, по мере надобности

**5. Group Proxy** (№25) — но строго с оглядкой на разбор выше: правила
списков строим **всегда**, глобальность выражаем только хвостом маршрутизации.

**6. Маршрутизация по устройствам** (№29) — попутно закрывает наш
задокументированный пробел «правила по инбаунду не выражаются в clash-rs»:
forkop показывает, что привязка секции к SRC-IP — рабочая замена.

**7. Механизм миграций конфига** (№42) — пока установок мало, дёшево;
когда их станет много, поздно.

**8. Мониторинг соединений** (№24) и **сортировка по задержке** (№20) —
чистый фронтенд на готовом Clash API, обе ветки получают одинаково.

### Чего не делать

- **XHTTP и sing-box-extended** (№17) — на clash-rs не существует, а
  поддерживать фичу, работающую только на половине конфигураций, дороже,
  чем не иметь её.
- **Свой сервер на роутере** (№37) — самая заметная фича forkop и самая
  для нас неподходящая: на clash-rs нет ни VLESS-инбаунда, ни Reality, ни
  MTProto. Получится кнопка, которая работает только на sing-box.
- **Группы приоритета демоном** (№19) — если делать, то не как forkop
  (внешний демон), а генерацией `fallback`-группы на clash-rs; на sing-box
  оставить как есть.
- **Условия маршрутизации в правиле** (№27) — идея хорошая, но это смена
  модели конфига целиком. Пока у нас не доделан второй генератор, трогать
  схему UCI — гарантированный способ никогда его не доделать.
- **Zapret/ByeDPI** (№35, №36) — сами по себе ядронезависимы и потому
  соблазнительны, но это отдельная подсистема с внешними пакетами. Не
  раньше, чем clash-ветка станет рабочей. Из двух ByeDPI дешевле вдвое:
  он стыкуется с ядром одним socks-outbound'ом.
