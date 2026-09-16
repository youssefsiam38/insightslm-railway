# Railway template configuration

The template's exact configuration. Reproduce it from this file if it ever has to be rebuilt.

| | |
|---|---|
| Name | InsightsLM |
| Code | `insightslm` |
| Template id | `6c8a1401-56f1-4a02-968c-bca9dd3bd37a` |
| Deploy URL | https://railway.com/deploy/insightslm |
| Category | AI/ML |
| Card description | Open-source NotebookLM: chat with sources, audio overviews; Supabase + n8n |
| Icon | `assets/icon.png` |
| Overview markdown | `marketplace/OVERVIEW.md` (Railway enforces its section headings) |

Generated values use Railway's `secret()` function: `hexN` is `${{secret(N, "abcdef0123456789")}}` and `alnumN` is
`${{secret(N, "a-zA-Z0-9")}}` spelled out. Alphanumeric passwords are used wherever a value is embedded in a
connection URL, so nothing needs percent-encoding. Images are referenced by tag, because the template generator
rejects digests; `UPSTREAM.md` records the digests.

## Services

### `db`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/insightslm-railway-db:1.0.0` |
| Public domain | none |
| Volume | `/var/lib/postgresql/data` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `POSTGRES_PASSWORD` | generated, alnum48 |

### `auth`

| Field | Value |
|---|---|
| Source | `supabase/gotrue:v2.197.0` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `JWT_SECRET` | generated, hex64 |
| `PORT` | `9999` |
| `GOTRUE_API_HOST` | `::` |
| `GOTRUE_API_PORT` | `9999` |
| `API_EXTERNAL_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `GOTRUE_DB_DRIVER` | `postgres` |
| `GOTRUE_DB_DATABASE_URL` | `postgres://supabase_auth_admin:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `GOTRUE_SITE_URL` | `https://${{app.RAILWAY_PUBLIC_DOMAIN}}` |
| `GOTRUE_URI_ALLOW_LIST` | `https://${{app.RAILWAY_PUBLIC_DOMAIN}}/**` |
| `GOTRUE_DISABLE_SIGNUP` | `false` |
| `GOTRUE_JWT_ADMIN_ROLES` | `service_role` |
| `GOTRUE_JWT_AUD` | `authenticated` |
| `GOTRUE_JWT_DEFAULT_GROUP_NAME` | `authenticated` |
| `GOTRUE_JWT_EXP` | `3600` |
| `GOTRUE_JWT_SECRET` | `${{JWT_SECRET}}` |
| `GOTRUE_EXTERNAL_EMAIL_ENABLED` | `true` |
| `GOTRUE_EXTERNAL_ANONYMOUS_USERS_ENABLED` | `false` |
| `GOTRUE_EXTERNAL_PHONE_ENABLED` | `false` |
| `GOTRUE_MAILER_AUTOCONFIRM` | `true` |
| `GOTRUE_PASSWORD_MIN_LENGTH` | `10` |
| `GOTRUE_SMTP_HOST` | optional, unset |
| `GOTRUE_SMTP_PORT` | optional, unset |
| `GOTRUE_SMTP_USER` | optional, unset |
| `GOTRUE_SMTP_PASS` | optional, unset |
| `GOTRUE_SMTP_ADMIN_EMAIL` | optional, unset |

### `rest`

