#!/bin/sh
# insightslm-railway app entrypoint:
#   1. validate the variables (names only; values are never printed)
#   2. set up InsightsLM's database, signup gate and owner account (setup.mjs)
#   3. provision InsightsLM's workflows in n8n (provision-n8n.mjs)
#   4. write the public Supabase URL and anon key into the built web app, then serve it
set -u
log()  { printf '[insightslm-app] %s\n' "$*"; }
fail() { printf '[insightslm-app] FATAL: %s\n' "$*" >&2; exit 1; }

for name in JWT_SECRET SUPABASE_DB_URL SUPABASE_INTERNAL_URL SUPABASE_PUBLIC_URL FUNCTIONS_INTERNAL_URL N8N_INTERNAL_URL \
            NOTEBOOK_GENERATION_AUTH OWNER_EMAIL OWNER_PASSWORD N8N_OWNER_PASSWORD; do
  eval "v=\${$name:-}"
  # shellcheck disable=SC2154  # v is assigned by the eval above
  [ -n "$v" ] || fail "missing required variable: $name"
done
[ "${#JWT_SECRET}" -ge 32 ] || fail "JWT_SECRET must be at least 32 characters"
case "$JWT_SECRET" in
  your-super-secret-jwt-token-with-at-least-32-characters-long)
    fail "JWT_SECRET is the value from Supabase's public .env.example. Anyone can sign a service_role token with it." ;;
esac
for name in SUPABASE_DB_URL SUPABASE_INTERNAL_URL SUPABASE_PUBLIC_URL FUNCTIONS_INTERNAL_URL N8N_INTERNAL_URL; do
  eval "v=\${$name:-}"
  case "$v" in
    *://|*://:*|*://.*|*:///*|*@:*|*@/*)
      fail "$name has no host name. On Railway this is a reference to another service's domain that had not resolved when this deployment started; redeploy once that service has deployed." ;;
  esac
done
[ -n "${OPENAI_API_KEY:-}" ] || log "OPENAI_API_KEY is not set: adding sources, chat and notebook generation need it; set it on this service and redeploy"
[ -n "${GEMINI_API_KEY:-}" ] || log "GEMINI_API_KEY is not set: audio overviews need it"

node /opt/insightslm/setup.mjs || exit 1
if [ "${INSIGHTSLM_MANAGE_WORKFLOWS:-true}" = "true" ]; then
  node /opt/insightslm/provision-n8n.mjs || exit 1
else
  log "INSIGHTSLM_MANAGE_WORKFLOWS is not true: leaving n8n's workflows and credentials as they are"
fi

keys=$(node /opt/insightslm/mint-supabase-keys.mjs) || fail "could not mint the Supabase anon key"
VITE_SUPABASE_ANON_KEY=$(printf '%s\n' "$keys" | sed -n 's/^ANON_KEY=//p')
VITE_SUPABASE_URL=${SUPABASE_PUBLIC_URL%/}
unset keys
export VITE_SUPABASE_URL VITE_SUPABASE_ANON_KEY
node /opt/insightslm/fill-public-env.mjs || exit 1

# The web server needs none of the secrets the start-up used.
unset JWT_SECRET SUPABASE_DB_URL OWNER_PASSWORD N8N_OWNER_PASSWORD NOTEBOOK_GENERATION_AUTH OPENAI_API_KEY GEMINI_API_KEY ANTHROPIC_API_KEY
: "${PORT:=3000}"
case "$PORT" in ''|*[!0-9]*) fail "PORT must be a number, got \"$PORT\"" ;; esac
export PORT
exec node /opt/insightslm/serve.mjs
