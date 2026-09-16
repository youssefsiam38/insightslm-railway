#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2016  # single-quoted literals are matched, not expanded
# Static validation: syntax, shellcheck, compose, image pins, key minting, the patches and the security defaults.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd); export REPO_ROOT
cd "$REPO_ROOT"
# shellcheck source=tests/lib.sh
. "$REPO_ROOT/tests/lib.sh"

section "syntax"
for f in images/*/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in lib/*.mjs images/*/*.mjs; do
  if node --check "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
for f in tests/*.py; do
  if python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$f" 2>/dev/null; then pass "parses: $f"; else fail "syntax error: $f"; fi
done
if perl -c images/kong/mint-keys.pl >/dev/null 2>&1; then pass "parses: images/kong/mint-keys.pl"; else fail "syntax error: images/kong/mint-keys.pl"; fi

section "shellcheck"
if command -v shellcheck >/dev/null; then
  if shellcheck images/*/*.sh; then pass "shellcheck images"; else fail "shellcheck images"; fi
  if shellcheck -x -s bash tests/*.sh; then pass "shellcheck tests"; else fail "shellcheck tests"; fi
else
  echo "  SKIP  shellcheck not installed"
fi

section "compose"
if docker compose -f compose.yaml config -q; then pass "compose config"; else fail "compose config"; fi
cfg=$(docker compose -f compose.yaml config --format json)
assert_eq "nine services plus the test-only model stand-in" "app auth db functions kong mock-ai n8n realtime rest storage" \
  "$(jq -r '[.services | keys[]] | sort | join(" ")' <<<"$cfg")"
assert_eq "only the app and the gateway publish ports" "app kong" "$(jq -r '[.services | to_entries[] | select(.value.ports) | .key] | sort | join(" ")' <<<"$cfg")"
assert_eq "published ports bind to loopback" "127.0.0.1 127.0.0.1" "$(jq -r '[.services[] | .ports[]? | .host_ip] | join(" ")' <<<"$cfg")"
assert_eq "the test network has IPv6, like Railway's" "true" "$(jq -r '.networks.default.enable_ipv6' <<<"$cfg")"
assert_contains "n8n is the official image, pinned" "^docker.io/n8nio/n8n:[0-9.]*@sha256:[0-9a-f]\{64\}$" "$(jq -r '.services.n8n.image' <<<"$cfg")"
assert_eq "n8n has no build of ours" "null" "$(jq -r '.services.n8n.build' <<<"$cfg")"
for svc in auth rest realtime mock-ai; do
  img=$(jq -r --arg s "$svc" '.services[$s].image' <<<"$cfg")
  [[ "$img" == *:*@sha256:* ]] && pass "$svc pinned by tag and digest" || fail "$svc image not pinned: $img"
done
fn_env=$(jq -c '.services.functions.environment' <<<"$cfg")
for hook in NOTEBOOK_CHAT_URL NOTEBOOK_GENERATION_URL AUDIO_GENERATION_WEBHOOK_URL ADDITIONAL_SOURCES_WEBHOOK_URL DOCUMENT_PROCESSING_WEBHOOK_URL; do
  assert_contains "$hook points at an n8n webhook on the private network" '^http://n8n:5678/webhook/[0-9a-f-]\{36\}$' "$(jq -r --arg h "$hook" '.[$h]' <<<"$fn_env")"
done

section "images are pinned"
for df in images/*/Dockerfile; do
  base=$(grep -E '^ARG [A-Z_]+_IMAGE=' "$df")
  [ -n "$base" ] || { fail "$df has no pinned base image argument"; continue; }
  if grep -vqE '@sha256:[0-9a-f]{64}$' <<<"$base"; then fail "$df base image lacks a digest"; else pass "$df base pinned by digest"; fi
