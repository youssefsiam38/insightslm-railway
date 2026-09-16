# Architecture

## Service graph

```
 browser ──https──► app (static web app) ─────────────────────────────── served files only
    │
    └─────https──► kong ──private──► auth, rest, realtime, storage ──► db
                     │
                     └──private──► functions ──private──► n8n webhooks ──► OpenAI, Gemini, Jina
                                        ▲                     │
                                        │                     ├──private──► kong (storage, REST as service role)
                                        │                     ├──private──► db (chat memory, vector store)
                                        └────── callbacks ────┘
 app start-up ──private──► db (migration, gate, owner), kong (Auth admin), n8n REST (owner, credentials, workflows)
```

| Service | Listens | Reached by |
|---|---|---|
| `app` | `[::]:3000` | browsers (public) |
| `kong` | `[::]:8000`, `0.0.0.0:8000` | browsers (public); the app's start-up and n8n (private) |
| `functions` | `[::]:9000` | kong, and n8n for the callbacks (private) |
| `n8n` | `[::]:5678` | functions (webhooks) and the app's start-up (REST) (private) |
| `auth`, `rest`, `realtime`, `storage` | private | kong; storage also reaches rest |
| `db` | `*:5432` | every service that stores data; n8n uses its own `n8n` database |

## Start-up of `app`

1. **Database** (`setup.mjs`): waits for Postgres, the gateway and Supabase Auth, and for the `auth` and
   `storage` schemas that Supabase Auth and Storage create on their first start; creates the `n8n` database if
   the cluster predates it; applies InsightsLM's migration once (recorded with its checksum in
   `insightslm_railway.migrations`); installs the signup gate and writes the signup policy; creates the owner
   through Supabase Auth's admin API.
2. **n8n** (`provision-n8n.mjs`): waits for n8n's readiness endpoint, claims n8n's owner account with
   `OWNER_EMAIL` and `N8N_OWNER_PASSWORD` (or signs in as it), then through the REST API n8n's editor uses:
   - creates or updates six credentials from the variables (OpenAI, Gemini, Anthropic, the webhook header,
     Postgres, Supabase service role), remembering the ids n8n assigns in `insightslm_railway.n8n_credentials`;
   - creates or updates the six workflows under upstream's own ids, so sub-workflow references and webhook
     paths stay as upstream wrote them, and publishes each one.
3. Mints the anon key, writes it and the gateway's public URL into the built web app, drops the secrets, and
   serves the app.

### How the workflows are rewritten

Upstream's workflows are exported from its author's own n8n and Supabase project. For each node that calls an
address, provisioning rewrites exactly that node, and stops if an expected address is missing:

| Node | Upstream | Here |
|---|---|---|
| Storage uploads, signed-URL requests, downloads | the author's `*.supabase.co` | the gateway's private address |
| The audio link saved on the notebook | the author's `*.supabase.co` | the gateway's public address |
| The document-processing callback | `.../functions/v1/process-document-callback` | the functions service, privately |
| Text-to-speech | `generativelanguage.googleapis.com` | `GEMINI_BASE_URL` |
| Web-page reading | `r.jina.ai` | `READER_BASE_URL` |

The audio pipeline is restructured: upstream checks for ffmpeg, writes Gemini's PCM to disk, converts it to MP3
with the Execute Command node, and reads the file back. Here one Code node wraps the PCM (24 kHz, 16-bit, mono)
in a WAV header, and the ffmpeg check and its error branch are gone.

Workflows and credentials are rewritten on every start while `INSIGHTSLM_MANAGE_WORKFLOWS` is `true`.

## Edge functions

The `functions` image bundles InsightsLM's nine functions into eszip files at build time, with supabase-js
pinned to one release. Its main service routes `/<function>` to its bundle, mints the Supabase API keys from
`JWT_SECRET` and hands them to the function, and requires a valid service-role token for the two callbacks.
The user-facing functions check the caller's Supabase session themselves, as upstream wrote them.

`SUPABASE_URL` for the functions is the gateway's public address, because `refresh-audio-url` stores the signed
link it creates and browsers play it.

## The signup gate

A `BEFORE INSERT` trigger on `auth.users` admits a new user when its metadata carries the one-time bootstrap
nonce (the owner), when the signup mode is `open`, or when its address or `@domain` is on the allowlist.
Everything else fails, which Supabase Auth reports as a 500. A second trigger strips the nonce on the update
Supabase Auth makes right after the insert. Upstream's `handle_new_user` trigger then creates the profile.

## Storage

Supabase Storage keeps files on its volume. The migration creates three buckets: `sources` (private, per
notebook folder), `audio` (private) and `public-images`. The web app uploads sources directly with the user's
session; n8n reads and writes them with the service role over the private network.