| Field | Value |
|---|---|
| Source | `postgrest/postgrest:v14.17` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PGRST_DB_URI` | `postgres://authenticator:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `PGRST_DB_SCHEMAS` | `public,storage,graphql_public` |
| `PGRST_DB_MAX_ROWS` | `1000` |
| `PGRST_DB_EXTRA_SEARCH_PATH` | `public` |
| `PGRST_DB_ANON_ROLE` | `anon` |
| `PGRST_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `PGRST_DB_USE_LEGACY_GUCS` | `false` |
| `PGRST_APP_SETTINGS_JWT_EXP` | `3600` |
| `PGRST_SERVER_HOST` | `*6` |
| `PGRST_SERVER_PORT` | `3000` |

### `realtime`

| Field | Value |
|---|---|
| Source | `supabase/realtime:v2.134.10` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `4000` |
| `DB_HOST` | `${{db.RAILWAY_PRIVATE_DOMAIN}}` |
| `DB_PORT` | `5432` |
| `DB_USER` | `supabase_admin` |
| `DB_PASSWORD` | `${{db.POSTGRES_PASSWORD}}` |
| `DB_NAME` | `postgres` |
| `DB_AFTER_CONNECT_QUERY` | `SET search_path TO _realtime` |
| `DB_ENC_KEY` | generated, alnum16 |
| `API_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `METRICS_JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `SECRET_KEY_BASE` | generated, alnum64 |
| `ERL_AFLAGS` | `-proto_dist inet_tcp` |
| `DNS_NODES` | `''` |
| `RLIMIT_NOFILE` | `10000` |
| `APP_NAME` | `realtime` |
| `SEED_SELF_HOST` | `true` |
| `SELF_HOST_TENANT_NAME` | `realtime` |
| `RUN_JANITOR` | `true` |
| `DISABLE_HEALTHCHECK_LOGGING` | `true` |

### `storage`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/insightslm-railway-storage:1.0.0` |
| Public domain | none |
| Volume | `/var/lib/storage` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `5000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `DATABASE_URL` | `postgres://supabase_storage_admin:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `POSTGREST_URL` | `http://${{rest.RAILWAY_PRIVATE_DOMAIN}}:3000` |
| `STORAGE_PUBLIC_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |

### `functions`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/insightslm-railway-functions:1.0.0` |
| Public domain | none |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `9000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `SUPABASE_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `NOTEBOOK_GENERATION_AUTH` | generated, hex64 |
| `NOTEBOOK_CHAT_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678/webhook/2fabf43f-6e6e-424b-8e93-9150e9ce7d6c` |
| `NOTEBOOK_GENERATION_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678/webhook/0c488f50-8d6a-48a0-b056-5f7cfca9efe2` |
| `AUDIO_GENERATION_WEBHOOK_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678/webhook/4c4699bc-004b-4ca3-8923-373ddd4a274e` |
| `ADDITIONAL_SOURCES_WEBHOOK_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678/webhook/670882ea-5c1e-4b50-9f41-4792256af985` |
| `DOCUMENT_PROCESSING_WEBHOOK_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678/webhook/19566c6c-e0a5-4a8f-ba1a-5203c2b663b7` |
| `OPENAI_API_KEY` | `${{app.OPENAI_API_KEY}}` |
| `OPENAI_BASE_URL` | `${{app.OPENAI_BASE_URL}}` |

### `kong`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/insightslm-railway-kong:1.0.0` |
| Public domain | target port 8000 |
| Volume | none |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `8000` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `AUTH_HOST` | `${{auth.RAILWAY_PRIVATE_DOMAIN}}` |
| `REST_HOST` | `${{rest.RAILWAY_PRIVATE_DOMAIN}}` |
| `REALTIME_HOST` | `${{realtime.RAILWAY_PRIVATE_DOMAIN}}` |
| `STORAGE_HOST` | `${{storage.RAILWAY_PRIVATE_DOMAIN}}` |
| `FUNCTIONS_HOST` | `${{functions.RAILWAY_PRIVATE_DOMAIN}}` |

### `n8n`

| Field | Value |
|---|---|
| Source | `n8nio/n8n:2.39.6` |
| Public domain | none |
| Volume | none |
| Healthcheck | `/healthz/readiness`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `5678` |
| `N8N_PORT` | `5678` |
| `N8N_LISTEN_ADDRESS` | `::` |
| `DB_TYPE` | `postgresdb` |
| `DB_POSTGRESDB_HOST` | `${{db.RAILWAY_PRIVATE_DOMAIN}}` |
| `DB_POSTGRESDB_PORT` | `5432` |
| `DB_POSTGRESDB_DATABASE` | `n8n` |
| `DB_POSTGRESDB_USER` | `postgres` |
| `DB_POSTGRESDB_PASSWORD` | `${{db.POSTGRES_PASSWORD}}` |
| `N8N_ENCRYPTION_KEY` | generated, hex64 |
| `N8N_DIAGNOSTICS_ENABLED` | `false` |
| `N8N_VERSION_NOTIFICATIONS_ENABLED` | `false` |
| `N8N_PERSONALIZATION_ENABLED` | `false` |
| `N8N_TEMPLATES_ENABLED` | `false` |
| `N8N_DEFAULT_BINARY_DATA_MODE` | `default` |
| `N8N_RUNNERS_ENABLED` | `true` |
| `N8N_BLOCK_ENV_ACCESS_IN_NODE` | `true` |
| `GENERIC_TIMEZONE` | `UTC` |

