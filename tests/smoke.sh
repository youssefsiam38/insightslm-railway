#!/usr/bin/env bash
# shellcheck disable=SC2013,SC2015,SC2016  # single-quoted literals are matched, not expanded
# End-to-end test of the whole bundle on a fresh local stack, through the requests InsightsLM's web app sends:
# REST and Storage through the gateway, the edge functions, and n8n's workflows behind them (with the
# stand-in model provider, mock-ai).
#   tests/smoke.sh               (INSIGHTSLM_TEST_KEEP=1 leaves the stack running)
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077
JWT_LOCAL=local-test-only-jwt-secret-000000000000000000000000000000
OWNER_EMAIL=owner@example.com
printf '%s' local-test-only-owner-password > "$TEST_TMP/owner-pw"
stamp=$(date +%s)

cleanup() {
  [ "${INSIGHTSLM_TEST_KEEP:-0}" = 1 ] || compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

section "start a fresh stack"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d --no-build >/dev/null 2>&1 || die "compose up failed"
wait_for_log app "serving the web app|FATAL" 1 || die "the app did not finish starting"
compose logs --no-color --no-log-prefix app 2>&1 | grep -q FATAL && { compose logs --no-color --tail 40 app >&2; die "the app's start-up failed"; }
wait_for_code "$APP_URL/" 200 120 || die "web app"
mint_keys "$JWT_LOCAL"
pass "all services are up"

section "start-up steps"
app_logs=$(compose logs --no-color --no-log-prefix app 2>&1)
assert_contains "InsightsLM's migration is applied" "applied migration 20250606152423_v0.1.sql" "$app_logs"
assert_contains "the owner is created" "owner account created for o\*\*\*@example.com" "$app_logs"
assert_contains "n8n's owner is claimed for the deployer" "n8n owner created for o\*\*\*@example.com" "$app_logs"
assert_eq "all six workflows are published" "6" "$(grep -c 'published$' <<<"$app_logs")"
assert_eq "n8n runs them from its own database" "6" "$(compose exec -T db psql -U postgres -d n8n -tAc "select count(*) from workflow_entity where \"activeVersionId\" is not null" | tr -d ' \r')"
assert_eq "n8n keeps the credentials encrypted" "0" "$(compose exec -T db psql -U postgres -d n8n -tAc "select count(*) from credentials_entity where data like '%local-test-only%' or data like '%mock-openai-key%'" | tr -d ' \r')"
all_logs=$(compose logs --no-color app functions kong storage 2>&1)
assert_not_contains "no wrapper logs the owner's e-mail" "$OWNER_EMAIL" "$all_logs"
assert_not_contains "no wrapper logs a password" "local-test-only-owner-password\|LocalTestOnlyN8nOwner1" "$all_logs"
assert_not_contains "nor the webhook secret" "local-test-only-webhook-auth" "$(compose logs --no-color 2>&1)"

section "the web app"
index=$(curl -s --max-time 30 "$APP_URL/" || true)
assert_not_contains "upstream's third-party page script is gone" "gpteng" "$index"
bundle=""
for js in $(grep -oE '/assets/[^"]+\.js' <<<"$index" | sort -u); do bundle+=$(curl -s --max-time 30 "$APP_URL$js" || true); done
assert_not_contains "no build placeholder left" "insightslm-railway-placeholder-" "$bundle"
assert_contains "the browser is pointed at this gateway" "$GATEWAY_URL" "$bundle"
assert_contains "with the anon key minted from JWT_SECRET" "$(anon_key)" "$bundle"
assert_not_contains "and never the service-role key" "$(service_key)" "$bundle"
assert_eq "client-side routes get the app" "200" "$(http_code "$APP_URL/notebook/probe")"
assert_eq "missing assets are real 404s" "404" "$(http_code "$APP_URL/assets/missing.js")"
assert_eq "no path escapes the build" "404" "$(http_code --path-as-is "$APP_URL/assets/../../../etc/passwd")"
assert_contains "pages refuse to be framed" "frame-ancestors 'none'" "$(curl -s -D - -o /dev/null --max-time 30 "$APP_URL/" | tr -d '\r')"

section "the gateway"
assert_eq "no API key, no entry" "401" "$(http_code "$GATEWAY_URL/rest/v1/notebooks")"
assert_eq "the anon key reads no notebooks" "[]" "$(rest_as anon '/rest/v1/notebooks?select=id')"
assert_eq "Realtime's tenant API is blocked" "403" "$(http_code "$GATEWAY_URL/realtime/v1/api/tenants" -H "apikey: $(anon_key)")"
assert_eq "Realtime accepts a websocket" "101" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --http1.1 -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "$GATEWAY_URL/realtime/v1/websocket?apikey=$(anon_key)&vsn=1.0.0" || true)"
for cb in process-document-callback audio-generation-callback; do
  assert_eq "the $cb function is closed at the gateway" "403" "$(http_code -X POST "$GATEWAY_URL/functions/v1/$cb" -H 'Content-Type: application/json' --data '{"source_id":"00000000-0000-0000-0000-000000000000"}')"
