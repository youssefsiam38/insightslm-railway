# InsightsLM on Railway

A community Railway template for [InsightsLM][upstream], the open-source alternative to NotebookLM: create a
notebook, add PDFs, pasted text and websites, chat with them with cited answers, take notes, and generate a
two-host audio overview. It is not affiliated with the InsightsLM or n8n projects.

InsightsLM's guide has you create a Supabase Cloud project, run its migration in the dashboard, deploy its edge
functions with the Supabase CLI, set up n8n with ffmpeg, import six workflows and wire their credentials node by
node, and host the web app. This template runs **all of it on Railway, in one project**: a self-hosted Supabase
(Postgres with pgvector, Auth, REST, Realtime, Storage, Edge Functions and the Kong gateway), n8n, and the web
app, set up and wired at the first start. You bring an OpenAI key (and a Gemini key for audio overviews).

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/insightslm)

## What you get

- **Nine services wired over Railway's private network**, every secret generated at deploy time. Two are
  public: the web app, and the Supabase gateway the browser talks to.
- **n8n wired for you.** The app's start-up claims n8n's owner account, creates the credentials from your
  variables, and creates and publishes InsightsLM's six workflows through n8n's API. n8n runs its official
  image, unmodified, with no public domain.
- **Audio overviews without ffmpeg.** Upstream converts the text-to-speech audio with ffmpeg through n8n's
  Execute Command node; here a code step wraps it as WAV, so neither ffmpeg nor command execution is needed.
- **The database set up for you**: InsightsLM's migration applied once, the storage buckets and policies with
  it, and an owner account created from the e-mail you enter.
- **Signup closed by default, enforced in the database.** InsightsLM has no sign-up page, but Supabase Auth
  accepts signups posted to it directly; here only the owner and the addresses or domains you list get in.
- **Two upstream holes closed**: the document and audio callbacks, which upstream deploys without any check,
  are unreachable from the internet and require the service-role key.
- Edge functions bundled at build time (nothing is fetched from esm.sh or deno.land at run time), a
  third-party script removed from the page, and the whole bundle tested in CI with a stand-in model
  provider: a PDF processed into the vector store, pasted text and a website, a chat, a note title and an
  audio overview.

## First run

1. Deploy the template. Enter `OWNER_EMAIL`, and on the `app` service set `OPENAI_API_KEY` (and
   `GEMINI_API_KEY` for audio overviews), in the form or afterwards followed by a redeploy of `app`.
2. Wait for `app` to go green. The first start sets up the database and n8n; allow a few minutes.
3. Copy `OWNER_PASSWORD` from the `app` service's **Variables** tab and sign in on the app's domain.
4. Create a notebook and add a source. Processing runs in n8n; the source turns ready when it is done.
5. To give colleagues their own accounts, list their addresses or `@yourcompany.com` in
   `INSIGHTSLM_ALLOWED_SIGNUPS` on `app` and redeploy it. InsightsLM has no sign-up page, so each colleague
   creates their account once with Supabase Auth's sign-up endpoint (the anon key is in the web app's
   JavaScript, as on any Supabase site):
   ```bash
   curl -X POST https://KONG-DOMAIN/auth/v1/signup -H "apikey: ANON-KEY" \
     -H 'Content-Type: application/json' --data '{"email":"colleague@yourcompany.com","password":"..."}'
   ```
   and then signs in on the app.

## Services