### `app`

| Field | Value |
|---|---|
| Source | `ghcr.io/youssefsiam38/insightslm-railway-app:1.0.0` |
| Public domain | target port 3000 |
| Volume | none |
| Healthcheck | `/healthz`, timeout from `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` |
| Restart policy | on failure, 10 retries |

| Variable | Value |
|---|---|
| `PORT` | `3000` |
| `RAILWAY_HEALTHCHECK_TIMEOUT_SEC` | `900` |
| `JWT_SECRET` | `${{auth.JWT_SECRET}}` |
| `SUPABASE_DB_URL` | `postgres://postgres:${{db.POSTGRES_PASSWORD}}@${{db.RAILWAY_PRIVATE_DOMAIN}}:5432/postgres` |
| `SUPABASE_INTERNAL_URL` | `http://${{kong.RAILWAY_PRIVATE_DOMAIN}}:8000` |
| `SUPABASE_PUBLIC_URL` | `https://${{kong.RAILWAY_PUBLIC_DOMAIN}}` |
| `FUNCTIONS_INTERNAL_URL` | `http://${{functions.RAILWAY_PRIVATE_DOMAIN}}:9000` |
| `N8N_INTERNAL_URL` | `http://${{n8n.RAILWAY_PRIVATE_DOMAIN}}:5678` |
| `NOTEBOOK_GENERATION_AUTH` | `${{functions.NOTEBOOK_GENERATION_AUTH}}` |
| `OWNER_EMAIL` | required input, no default |
| `OWNER_PASSWORD` | generated, alnum24 |
| `N8N_OWNER_PASSWORD` | generated, alnum29 followed by `Aa1` |
| `INSIGHTSLM_SIGNUP_MODE` | `closed` |
| `OPENAI_API_KEY` | optional, unset |
| `GEMINI_API_KEY` | optional, unset |
| `OPENAI_BASE_URL` | optional, unset |
| `INSIGHTSLM_ALLOWED_SIGNUPS` | optional, unset |

## Notes

- **Service names are part of the configuration.** Every cross-service reference uses them; `functions` reads
  `OPENAI_API_KEY` and `OPENAI_BASE_URL` from `app` (unset references resolve empty, and the function falls back
  to api.openai.com), and `app` reads `NOTEBOOK_GENERATION_AUTH` from `functions`.
- **The n8n webhook paths in `functions` are upstream's** (from the workflows' webhook nodes); provisioning keeps
  the workflows' ids and paths, so these stay valid across restarts.
- **n8n runs the official `n8nio/n8n` image, unmodified.** It needs `PORT=5678` for Railway's healthcheck
  (`/healthz/readiness`) and has no public domain. `N8N_OWNER_PASSWORD` is generated with a fixed `Aa1` suffix,
  because n8n requires a capital letter and a digit.
- **Two public domains**: `app` and `kong`. `kong` closes `/functions/v1/process-document-callback` and
  `/functions/v1/audio-generation-callback`.
- The template was generated from a skeleton project that was never deployed: the generator keeps only
  reference-valued variables, so every literal and generator was patched in afterwards with
  `templateChangeSetStage` and `templateChangeSetApply`. Volumes, domains and healthchecks were checked after
  patching.
- **`app` has a 900-second healthcheck timeout**: it serves only after the database migration and n8n's
  provisioning.
- After redeploying `db`, PostgREST answers `PGRST002` for a short while and then reconnects by itself.
- Tested on a clean-room deploy of this template (1.0.0) with a temporary stand-in model service:
  `tests/railway-smoke.sh` 41/41 (PDF processing into the vector store, pasted text, a website, chat, note title,
  audio overview, allowlist and isolation), a redeploy of all nine services keeping the owner, a notebook, its
  processed source, the chat, the audio file and working workflows, and 41/41 again afterwards.