done
commits=$(grep -h '^ARG INSIGHTSLM_COMMIT=' images/*/Dockerfile | sort -u)
assert_eq "app and functions build the same upstream commit" "1" "$(wc -l <<<"$commits" | tr -d ' ')"
assert_contains "an exact commit" '^ARG INSIGHTSLM_COMMIT=[0-9a-f]\{40\}$' "$commits"
for img in app functions; do
  assert_contains "$img verifies the fetched commit" 'test "$(git -C /src rev-parse HEAD)" = "${INSIGHTSLM_COMMIT}"' "$(cat "images/$img/Dockerfile")"
done
app_df=$(cat images/app/Dockerfile)
assert_contains "the app build checks upstream's package.json is the one the fixes came from" '${UPSTREAM_PACKAGE_JSON_SHA256}  /src/package.json" | sha256sum -c -' "$app_df"
assert_contains "and its lockfile" '${UPSTREAM_PACKAGE_LOCK_SHA256}  /src/package-lock.json" | sha256sum -c -' "$app_df"
assert_contains "the app installs from the lockfile" 'npm ci --no-audit --no-fund' "$app_df"
assert_contains "the third-party page script is removed, and the build checks it was there once" "test \"\$(grep -c 'cdn.gpteng.co/gptengineer.js' /src/index.html)\" = 1" "$app_df"
assert_contains "the runtime database client is locked" '"pg": "[0-9]' "$(cat images/app/runtime/package.json)"
for v in JWT_SECRET POSTGRES_PASSWORD OWNER_PASSWORD N8N_OWNER_PASSWORD NOTEBOOK_GENERATION_AUTH OPENAI_API_KEY GEMINI_API_KEY; do
  if grep -qE "^\s+$v=|^ENV $v=|ARG $v" images/*/Dockerfile; then fail "$v is baked into an image"; else pass "no $v in any image"; fi
done

section "the key minters agree"
secret=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
node_out=$(JWT_SECRET="$secret" node lib/mint-supabase-keys.mjs)
perl_out=$(JWT_SECRET="$secret" perl images/kong/mint-keys.pl)
assert_eq "node and perl minters produce identical keys" "$(sha256sum <<<"$node_out" | cut -c1-16)" "$(sha256sum <<<"$perl_out" | cut -c1-16)"
for f in images/app/setup.mjs images/app/provision-n8n.mjs images/functions/main/index.ts; do
  assert_contains "$f mints with the same fixed claims" '"iss":"supabase","iat":1735689600,"exp":2082758400' "$(cat "$f")"
done

section "who gets in"
gate=$(cat images/app/gate.sql)
assert_contains "the gate is a BEFORE INSERT trigger on auth.users" 'before insert on auth.users' "$gate"
assert_contains "the owner nonce is single-use" "delete from insightslm_railway.settings" "$gate"
assert_contains "the allowlist matches whole addresses or whole domains" "entry = v_email or entry = '@' || split_part(v_email, '@', 2)" "$gate"
setup=$(cat images/app/setup.mjs)
assert_contains "signup defaults to closed" 'env("INSIGHTSLM_SIGNUP_MODE", "closed")' "$setup"
assert_contains "the owner claim is the owner's own address" 'select id::text from auth.users where lower(email) = $1' "$setup"
assert_contains "the migration is recorded with a checksum" 'insert into insightslm_railway.migrations (name, sha256)' "$setup"
ep=$(cat images/app/entrypoint.sh)
setup_line=$(grep -n 'setup.mjs' images/app/entrypoint.sh | head -1 | cut -d: -f1)
serve_line=$(grep -n 'exec node /opt/insightslm/serve.mjs' images/app/entrypoint.sh | cut -d: -f1)
[ "$setup_line" -lt "$serve_line" ] && pass "set-up finishes before the app serves" || fail "the app serves before set-up"
assert_contains "the web server drops the start-up's secrets" 'unset JWT_SECRET SUPABASE_DB_URL OWNER_PASSWORD N8N_OWNER_PASSWORD' "$ep"

section "the functions"
main=$(cat images/functions/main/index.ts)
assert_contains "only bundled functions are served" 'if (!available.has(name)) return json(404' "$main"
assert_contains "the callbacks require the service-role key" 'CALLBACKS.has(name) && req.method !== "OPTIONS" && !(await isServiceRole(req))' "$main"
assert_contains "the token signature is checked, not just decoded" 'crypto.subtle.verify("HMAC"' "$main"
patch=$(cat images/functions/patch-functions.mjs)
assert_contains "the patch refuses an unexpected function list" 'unexpected function list' "$patch"
assert_contains "supabase-js is pinned to one release" 'const SUPABASE_JS = "2\.' "$patch"
assert_contains "every function is bundled at build time" 'edge-runtime bundle --entrypoint' "$(cat images/functions/Dockerfile)"

section "the gateway"
kong_yml=$(grep -v '^#' images/kong/kong.yml)
assert_contains "the callbacks are closed publicly" '"/functions/v1/process-document-callback", "/functions/v1/audio-generation-callback"' "$kong_yml"
assert_contains "with a 403" 'status_code: 403' "$kong_yml"
assert_contains "Kong admin API off" 'KONG_ADMIN_LISTEN=off' "$(cat images/kong/entrypoint.sh)"
assert_contains "Kong access log off" 'KONG_PROXY_ACCESS_LOG=off' "$(cat images/kong/Dockerfile)"
for route in pg-meta analytics studio; do assert_not_contains "no $route route" "$route" "$kong_yml"; done
assert_contains "the vault key lives on the data volume" '/var/lib/postgresql/data/pgsodium_root.key' "$(cat images/db/getkey.sh)"

section "n8n provisioning"
prov=$(cat images/app/provision-n8n.mjs)
assert_contains "an unrewritten upstream Supabase address stops provisioning" "an address of upstream's own Supabase project was not rewritten" "$prov"
assert_contains "the audio overview does not need ffmpeg" 'PCM_TO_WAV' "$prov"
assert_contains "the Execute Command nodes are removed" '"Execute Command"' "$prov"
assert_contains "workflows keep upstream's ids" 'id: wf.id' "$prov"
assert_contains "a missing credential stops provisioning" "which this template does not provide" "$prov"

section "log streams"
for f in images/*/entrypoint.sh; do
  if grep -q '^log()' "$f"; then
    if ! grep '^log()' "$f" | grep -q '>&2'; then pass "routine logs go to stdout: $f"; else fail "log() writes to stderr: $f"; fi
  fi
  if grep '^fail()' "$f" | grep -q '>&2'; then pass "failures go to stderr: $f"; else fail "fail() does not write to stderr: $f"; fi
done

section "workflows"
for wf in .github/workflows/*.yml; do
  if grep -qE 'uses: .*@[0-9a-f]{40}' "$wf" && ! grep -qE 'uses: [^#]*@v[0-9]+\s*$' "$wf"; then
    pass "actions pinned by SHA in $wf"
  else
    fail "unpinned action in $wf"
  fi
done
for c in db kong storage functions app; do
  var="INSIGHTSLM_RAILWAY_$(tr '[:lower:]' '[:upper:]' <<<"$c")_IMAGE"
  assert_contains "compose lets CI override the $c image" "$var" "$(cat compose.yaml)"
  assert_contains "the publish workflow tests the $c candidate" "$var" "$(cat .github/workflows/publish-image.yml)"
done

section "no tracked secrets"
if git rev-parse --git-dir >/dev/null 2>&1; then
  if git grep -nIE '(BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{20,}|github_pat_|xox[baprs]-|sk-[A-Za-z0-9]{32,}|eyJhbGciOi)' -- . ':!tests/static.sh' ':!images/app/deps/package-lock.json' ':!images/app/runtime/package-lock.json' >/dev/null 2>&1; then
    fail "credential pattern in tracked files"
  else
    pass "no credential patterns in tracked files"
  fi
else
  echo "  SKIP  not a git checkout"
fi
summary
