# Соответствие sing-box → Clash (clash-rs)

Карта для замены ядра. Слева — то, что подкоп генерирует сейчас
(`sing_box_config_manager.sh`, 39 функций, и `sing_box_config_facade.sh`, 11),
справа — во что это превращается в схеме clash-rs.

Схема справа снята не с общих представлений о Clash, а с исходников
`clash-lib/src/config/def.rs` версии v0.10.8 — у clash-rs есть свои отличия
от оригинального Clash и от mihomo.

## Ключевые структурные различия

Их четыре, и они определяют почти всю работу.

### 1. Инбаунды: массив с тегами → скалярные порты

sing-box держит `inbounds[]` — массив типизированных записей, у каждой свой
`tag`. clash-rs держит порты верхним уровнем:

```yaml
tproxy-port: 7894
mixed-port: 7890
redir-port: 7892
bind-address: "*"
```

**Следствие, которое надо решить отдельно:** у инбаундов нет тегов, значит
нет и правил вида «этот трафик пришёл с tproxy-in». Подкоп этим пользуется —
у него есть правила с `inbound: tproxy-in`. Прямого эквивалента нет.
Варианты обхода в разделе «Пробелы».

### 2. Выходы: один массив → два раздела

| sing-box | clash-rs |
|---|---|
| `outbounds[]` со всеми типами вперемешку | `proxies[]` — только настоящие прокси |
| `{type: "selector"}` в том же массиве | `proxy-groups[]` — группы отдельно |
| `{type: "direct", tag: "direct-out"}` | `DIRECT` — встроенное имя, не объявляется |
| `{type: "block"}` | `REJECT` — встроенное имя |

То есть `main-out` (у подкопа это `direct` с привязкой к интерфейсу) в Clash
объявляется не так: привязка к интерфейсу задаётся полем `interface-name`
у конкретного прокси или глобально.

### 3. Правила: объекты JSON → строки

sing-box:

```json
{"action":"route","rule_set":["telegram"],"outbound":"main-out"}
```

clash-rs:

```yaml
rules:
  - RULE-SET,telegram,main
  - DOMAIN-SUFFIX,example.com,VLESS
  - MATCH,DIRECT
```

Формат строки: `ТИП,ЗНАЧЕНИЕ,ЦЕЛЬ[,no-resolve]`. Порядок значим, первое
совпадение выигрывает — как и в sing-box.

### 4. Наборы правил: `.srs` → rule-providers

**Самое неприятное различие.** Подкоп кормит sing-box бинарными `.srs`:

```
https://github.com/itdoginfo/allow-domains/releases/latest/download/telegram.srs
```

clash-rs формат `.srs` не читает вовсе. У него `rule-providers`:

```yaml
rule-providers:
  telegram:
    type: http
    behavior: domain        # domain | ipcidr | classical
    format: yaml            # yaml | text | mrs
    url: "...telegram.lst"
    path: ./rules/telegram.lst
    interval: 86400
```

Хорошая новость: itdoginfo публикует те же списки в текстовом виде
(`Subnets/IPv4/telegram.lst`, `Domains/.../*.lst`), а `format: text` их
принимает. То есть менять надо ссылки и разбор, а не источник данных.

## Таблица функций

### Лог и общее

| sing_box_cm_* | Clash | Примечание |
|---|---|---|
| `configure_log` | `log-level` | у sing-box объект, тут скаляр |
| `save_config_to_file` | — | тот же, только YAML/JSON |
| `configure_cache_file` | `profile.store-selected`, `profile.store-fake-ip` | путь не задаётся, clash-rs хранит рядом с конфигом |
| `configure_clash_api` | `external-controller`, `secret`, `external-ui` | нативно, а не через `experimental` |

### DNS

| sing_box_cm_* | Clash | Примечание |
|---|---|---|
| `configure_dns` | `dns.enable`, `dns.listen` | |
| `add_udp_dns_server` | `dns.nameserver: ["8.8.8.8"]` | просто строка |
| `add_tls_dns_server` | `dns.nameserver: ["tls://1.1.1.1"]` | схема в URL |
| `add_https_dns_server` | `dns.nameserver: ["https://.../dns-query"]` | схема в URL |
| `add_fakeip_dns_server` | `dns.enhanced-mode: fake-ip` + `dns.fake-ip-range` | не сервер, а режим |
| `add_dns_route_rule` | `dns.nameserver-policy: {"+.example.com": "..."}` | карта, а не список правил |
| `patch_dns_route_rule` | правка той же карты | |
| `add_dns_reject_rule` | `dns.fake-ip-filter` либо `REJECT` в `rules` | зависит от смысла |
| DNS через прокси | фрагмент `#proxy=<имя>` у сервера | нативно, отдельной опции не нужно |
| DNS через интерфейс | фрагмент `#interface=<имя>` у сервера | нативно |

Про фрагменты: clash-rs разбирает их в `parse_outbound_proxy` (`app/dns/config.rs`),
то есть «резолвить через такой-то выход» пишется прямо в адресе сервера:

```yaml
dns:
  nameserver:
    - "https://dns.google/dns-query#proxy=VLESS-out"
```

У sing-box для этого отдельное поле `detour` у DNS-сервера. Форма разная,
смысл тот же, обходных путей не требуется.

Диапазон fake-ip совпадает: подкоп использует `198.18.0.0/15`, в примерах
clash-rs `198.18.0.2/16`. Формат одинаковый, менять нечего.

### Инбаунды

