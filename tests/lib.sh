#!/usr/bin/env bash
# shellcheck disable=SC2015  # `cond && pass || fail` is intentional; pass/fail always succeed
# Shared helpers for insightslm-railway tests. Source this file; do not execute it.
# Secrets are never echoed. Only names, lengths, and pass/fail results are printed.

: "${APP_URL:=http://localhost:${INSIGHTSLM_TEST_PORT:-13600}}"
: "${GATEWAY_URL:=http://kong.localhost:${INSIGHTSLM_TEST_GATEWAY_PORT:-18600}}"
# A cold start pulls n8n, builds nothing, and provisions six workflows before the app serves.
: "${TEST_TIMEOUT:=900}"

TEST_TMP="${TEST_TMP:-$(mktemp -d)}"
export TEST_TMP
_PASS=0; _FAIL=0

pass() { _PASS=$((_PASS+1)); printf '  PASS  %s\n' "$*"; }
fail() { _FAIL=$((_FAIL+1)); printf '  FAIL  %s\n' "$*" >&2; }
die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
section() { printf '\n== %s ==\n' "$*"; }
summary() { printf '\n%d passed, %d failed\n' "$_PASS" "$_FAIL"; [ "$_FAIL" -eq 0 ]; }

# here-strings, not pipes: `grep -q` exits on the first match and a pipe writer would get SIGPIPE,
# which `pipefail` reports as failure when the haystack is larger than the pipe buffer
assert_eq() { if [ "$2" = "$3" ]; then pass "$1 ($3)"; else fail "$1: expected [$2] got [$3]"; fi; }
assert_contains() { if grep -q -- "$2" <<<"$3"; then pass "$1"; else fail "$1: missing [$2]"; fi; }
assert_not_contains() { if grep -q -- "$2" <<<"$3"; then fail "$1: found forbidden [$2]"; else pass "$1"; fi; }

# curl still prints 000 through -w when it cannot connect, so `|| true`, never `|| echo 000`
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 30 "$@" || true; }