| Service | What it is | Image | Public | Volume |
|---|---|---|---|---|
| `app` | InsightsLM web app and start-up | `ghcr.io/youssefsiam38/insightslm-railway-app` | yes | |
| `kong` | Supabase API gateway | `ghcr.io/youssefsiam38/insightslm-railway-kong` | yes | |
| `functions` | Supabase Edge Functions (InsightsLM's nine) | `ghcr.io/youssefsiam38/insightslm-railway-functions` | | |
| `n8n` | n8n, InsightsLM's workflows | `n8nio/n8n` (official) | | |
| `auth` | Supabase Auth (GoTrue) | `supabase/gotrue` | | |
| `rest` | PostgREST | `postgrest/postgrest` | | |
| `realtime` | Supabase Realtime | `supabase/realtime` | | |
| `storage` | Supabase Storage | `ghcr.io/youssefsiam38/insightslm-railway-storage` | | `/var/lib/storage` |
| `db` | Supabase Postgres (also n8n's database) | `ghcr.io/youssefsiam38/insightslm-railway-db` | | `/var/lib/postgresql/data` |

See `ARCHITECTURE.md` for how the pieces fit together.

## Variables you may want to change

On the `app` service unless noted. The model settings are pushed into n8n's credentials when `app` starts:
after changing one, redeploy `app` (and `functions` for `OPENAI_*`).

| Variable | Default | Meaning |
|---|---|---|
| `OWNER_EMAIL` | asked at deploy | The owner account's e-mail; also n8n's owner. |
| `OWNER_PASSWORD` | generated | The owner's first password. Read on the first start only. |
| `OPENAI_API_KEY` | unset | Required for sources, chat, notebook details and note titles. |
| `GEMINI_API_KEY` | unset | Required for audio overviews. |
| `OPENAI_BASE_URL` | `https://api.openai.com/v1` | An OpenAI-compatible endpoint instead. |
| `GEMINI_BASE_URL`, `READER_BASE_URL` | Google's API, `https://r.jina.ai` | Where text-to-speech and web-page reading go. |
| `INSIGHTSLM_ALLOWED_SIGNUPS` | unset | Comma-separated addresses and `@domain` entries that may have accounts. |
| `INSIGHTSLM_SIGNUP_MODE` | `closed` | `open` lets anyone sign up. |
| `INSIGHTSLM_RESET_OWNER_PASSWORD` | unset | Set `true` with a new `OWNER_PASSWORD` to recover the owner; remove afterwards. |
| `INSIGHTSLM_MANAGE_WORKFLOWS` | `true` | `false` stops the start-up from rewriting n8n's workflows and credentials, e.g. after you customise them. |
| `N8N_OWNER_PASSWORD` | generated | n8n's owner password; needed only if you give `n8n` a domain. |
| `GOTRUE_SMTP_*` (`auth`) | unset | SMTP for password-reset e-mails. |

## Persistent data

| Service | Path | Holds | If lost |
|---|---|---|---|
| `db` | `/var/lib/postgresql/data` | Accounts, notebooks, sources' text, notes, chats, embeddings, n8n's workflows, credentials and executions | Everything |
| `storage` | `/var/lib/storage` | Uploaded files and generated audio | Original files and audio |

## Before you rely on it

- **Third-party services see your documents.** OpenAI receives source text for summaries, embeddings and
  chat; Google receives the podcast script; websites are fetched through Jina's reader (`r.jina.ai`) unless
  you set `READER_BASE_URL`.
- **YouTube and audio sources** are processed as upstream processes them; they were not part of this
  template's tests.
- **Audio overviews are WAV**, not MP3: about 3 MB per minute.
- **n8n** is under the Sustainable Use License (see `THIRD_PARTY_NOTICES.md`); this template runs n8n's own
  image for your internal use.
- **Licence.** InsightsLM is MIT.

## Local development

```bash
docker compose build
tests/static.sh
tests/smoke.sh
tests/persistence.sh
```

The compose file mirrors the Railway services one-to-one with fixed, public, local-test-only secrets, plus a
test-only stand-in for OpenAI, Gemini and Jina (`tests/mock-ai.py`). The app is served on
`http://localhost:13600` and the gateway on `http://kong.localhost:18600`; move them with
`INSIGHTSLM_TEST_PORT` and `INSIGHTSLM_TEST_GATEWAY_PORT`.

After deploying:

```bash
OWNER_EMAIL=you@example.com OWNER_PASSWORD_FILE=./owner-password INSIGHTSLM_SMOKE_AI=1 \
  tests/railway-smoke.sh https://<app-domain> https://<kong-domain>
```

## Documents

| File | Contents |
|---|---|
| `ARCHITECTURE.md` | Service graph, start-up, n8n provisioning, the functions, the signup gate |
| `SECURITY.md` | Threat model, what is exposed, residual risks |
| `RAILWAY_TEMPLATE.md` | The exact template configuration |
| `UPSTREAM.md` | Pinned versions, digests, and what this repository changes |
| `MAINTENANCE.md` | Release process, bumping upstream, rollback |
| `MARKETPLACE_AUDIT.md` | Why this template exists |
| `THIRD_PARTY_NOTICES.md` | Licences |

## Licence

MIT for this repository's own files. InsightsLM is MIT; the Supabase components are MIT, Apache-2.0 and the
PostgreSQL licence; n8n is under the Sustainable Use License. See `THIRD_PARTY_NOTICES.md`.

[upstream]: https://github.com/theaiautomators/insights-lm-public