done
assert_eq "an unknown function does not exist" "404" "$(http_code -X POST "$GATEWAY_URL/functions/v1/not-a-function" -H 'Content-Type: application/json' --data '{}')"
assert_eq "a user function refuses an anonymous caller" "401" "$(http_code -X POST "$GATEWAY_URL/functions/v1/send-chat-message" -H 'Content-Type: application/json' --data '{}')"
direct=$(compose exec -T app node --input-type=module -e '
  const u = "http://functions:9000/process-document-callback";
  const body = JSON.stringify({ source_id: "00000000-0000-0000-0000-000000000000", status: "failed" });
  const a = await fetch(u, { method: "POST", headers: { "Content-Type": "application/json" }, body });
  const b = await fetch(u, { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + process.env.NOTEBOOK_GENERATION_AUTH }, body });
  console.log(a.status, b.status);' 2>/dev/null | tr -d '\r')
assert_eq "even on the private network, the callbacks require the service-role key" "401 401" "$direct"
assert_eq "n8n is not published" "null" "$(compose config --format json | jq -r '.services.n8n.ports')"

section "who may sign up"
printf '%s' "probe-password-$stamp" > "$TEST_TMP/probe-pw"
assert_eq "a stranger's signup is refused" "500" "$(sign_up "stranger-$stamp@example.com" "$TEST_TMP/probe-pw")"
assert_eq "so is one with a forged bootstrap nonce" "500" \
  "$(sign_up "forger-$stamp@example.com" "$TEST_TMP/probe-pw" "{\"insightslm_railway_bootstrap_nonce\":\"$(printf '0%.0s' $(seq 1 64))\"}")"
assert_eq "an allowlisted address may sign up" "200" "$(sign_up friend@example.com "$TEST_TMP/probe-pw")"

section "a notebook with a PDF source"
sign_in "$OWNER_EMAIL" "$TEST_TMP/owner-pw" "$TEST_TMP/owner" && pass "the owner signs in" || die "owner sign-in failed"
owner_id=$(token_sub "$TEST_TMP/owner")
assert_eq "the owner has a profile" "1" "$(rest_as "$TEST_TMP/owner" "/rest/v1/profiles?select=id&id=eq.$owner_id" | jq length)"
NB=$(rest_as "$TEST_TMP/owner" /rest/v1/notebooks -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"title\":\"Untitled notebook\",\"user_id\":\"$owner_id\",\"generation_status\":\"pending\"}" | jq -r '.[0].id // empty')
[ -n "$NB" ] && pass "the owner creates a notebook" || die "could not create a notebook"
SRC=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"notebook_id\":\"$NB\",\"title\":\"probe.pdf\",\"type\":\"pdf\",\"processing_status\":\"uploading\",\"metadata\":{}}" | jq -r '.[0].id // empty')
python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/probe.pdf" "InsightsLM railway probe document $stamp" "second page"
assert_eq "uploads the PDF to its notebook's folder" "200" "$(upload_as "$TEST_TMP/owner" sources "$NB/$SRC.pdf" "$TEST_TMP/probe.pdf" application/pdf)"
rest_as "$TEST_TMP/owner" "/rest/v1/sources?id=eq.$SRC" -X PATCH -H 'Content-Type: application/json' --data "{\"file_path\":\"$NB/$SRC.pdf\",\"processing_status\":\"processing\"}" >/dev/null
assert_contains "process-document starts the workflow" "^200 " "$(fn_as "$TEST_TMP/owner" process-document "{\"sourceId\":\"$SRC\",\"filePath\":\"$NB/$SRC.pdf\",\"sourceType\":\"pdf\"}")"
assert_contains "generate-notebook-content names the notebook" "^200 .*Probe title mock-ai-answer" \
  "$(fn_as "$TEST_TMP/owner" generate-notebook-content "{\"notebookId\":\"$NB\",\"filePath\":\"$NB/$SRC.pdf\",\"sourceType\":\"pdf\"}")"
assert_eq "n8n extracts, summarises and embeds the PDF, then calls back" "completed" "$(wait_sql "select processing_status from sources where id='$SRC'" completed 180 || true)"
assert_contains "the source holds the PDF's text" "railway probe document $stamp" "$(psql_admin "select content from sources where id='$SRC'")"
assert_eq "its chunks are in the vector store" "1" "$(psql_admin "select (count(*) > 0)::int from documents where metadata->>'source_id' = '$SRC' and embedding is not null" | tr -d ' \r')"
assert_eq "the notebook has example questions" "2" "$(psql_admin "select array_length(example_questions, 1) from notebooks where id='$NB'" | tr -d ' \r')"

