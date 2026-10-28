#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$ROOT_DIR/trafira/files/usr/lib"
CHECK="$LIB/providers/nfqueue/check.uc"
checks=0

check_rule() {
  local expected="$1" description="$2" rule="$3" status=0
  printf 'table inet fw4 {\n chain incoming {\n  %s\n }\n}\n' "$rule" |
    ucode -L "$LIB" "$CHECK" nft-queue-overlap TrafiraTable 4300 4555 >/dev/null || status=$?
  if [ "$status" != "$expected" ]; then
    printf 'FAIL: %s: expected exit %s, got %s\n' "$description" "$expected" "$status" >&2
    exit 1
  fi
  checks=$((checks + 1))
}

# Removing the explicit per-rule opt-in must turn the first case into a conflict.
check_rule 1 'explicitly owned incoming queue' 'ct reply packets 1-15 counter queue flags bypass to 4300 comment "trafira-ignore"'
check_rule 0 'same queue without ownership declaration' 'queue flags bypass to 4300'
check_rule 0 'descriptive comment is not ownership' 'queue num 4300 bypass comment "first replies of YouTube_Zapret2 TCP to nfqws2"'
check_rule 1 'owned queue range' 'queue num 4300-4303 bypass comment "trafira-ignore"'
check_rule 0 'foreign overlapping range' 'queue num 4299-4301 bypass'
check_rule 0 'ownership does not cover a range crossing provider boundary' 'queue num 4299-4301 bypass comment "trafira-ignore"'
check_rule 0 'ownership does not cover range above provider boundary' 'queue num 4555-4556 bypass comment "trafira-ignore"'
check_rule 0 'set is not an owned static target' 'queue num { 4300, 4301 } bypass comment "trafira-ignore"'
check_rule 0 'reversed range is not an owned target' 'queue num 4301-4300 bypass comment "trafira-ignore"'
check_rule 1 'nonoverlapping queue' 'queue num 4299 bypass'
check_rule 1 'upper nonoverlapping range' 'queue num 4556-4560 bypass'
check_rule 0 'marker substring is invalid' 'queue num 4300 bypass comment "prefix trafira-ignore"'
check_rule 0 'marker suffix is invalid' 'queue num 4300 bypass comment "trafira-ignore:4300"'
check_rule 0 'unquoted marker is invalid' 'queue num 4300 bypass comment trafira-ignore'
check_rule 0 'unterminated marker is invalid' 'queue num 4300 bypass comment "trafira-ignore'
check_rule 0 'escaped marker imitation is invalid' 'queue num 4300 bypass comment "trafira\x2dignore"'
check_rule 0 'embedded quoted marker is invalid' 'queue num 4300 bypass comment "text \"trafira-ignore\""'
check_rule 0 'marker cannot hide queue in another statement' 'queue num 4300; queue num 4301 comment "trafira-ignore"'
check_rule 1 'comment queue text does not invent overlap' 'counter comment "queue num 4300"'
check_rule 1 'comment number does not invent overlap' 'queue num 123 bypass comment "4300"'
check_rule 1 'queue text in an escaped string is not an expression' 'counter comment "quoted \"queue num 4300\""'

status=0
printf 'table inet fw4 {\n chain c {\n queue num 4300 comment "trafira-ignore"\n queue num 4301\n }\n}\n' |
  ucode -L "$LIB" "$CHECK" nft-queue-overlap TrafiraTable 4300 4555 >/dev/null || status=$?
[ "$status" = 0 ] || { printf 'FAIL: marker must apply only to its own rule\n' >&2; exit 1; }

status=0
printf 'table inet TrafiraTable {\n chain c {\n queue num 4300\n }\n}\ntable inet fw4 {\n chain c {\n queue num 4301\n }\n}\n' |
  ucode -L "$LIB" "$CHECK" nft-queue-overlap TrafiraTable 4300 4555 >/dev/null || status=$?
[ "$status" = 0 ] || { printf 'FAIL: own table must not exempt later foreign tables\n' >&2; exit 1; }

status=0
printf 'table inet TrafiraTable {\n chain c {\n queue num 4300\n }\n}\n' |
  ucode -L "$LIB" "$CHECK" nft-queue-overlap TrafiraTable 4300 4555 >/dev/null || status=$?
[ "$status" = 1 ] || { printf 'FAIL: own table must remain exempt\n' >&2; exit 1; }

printf 'NFQUEUE comment ownership checks passed (%s rule cases, 3 ruleset cases)\n' "$checks"
