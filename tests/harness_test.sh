#!/bin/sh
# Самопроверка харнесса. Если он врёт, врут и все остальные тесты.
# shellcheck shell=sh
. "$(dirname "$0")/lib.sh"

it "assert_eq принимает равные строки"
assert_eq "abc" "abc"

it "assert_ne принимает разные строки"
assert_ne "abc" "abd"

it "assert_contains находит подстроку"
assert_contains "ss-out" '{"tag":"ss-out"}'

it "assert_not_contains не находит отсутствующее"
assert_not_contains "vmess" '{"type":"vless"}'

it "assert_valid_json принимает валидный JSON"
assert_valid_json '{"a":1}'

it "assert_json_eq не зависит от порядка ключей"
assert_json_eq '{"a":1,"b":2}' '{"b":2,"a":1}'

it "assert_json_eq не зависит от пробелов"
assert_json_eq '{"a":1}' '  {  "a"  :  1  }  '

it "assert_jq достаёт вложенное поле"
assert_jq '.proxies[0].name' "VLESS" '{"proxies":[{"name":"VLESS"}]}'

it "assert_jq работает с массивами"
assert_jq '.rules | length' "2" '{"rules":["a","b"]}'

it "пустой конфиг Clash валиден"
assert_valid_json "$(clash_empty_config)"

it "в пустом конфиге нет прокси"
assert_jq '.proxies | length' "0" "$(clash_empty_config)"

it "в пустом конфиге есть все четыре раздела"
assert_jq 'keys | join(",")' "proxies,proxy-groups,rule-providers,rules" \
	"$(printf '%s' "$(clash_empty_config)" | "$JQ" -S .)"

finish
