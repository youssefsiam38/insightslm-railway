#!/usr/bin/env bash
# shellcheck disable=SC2013,SC2015,SC2016  # single-quoted literals are matched, not expanded
# End-to-end test against a deployed bundle, from the outside, through the requests InsightsLM's web app sends.
# The probe notebook it creates as the owner is deleted again at the end.
#   tests/railway-smoke.sh https://app-domain https://kong-domain
# Optional:
#   OWNER_EMAIL=... OWNER_PASSWORD_FILE=/path   sign in as the owner (the file holds the password)
#   INSIGHTSLM_SMOKE_AI=1                       the deployment has working model settings: also add a PDF, pasted
#                                               text and a website, chat, and generate an audio overview
#   ALLOWED_EMAIL=...                           an address in INSIGHTSLM_ALLOWED_SIGNUPS: signs up, checks isolation
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
usage="usage: railway-smoke.sh https://app https://kong"
APP_URL=${1:?$usage}; APP_URL=${APP_URL%/}
GATEWAY_URL=${2:?$usage}; GATEWAY_URL=${GATEWAY_URL%/}
export APP_URL GATEWAY_URL
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077
stamp=$(date +%s)
NB=""
cleanup() {
  if [ -n "$NB" ] && [ -s "$TEST_TMP/owner" ]; then
    rest_as "$TEST_TMP/owner" "/rest/v1/notebooks?id=eq.$NB" -X DELETE >/dev/null || true
  fi
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# rest_wait TOKEN_FILE PATH JQ_FILTER EXPECTED [TIMEOUT] -> the last value; 0 once the filter yields EXPECTED
rest_wait() {
  local tf=$1 path=$2 filter=$3 want=$4 timeout=${5:-240} start got
  start=$(date +%s)
  while :; do
    got=$(rest_as "$tf" "$path" | jq -r "$filter" 2>/dev/null || true)
    [ "$got" = "$want" ] && { printf '%s' "$got"; return 0; }
    if [ $(( $(date +%s) - start )) -ge "$timeout" ]; then printf '%s' "$got"; return 1; fi
    sleep 5
  done
}

section "TLS and routing"
wait_for_code "$APP_URL/" 200 600 || true
assert_eq "the web app over https" "200" "$(http_code "$APP_URL/")"
for u in "$APP_URL/" "$GATEWAY_URL/auth/v1/health"; do
  assert_contains "valid certificate: ${u#https://}" "SSL certificate verify ok" "$(curl -sv -o /dev/null --max-time 30 "$u" 2>&1 || true)"
done
host=${APP_URL#https://}
assert_contains "http -> https" "https://$host" "$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --max-time 20 "http://$host/")"
assert_eq "client-side routes get the app" "200" "$(http_code "$APP_URL/notebook/probe")"

section "the web app carries this deployment's values"
index=$(curl -s --max-time 30 "$APP_URL/" || true)
assert_not_contains "no third-party page script" "gpteng" "$index"
bundle=""
for js in $(grep -oE '/assets/[^"]+\.js' <<<"$index" | sort -u); do bundle+=$(curl -s --max-time 30 "$APP_URL$js" || true); done
assert_not_contains "no build placeholder left" "insightslm-railway-placeholder-" "$bundle"
assert_contains "the browser is pointed at this gateway" "$GATEWAY_URL" "$bundle"
anon=$(grep -oE 'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+' <<<"$bundle" | head -1 || true)
[ -n "$anon" ] && pass "found the public anon key" || fail "no anon key in the bundle"
printf 'ANON_KEY=%s\n' "$anon" > "$TEST_TMP/keys"

section "the gateway"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/rest/v1/notebooks")"
assert_eq "the anon key reads no notebooks" "[]" "$(rest_as anon '/rest/v1/notebooks?select=id')"
assert_eq "Realtime's tenant API is blocked" "403" "$(http_code "$GATEWAY_URL/realtime/v1/api/tenants" -H "apikey: $anon")"
assert_eq "Realtime accepts a websocket over TLS" "101" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$GATEWAY_URL/realtime/v1/websocket?apikey=$anon&vsn=1.0.0" || true)"
for cb in process-document-callback audio-generation-callback; do
  assert_eq "$cb is closed" "403" "$(http_code -X POST "$GATEWAY_URL/functions/v1/$cb" -H 'Content-Type: application/json' --data '{"source_id":"00000000-0000-0000-0000-000000000000"}')"
done
assert_eq "user functions refuse anonymous callers" "401" "$(http_code -X POST "$GATEWAY_URL/functions/v1/send-chat-message" -H 'Content-Type: application/json' --data '{}')"
head -c 18 /dev/urandom | base64 | tr -d '/+=\n' > "$TEST_TMP/probe-pw"
assert_eq "a stranger's signup is refused" "500" "$(sign_up "probe-$stamp@example.com" "$TEST_TMP/probe-pw")"

if [ -n "${OWNER_EMAIL:-}" ] && [ -n "${OWNER_PASSWORD_FILE:-}" ]; then
  section "the owner"
  sign_in "$OWNER_EMAIL" "$OWNER_PASSWORD_FILE" "$TEST_TMP/owner" && pass "owner signs in" || fail "owner sign-in failed"
fi
if [ -s "$TEST_TMP/owner" ]; then
  owner_id=$(token_sub "$TEST_TMP/owner")
  assert_eq "the owner has a profile" "1" "$(rest_as "$TEST_TMP/owner" "/rest/v1/profiles?select=id&id=eq.$owner_id" | jq 'if type == "array" then length else -1 end')"
  NB=$(rest_as "$TEST_TMP/owner" /rest/v1/notebooks -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
    --data "{\"title\":\"Railway probe $stamp\",\"user_id\":\"$owner_id\",\"generation_status\":\"pending\"}" | jq -r '.[0].id // empty')
  [ -n "$NB" ] && pass "creates a notebook" || fail "could not create a notebook"
  SRC=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
    --data "{\"notebook_id\":\"$NB\",\"title\":\"probe.pdf\",\"type\":\"pdf\",\"processing_status\":\"uploading\",\"metadata\":{}}" | jq -r '.[0].id // empty')
  python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/probe.pdf" "InsightsLM railway probe document $stamp" "second page"
  assert_eq "uploads a PDF to its folder" "200" "$(upload_as "$TEST_TMP/owner" sources "$NB/$SRC.pdf" "$TEST_TMP/probe.pdf" application/pdf)"
  rest_as "$TEST_TMP/owner" "/rest/v1/sources?id=eq.$SRC" -X PATCH -H 'Content-Type: application/json' --data "{\"file_path\":\"$NB/$SRC.pdf\",\"processing_status\":\"processing\"}" >/dev/null

  if [ "${INSIGHTSLM_SMOKE_AI:-0}" = 1 ]; then
    section "n8n processes the notebook"
    assert_contains "process-document starts the workflow" "^200 " "$(fn_as "$TEST_TMP/owner" process-document "{\"sourceId\":\"$SRC\",\"filePath\":\"$NB/$SRC.pdf\",\"sourceType\":\"pdf\"}")"
    assert_contains "generate-notebook-content names the notebook" '^200 .*"success":true' \
      "$(fn_as "$TEST_TMP/owner" generate-notebook-content "{\"notebookId\":\"$NB\",\"filePath\":\"$NB/$SRC.pdf\",\"sourceType\":\"pdf\"}")"
    # The workflow calls back only after its vector-store insert succeeded, so "completed" means the chunks are
    # stored (the documents table is not readable through REST; tests/smoke.sh checks it in the database).
    assert_eq "the PDF is extracted, summarised, embedded, and called back" "completed" \
      "$(rest_wait "$TEST_TMP/owner" "/rest/v1/sources?select=processing_status&id=eq.$SRC" '.[0].processing_status' completed 300 || true)"
    assert_contains "the source holds the PDF's text" "railway probe document $stamp" "$(rest_as "$TEST_TMP/owner" "/rest/v1/sources?select=content&id=eq.$SRC")"
    assert_eq "and the model's summary" "true" "$(rest_as "$TEST_TMP/owner" "/rest/v1/sources?select=summary&id=eq.$SRC" | jq '(.[0].summary // "") | length > 0')"
    assert_contains "send-chat-message reaches the chat workflow" "^200 " "$(fn_as "$TEST_TMP/owner" send-chat-message "{\"session_id\":\"$NB\",\"message\":\"What does the probe say?\"}")"
    assert_eq "the answer is stored for the chat view" "2" "$(rest_wait "$TEST_TMP/owner" "/rest/v1/n8n_chat_histories?select=id&session_id=eq.$NB" 'if type == "array" then length else -1 end' 2 180 || true)"
    TXT=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
      --data "{\"notebook_id\":\"$NB\",\"title\":\"Pasted\",\"type\":\"text\",\"content\":\"Pasted probe text\",\"processing_status\":\"processing\",\"metadata\":{}}" | jq -r '.[0].id')
    fn_as "$TEST_TMP/owner" process-additional-sources "{\"type\":\"copied-text\",\"notebookId\":\"$NB\",\"title\":\"Pasted\",\"content\":\"Pasted probe text\",\"sourceIds\":[\"$TXT\"],\"timestamp\":\"$stamp\"}" >/dev/null
    assert_eq "pasted text is processed" "completed" "$(rest_wait "$TEST_TMP/owner" "/rest/v1/sources?select=processing_status&id=eq.$TXT" '.[0].processing_status' completed 240 || true)"
    WEB=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
      --data "{\"notebook_id\":\"$NB\",\"title\":\"https://example.org/probe\",\"type\":\"website\",\"url\":\"https://example.org/probe\",\"processing_status\":\"processing\",\"metadata\":{}}" | jq -r '.[0].id')
    fn_as "$TEST_TMP/owner" process-additional-sources "{\"type\":\"multiple-websites\",\"notebookId\":\"$NB\",\"urls\":[\"https://example.org/probe\"],\"sourceIds\":[\"$WEB\"],\"timestamp\":\"$stamp\"}" >/dev/null
    assert_eq "a website is processed" "completed" "$(rest_wait "$TEST_TMP/owner" "/rest/v1/sources?select=processing_status&id=eq.$WEB" '.[0].processing_status' completed 240 || true)"
    assert_contains "generate-audio-overview starts the podcast" "^200 " "$(fn_as "$TEST_TMP/owner" generate-audio-overview "{\"notebookId\":\"$NB\"}")"
    assert_eq "the audio overview completes" "completed" \
      "$(rest_wait "$TEST_TMP/owner" "/rest/v1/notebooks?select=audio_overview_generation_status&id=eq.$NB" '.[0].audio_overview_generation_status' completed 300 || true)"
    audio=$(rest_as "$TEST_TMP/owner" "/rest/v1/notebooks?select=audio_overview_url&id=eq.$NB" | jq -r '.[0].audio_overview_url // empty')
    assert_contains "its link is on the public gateway" "^$GATEWAY_URL/storage/v1/" "$audio"
    [ -n "$audio" ] && assert_eq "the browser can play it" "RIFF" "$(curl -s --max-time 30 "$audio" | head -c 4 || true)"
    assert_contains "refresh-audio-url signs a new link" '^200 .*"audioUrl"' "$(fn_as "$TEST_TMP/owner" refresh-audio-url "{\"notebookId\":\"$NB\"}")"
    assert_contains "generate-note-title answers" '^200 {"title"' "$(fn_as "$TEST_TMP/owner" generate-note-title '{"content":"Notes about the railway probe"}')"
  fi

  if [ -n "${ALLOWED_EMAIL:-}" ]; then
    section "an allowlisted colleague"
    assert_eq "may sign up" "200" "$(sign_up "$ALLOWED_EMAIL" "$TEST_TMP/probe-pw")"
    sign_in "$ALLOWED_EMAIL" "$TEST_TMP/probe-pw" "$TEST_TMP/friend" && pass "and sign in" || fail "the allowlisted user could not sign in"
    assert_eq "sees none of the owner's notebooks" "[]" "$(rest_as "$TEST_TMP/friend" "/rest/v1/notebooks?select=id&id=eq.$NB")"
    assert_contains "nor the owner's uploaded file" "^4" "$(http_code "$GATEWAY_URL/storage/v1/object/sources/$NB/$SRC.pdf" -H "apikey: $anon" -H "Authorization: Bearer $(cat "$TEST_TMP/friend")")"
  fi

  section "clean up"
  rest_as "$TEST_TMP/owner" "/rest/v1/notebooks?id=eq.$NB" -X DELETE >/dev/null
  assert_eq "the probe notebook is deleted" "[]" "$(rest_as "$TEST_TMP/owner" "/rest/v1/notebooks?select=id&id=eq.$NB")"
  NB=""
fi
summary