section "chat, notes, more sources, audio"
assert_contains "send-chat-message reaches the chat workflow" "^200 " "$(fn_as "$TEST_TMP/owner" send-chat-message "{\"session_id\":\"$NB\",\"message\":\"What does the probe say?\"}")"
assert_eq "the question and the answer are stored for the chat view" "2" "$(wait_sql "select count(*) from n8n_chat_histories where session_id='$NB'" 2 120 || true)"
assert_contains "the answer is the model's, with citations for the UI" "mock-ai-answer" "$(psql_admin "select message->>'content' from n8n_chat_histories where session_id='$NB' and message->>'type' = 'ai'")"
assert_contains "the owner reads the chat through REST" "mock-ai-answer" "$(rest_as "$TEST_TMP/owner" "/rest/v1/n8n_chat_histories?select=message&session_id=eq.$NB")"
assert_contains "generate-note-title titles a note" '^200 {"title"' "$(fn_as "$TEST_TMP/owner" generate-note-title '{"content":"Notes about the railway probe"}')"
TXT=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"notebook_id\":\"$NB\",\"title\":\"Pasted\",\"type\":\"text\",\"content\":\"Pasted probe text\",\"processing_status\":\"processing\",\"metadata\":{}}" | jq -r '.[0].id')
fn_as "$TEST_TMP/owner" process-additional-sources "{\"type\":\"copied-text\",\"notebookId\":\"$NB\",\"title\":\"Pasted\",\"content\":\"Pasted probe text\",\"sourceIds\":[\"$TXT\"],\"timestamp\":\"$stamp\"}" >/dev/null
assert_eq "pasted text is processed" "completed" "$(wait_sql "select processing_status from sources where id='$TXT'" completed 120 || true)"
WEB=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"notebook_id\":\"$NB\",\"title\":\"https://example.org/probe\",\"type\":\"website\",\"url\":\"https://example.org/probe\",\"processing_status\":\"processing\",\"metadata\":{}}" | jq -r '.[0].id')
fn_as "$TEST_TMP/owner" process-additional-sources "{\"type\":\"multiple-websites\",\"notebookId\":\"$NB\",\"urls\":[\"https://example.org/probe\"],\"sourceIds\":[\"$WEB\"],\"timestamp\":\"$stamp\"}" >/dev/null
assert_eq "a website is fetched through the reader and processed" "completed" "$(wait_sql "select processing_status from sources where id='$WEB'" completed 120 || true)"
assert_contains "generate-audio-overview starts the podcast" "^200 " "$(fn_as "$TEST_TMP/owner" generate-audio-overview "{\"notebookId\":\"$NB\"}")"
assert_eq "the audio overview completes without ffmpeg" "completed" "$(wait_sql "select audio_overview_generation_status from notebooks where id='$NB'" completed 180 || true)"
audio=$(psql_admin "select audio_overview_url from notebooks where id='$NB'" | tr -d '\r')
assert_contains "its link is on the public gateway" "^$GATEWAY_URL/storage/v1/" "$audio"
assert_eq "the browser can play it (WAV)" "RIFF" "$(curl -s --max-time 30 "$audio" | head -c 4)"
refresh=$(fn_as "$TEST_TMP/owner" refresh-audio-url "{\"notebookId\":\"$NB\"}")
assert_contains "refresh-audio-url signs a new link" '^200 .*"audioUrl"' "$refresh"

section "accounts are isolated"
sign_in friend@example.com "$TEST_TMP/probe-pw" "$TEST_TMP/friend" && pass "the allowlisted friend signs in" || fail "friend sign-in failed"
assert_eq "they see none of the owner's notebooks" "[]" "$(rest_as "$TEST_TMP/friend" '/rest/v1/notebooks?select=id')"
assert_eq "nor the owner's sources" "[]" "$(rest_as "$TEST_TMP/friend" "/rest/v1/sources?select=id&notebook_id=eq.$NB")"
assert_eq "nor the chat" "[]" "$(rest_as "$TEST_TMP/friend" "/rest/v1/n8n_chat_histories?select=id&session_id=eq.$NB")"
assert_contains "nor the uploaded file" "^4" "$(http_code "$GATEWAY_URL/storage/v1/object/sources/$NB/$SRC.pdf" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/friend")")"
assert_contains "and cannot refresh the owner's audio link" "^[45]" "$(fn_as "$TEST_TMP/friend" refresh-audio-url "{\"notebookId\":\"$NB\"}")"
friend_id=$(token_sub "$TEST_TMP/friend")
assert_contains "nor create a notebook in the owner's name" "^4" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -X POST "$GATEWAY_URL/rest/v1/notebooks" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/friend")" -H 'Content-Type: application/json' --data "{\"title\":\"x\",\"user_id\":\"$owner_id\"}" || true)"
[ -n "$friend_id" ] && pass "the friend is a separate account"

summary
