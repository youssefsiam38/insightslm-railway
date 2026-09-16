#!/bin/sh
# insightslm-railway functions entrypoint: validate, then serve the prebuilt edge functions. Values are never printed.
set -u
log()  { printf '[insightslm-functions] %s\n' "$*"; }
fail() { printf '[insightslm-functions] FATAL: %s\n' "$*" >&2; exit 1; }

for name in JWT_SECRET SUPABASE_URL NOTEBOOK_GENERATION_AUTH NOTEBOOK_CHAT_URL NOTEBOOK_GENERATION_URL \
            DOCUMENT_PROCESSING_WEBHOOK_URL ADDITIONAL_SOURCES_WEBHOOK_URL AUDIO_GENERATION_WEBHOOK_URL; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  [ -n "$v" ] || fail "missing required variable: $name"
done
[ "${#JWT_SECRET}" -ge 32 ] || fail "JWT_SECRET must be at least 32 characters"
# The n8n webhooks check this header; a short value is guessable.
[ "${#NOTEBOOK_GENERATION_AUTH}" -ge 32 ] || fail "NOTEBOOK_GENERATION_AUTH must be at least 32 characters"
for name in SUPABASE_URL NOTEBOOK_CHAT_URL NOTEBOOK_GENERATION_URL DOCUMENT_PROCESSING_WEBHOOK_URL ADDITIONAL_SOURCES_WEBHOOK_URL AUDIO_GENERATION_WEBHOOK_URL; do
  eval "v=\${$name:-}"
  case "$v" in
    *://|*://:*|*://.*|*:///*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done

# The Supabase API keys upstream's functions read are minted from JWT_SECRET by the main service (main/index.ts).

: "${PORT:=9000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
[ -n "${OPENAI_API_KEY:-}" ] || log "OPENAI_API_KEY is not set: generated note titles are unavailable until it is"
set -- /opt/insightslm/functions/*.eszip
log "serving $# edge functions on [::]:${PORT}"
exec edge-runtime start --main-service /opt/insightslm/main --ip :: --port "$PORT"