| sing_box_cm_* | Clash |
|---|---|
| `add_tproxy_inbound` | `tproxy-port` + `bind-address` |
| `add_mixed_inbound` | `mixed-port` |
| `add_direct_inbound` | эквивалента нет, см. «Пробелы» |

`tcp_fast_open` и `udp_fragment` у clash-rs на уровне инбаунда не
настраиваются — тихо теряются.

### Выходы

| sing_box_cm_* | Clash | Примечание |
|---|---|---|
| `add_direct_outbound` | `DIRECT` | встроенное, не объявляется |
| `add_vless_outbound` | `proxies: [{type: vless, ...}]` | поля другие, см. ниже |
| `add_shadowsocks_outbound` | `{type: ss, cipher, password}` | `method` → `cipher` |
| `add_trojan_outbound` | `{type: trojan, password, sni}` | |
| `add_socks_outbound` | `{type: socks5}` | |
| `add_interface_outbound` | `interface-name` у прокси | не отдельный выход |
| `add_raw_outbound` | вставка объекта в `proxies` как есть | сохраняем как приём |
| `add_urltest_outbound` | `proxy-groups: [{type: url-test}]` | `interval`, `tolerance` |
| `add_selector_outbound` | `proxy-groups: [{type: select}]` | переключается тем же Clash API |
| `set_tls_for_outbound` | `tls: true`, `servername`, `skip-cert-verify`, `reality-opts` | |
| `set_ws_transport_for_outbound` | `network: ws`, `ws-opts` | |
| `set_grpc_transport_for_outbound` | `network: grpc`, `grpc-opts` | |

Поля VLESS переименовываются целиком:

| sing-box | clash-rs |
|---|---|
| `server`, `server_port` | `server`, `port` |
| `uuid` | `uuid` |
| `flow` | `flow` |
| `tls.server_name` | `servername` |
| `tls.reality.public_key` | `reality-opts.public-key` |
| `tls.reality.short_id` | `reality-opts.short-id` |
| `tls.utls.fingerprint` | `client-fingerprint` |
| `packet_encoding` | `packet-encoding` |

### Маршрутизация

| sing_box_cm_* | Clash |
|---|---|
| `configure_route` | `mode: rule` + порядок `rules` |
| `add_route_rule` | строка `RULE-SET,<набор>,<цель>` |
| `add_reject_route_rule` | `...,REJECT` |
| `add_hijack_dns_route_rule` | режим fake-ip делает это сам |
| `add_options_route_rule` | частично `no-resolve` |
| `sniff_route_rule` | `sniffer` (отдельный раздел) |
| `add_resolve_rule` | эквивалента нет, fake-ip решает иначе |
| `patch_route_rule` | правка строки на месте |
| `add_inline_ruleset` | `rule-providers` с `type: file` |
| `add_inline_ruleset_rule` | дописывание в файл провайдера |
| `add_local_ruleset` | `rule-providers: {type: file, path}` |
| `add_remote_ruleset` | `rule-providers: {type: http, url, interval}` |

### Фасад

| sing_box_cf_* | что делать |
|---|---|
| `add_proxy_outbound` | переписать разбор ссылок под поля Clash |
| `_add_outbound_security` | → `tls`/`reality-opts`/`client-fingerprint` |
| `_add_outbound_transport` | → `network` + `ws-opts`/`grpc-opts` |
| `add_json_outbound` | вставка в `proxies` без изменений |
| `add_interface_outbound` | → `interface-name` |
| `add_dns_server` | → `dns.nameserver` |
| `add_mixed_inbound_and_route_rule` | → `mixed-port` + правило |
| `proxy_domain` | → правило `DOMAIN,...` |
| `override_domain_port` | эквивалента нет, см. «Пробелы» |
| `add_single_key_reject_rule` | → `...,REJECT` |

## Пробелы

Здесь эквивалента нет, и это надо решать, а не замалчивать.

**Правила по инбаунду.** У Clash нет тегов инбаундов, поэтому правило
«трафик с tproxy идёт туда-то» не выражается. Обход: разделять не по
инбаунду, а по `SRC-IP-CIDR` — у подкопа и так есть привязка секций к
адресам устройств. Требует проверки на живом трафике.

**`add_direct_inbound`.** Подкоп поднимает отдельный слушатель на
`127.0.0.42:53` для DNS. В clash-rs роль DNS-слушателя играет `dns.listen`.

**`override_domain_port`.** Подмены порта у назначения в правилах Clash нет.
Надо смотреть, ради чего это в подкопе, и есть ли обход.

**`.srs`.** Переезд на текстовые списки. Источник тот же, ссылки другие,
разбор `rulesets.sh` придётся править.

**`tcp_fast_open`, `udp_fragment`.** Настроек нет — просто не переносим.

## Что переиспользуется без изменений

- `nft.sh` — правила nftables с tproxy-меткой, ядру безразличны
- `rulesets.sh` — скачивание и разбор списков, кроме формата `.srs`
- `helpers.sh`, `logging.sh`, `constants.sh`
- вся модель секций в UCI и большая часть `/usr/bin/podkop`

## Оценка объёма

| | строк |
|---|---|
| `sing_box_config_manager.sh` | 1508 |
| `sing_box_config_facade.sh` | 335 |
| **переписать** | **~1850** |
| остальной бэкенд (переиспользуется) | ~3600 |

Плюс правки в `/usr/bin/podkop` там, где он зовёт `sing_box_*` и управляет
сервисом sing-box.
