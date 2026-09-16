#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Persistence: what exists before every container is destroyed is there after they are recreated (volumes kept),
# nothing the first start did is repeated or duplicated, and the workflows still run afterwards.
#   tests/persistence.sh         (starts its own fresh stack; INSIGHTSLM_TEST_KEEP=1 leaves it running)
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"
umask 077

mint_keys local-test-only-jwt-secret-000000000000000000000000000000
OWNER_EMAIL=owner@example.com
stamp=$(date +%s)
printf '%s' local-test-only-owner-password > "$TEST_TMP/initial-pw"
printf '%s' "changed-in-the-app-$stamp" > "$TEST_TMP/changed-pw"

cleanup() {
  [ "${INSIGHTSLM_TEST_KEEP:-0}" = 1 ] || compose down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Containers are recreated, so their logs start empty each time.
started() { wait_for_log app "serving the web app" 1 "$TEST_TIMEOUT" && wait_for_code "$APP_URL/" 200 120; }
n8n_count() { compose exec -T db psql -U postgres -d n8n -tAc "$1" | tr -d ' \r'; }

section "fresh stack"
compose down -v --remove-orphans >/dev/null 2>&1 || true
compose up -d --no-build >/dev/null 2>&1 || die "compose up failed"
started && pass "serving" || die "the stack never became ready"

section "write state"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/owner" && pass "owner signs in with the generated password" || die "owner sign-in failed"
assert_eq "owner changes their password" "200" "$(http_code -X PUT "$GATEWAY_URL/auth/v1/user" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/owner")" \
  -H 'Content-Type: application/json' --data "$(jq -nc --rawfile p "$TEST_TMP/changed-pw" '{password:$p}')")"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/owner" || die "could not sign in with the changed password"
owner_id=$(token_sub "$TEST_TMP/owner")
NB=$(rest_as "$TEST_TMP/owner" /rest/v1/notebooks -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"title\":\"Kept $stamp\",\"user_id\":\"$owner_id\",\"generation_status\":\"completed\"}" | jq -r '.[0].id')
SRC=$(rest_as "$TEST_TMP/owner" /rest/v1/sources -X POST -H 'Content-Type: application/json' -H 'Prefer: return=representation' \
  --data "{\"notebook_id\":\"$NB\",\"title\":\"kept.pdf\",\"type\":\"pdf\",\"processing_status\":\"processing\",\"file_path\":\"$NB/kept.pdf\",\"metadata\":{}}" | jq -r '.[0].id')
python3 "$REPO_ROOT/tests/make-pdf.py" "$TEST_TMP/kept.pdf" "kept-pdf-$stamp"
assert_eq "a PDF is uploaded" "200" "$(upload_as "$TEST_TMP/owner" sources "$NB/kept.pdf" "$TEST_TMP/kept.pdf" application/pdf)"
fn_as "$TEST_TMP/owner" process-document "{\"sourceId\":\"$SRC\",\"filePath\":\"$NB/kept.pdf\",\"sourceType\":\"pdf\"}" >/dev/null
assert_eq "and processed" "completed" "$(wait_sql "select processing_status from sources where id='$SRC'" completed 180 || true)"
fn_as "$TEST_TMP/owner" send-chat-message "{\"session_id\":\"$NB\",\"message\":\"first question\"}" >/dev/null
assert_eq "a chat exchange is stored" "2" "$(wait_sql "select count(*) from n8n_chat_histories where session_id='$NB'" 2 120 || true)"
docs=$(psql_admin "select count(*) from documents where metadata->>'source_id' = '$SRC'" | tr -d ' \r')

section "destroy and recreate every container (volumes kept)"
compose down >/dev/null 2>&1
compose up -d --no-build >/dev/null 2>&1
started && pass "serving again" || die "the stack did not come back"
app_logs=$(compose logs --no-color --no-log-prefix app 2>&1)
assert_contains "the migration is not applied twice" "1 migration, 0 applied now" "$app_logs"
assert_contains "the owner is found, not created again" "owner account exists from an earlier start" "$app_logs"
assert_eq "n8n's owner is not created again" "0" "$(grep -c 'n8n owner created' <<<"$app_logs" || true)"
assert_eq "no duplicate credentials in n8n" "6" "$(n8n_count 'select count(*) from credentials_entity')"
assert_eq "no duplicate workflows in n8n" "6" "$(n8n_count 'select count(*) from workflow_entity')"
assert_eq "all still published" "6" "$(n8n_count 'select count(*) from workflow_entity where "activeVersionId" is not null')"

section "state survived"
sign_in "$OWNER_EMAIL" "$TEST_TMP/changed-pw" "$TEST_TMP/owner2" && pass "the changed password still works" || fail "the changed password was lost"
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/owner3" && fail "the redeploy reset the owner's password" || pass "the redeploy did not reset the owner's password"
assert_eq "the notebook is there" "Kept $stamp" "$(rest_as "$TEST_TMP/owner2" "/rest/v1/notebooks?select=title&id=eq.$NB" | jq -r '.[0].title // empty')"
assert_eq "so are its vector chunks" "$docs" "$(psql_admin "select count(*) from documents where metadata->>'source_id' = '$SRC'" | tr -d ' \r')"
assert_contains "the uploaded file is still in storage" "^200$" "$(http_code "$GATEWAY_URL/storage/v1/object/sources/$NB/kept.pdf" -H "apikey: $(anon_key)" -H "Authorization: Bearer $(cat "$TEST_TMP/owner2")")"
fn_as "$TEST_TMP/owner2" send-chat-message "{\"session_id\":\"$NB\",\"message\":\"second question\"}" >/dev/null
assert_eq "the chat workflow still answers, with the history kept" "4" "$(wait_sql "select count(*) from n8n_chat_histories where session_id='$NB'" 4 120 || true)"

section "owner recovery"
INSIGHTSLM_TEST_RESET_OWNER=true compose up -d --no-build --no-deps app >/dev/null 2>&1
wait_for_log app "owner password reset from OWNER_PASSWORD" 1 300 && pass "INSIGHTSLM_RESET_OWNER_PASSWORD resets the owner" || fail "the reset did not run"
wait_for_log app "serving the web app" 1 300 >/dev/null || true
sign_in "$OWNER_EMAIL" "$TEST_TMP/initial-pw" "$TEST_TMP/owner4" && pass "the owner signs in with OWNER_PASSWORD again" || fail "the reset password does not work"

summary