wait_for_code() {
  local url=$1 want=$2 timeout=${3:-$TEST_TIMEOUT} start code
  start=$(date +%s)
  while :; do
    code=$(http_code "$url")
    [ "$code" = "$want" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for %s -> %s (last %s)\n' "$url" "$want" "$code" >&2; return 1; fi
    sleep 5
  done
}

# wait_for_log SERVICE PATTERN [MIN_COUNT] [TIMEOUT]
wait_for_log() {
  local svc=$1 pat=$2 min=${3:-1} timeout=${4:-$TEST_TIMEOUT} start n
  start=$(date +%s)
  while :; do
    n=$(compose logs --no-color --no-log-prefix "$svc" 2>/dev/null | grep -cE -- "$pat" || true)
    [ "$n" -ge "$min" ] && return 0
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf 'timed out waiting for [%s] in %s logs\n' "$pat" "$svc" >&2; return 1; fi
    sleep 3
  done
}

compose() { docker compose -f "$REPO_ROOT/compose.yaml" "$@"; }

# The image a compose service runs, selected by service name. `compose config --images` sorts by
# image name, which picks the wrong one in a file with several services.
service_image() { compose config --format json | jq -r --arg s "$1" '.services[$s].image'; }

# mint_keys JWT_SECRET -> writes ANON_KEY / SERVICE_ROLE_KEY lines to $TEST_TMP/keys
mint_keys() { JWT_SECRET="$1" node "$REPO_ROOT/lib/mint-supabase-keys.mjs" > "$TEST_TMP/keys"; }
anon_key() { sed -n 's/^ANON_KEY=//p' "$TEST_TMP/keys"; }
service_key() { sed -n 's/^SERVICE_ROLE_KEY=//p' "$TEST_TMP/keys"; }

# sign_in EMAIL PASSWORD_FILE TOKEN_OUT -> 0 on success; the token goes to a file, never stdout
sign_in() {
  local email=$1 pwfile=$2 out=$3 body code
  body=$(curl -s -w '\n%{http_code}' --max-time 30 -X POST "$GATEWAY_URL/auth/v1/token?grant_type=password" \
    -H "apikey: $(anon_key)" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg e "$email" --rawfile p "$pwfile" '{email:$e, password:($p|rtrimstr("\n"))}')" || true)
  code=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$code" = "200" ] || return 1
  jq -er '.access_token' <<<"$body" > "$out" 2>/dev/null || return 1
  [ -s "$out" ]
}

# sign_up EMAIL PASSWORD_FILE [EXTRA_METADATA_JSON] -> prints the HTTP status; on 200 the token goes to $TEST_TMP/signup-token
sign_up() {
  local email=$1 pwfile=$2 extra=${3:-'{}'} data body code
  data=$(jq -nc --arg e "$email" --rawfile p "$pwfile" --argjson x "$extra" \
    '{email:$e, password:($p|rtrimstr("\n")), data:({full_name:"Test"} + $x)}')
  body=$(curl -s -w '\n%{http_code}' --max-time 30 -X POST "$GATEWAY_URL/auth/v1/signup" \
    -H "apikey: $(anon_key)" -H 'Content-Type: application/json' --data "$data" || true)
  code=${body##*$'\n'}; body=${body%$'\n'*}
  [ "$code" = 200 ] && { jq -r '.access_token // empty' <<<"$body" > "$TEST_TMP/signup-token"; }
  printf '%s' "$code"
}

# rest_as TOKEN_FILE PATH [curl args...] -> body. TOKEN_FILE "anon" uses the anon key alone.
rest_as() {
  local tf=$1 path=$2; shift 2
  if [ "$tf" = anon ]; then
    curl -s --max-time 30 "$GATEWAY_URL$path" -H "apikey: $(anon_key)" "$@" || true
  else
    curl -s --max-time 30 "$GATEWAY_URL$path" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$tf")" "$@" || true
  fi
}

# psql_admin SQL -> tuples only, unaligned
psql_admin() { compose exec -T db psql -U supabase_admin -d postgres -tAc "$1"; }

# The user id inside a Supabase access token (the file holds the token).
token_sub() {
  local p; p=$(cut -d. -f2 "$1" | tr '_-' '/+')
  while [ $(( ${#p} % 4 )) -ne 0 ]; do p="$p="; done
  base64 -d <<<"$p" | jq -r .sub
}

# fn_as TOKEN_FILE FUNCTION JSON_BODY -> "<status> <body>", as supabase.functions.invoke calls an edge function
fn_as() {
  local tf=$1 name=$2 body=$3 out code
  out=$(curl -s -w '\n%{http_code}' --max-time 120 -X POST "$GATEWAY_URL/functions/v1/$name" -H "apikey: $(anon_key)" \
    -H "Authorization: Bearer $(cat "$tf")" -H 'Content-Type: application/json' --data "$body" || true)
  code=${out##*$'\n'}; printf '%s %s' "$code" "${out%$'\n'*}"
}

# wait_sql SQL EXPECTED [TIMEOUT] -> prints the last value; returns 0 once the query yields EXPECTED
wait_sql() {
  local sql=$1 want=$2 timeout=${3:-180} start got
  start=$(date +%s)
  while :; do
    got=$(psql_admin "$sql" 2>/dev/null | tr -d '\r' | head -1 || true)
    [ "$got" = "$want" ] && { printf '%s' "$got"; return 0; }
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf '%s' "$got"; return 1; fi
    sleep 3
  done
}

# upload_as TOKEN_FILE BUCKET PATH FILE CONTENT_TYPE -> HTTP status, as supabase.storage.from(bucket).upload does
upload_as() {
  local tf=$1 bucket=$2 path=$3 file=$4 ctype=$5
  curl -s -o /dev/null -w '%{http_code}' --max-time 60 -X POST "$GATEWAY_URL/storage/v1/object/$bucket/$path" \
    -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$tf")" -H "Content-Type: $ctype" -H 'x-upsert: false' \
    --data-binary "@$file" || true
}
