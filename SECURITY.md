# Security

## Reporting

Open an issue at https://github.com/youssefsiam38/insightslm-railway/issues for a problem with the template or
its wrappers. Report anything in InsightsLM itself to its maintainers
(https://github.com/theaiautomators/insights-lm-public). Do not include credentials, tokens, public hostnames
or private documents in an issue.

## What this bundle holds

Each user's notebooks: uploaded files, the text extracted from them and their embeddings, notes, chat history
and audio overviews; plus the deployment's model API keys, stored encrypted in n8n's credentials.

## Problems this template closes

| Problem on a public platform | What the template does |
|---|---|
| `process-document-callback` and `audio-generation-callback` are deployed without JWT verification and check nothing: anyone who learns a source or notebook id can overwrite its text, summary and status, or its audio link | The gateway answers 403 for both, and the functions service itself requires a valid service-role token for them. Only n8n calls them, privately. |
| Supabase Auth accepts any signup posted to it, even though InsightsLM shows no sign-up page | A `BEFORE INSERT` trigger on `auth.users` admits the owner and `INSIGHTSLM_ALLOWED_SIGNUPS`; nobody else. |
| n8n's editor is claimed by whoever opens it first, and the audio workflow needs the Execute Command node | n8n has no public domain; its owner account is claimed for the deployer at the first start; the audio workflow no longer executes commands. |
| The page loads a script from `cdn.gpteng.co`, the site builder the app was made with, into every session | The script tag is removed at build time; the build fails if it moves. |
| Edge functions import `supabase-js@2` from esm.sh at run time, resolving whatever release is current | Functions are bundled at build time with a pinned release; the runtime serves only those bundles and fetches nothing. |
| The frontend's lockfile carries published advisories (React Router open redirect, auth-js path routing, others) | Non-breaking fixes applied (see `UPSTREAM.md`); two moderate React Router advisories need its next major. |
| Well-known demo secrets (Supabase's `.env.example`) | Every secret is generated per deploy; the wrappers refuse the published values and short ones. |
| Model keys typed into n8n by hand, often in several credentials | Set once as variables; written into n8n's encrypted credential store at start; the web server process does not hold them. |

## What is exposed

| Surface | Anonymous | Notes |
|---|---|---|
| `app` | The built web app | Static files only; no API, no secrets beyond the public anon key and gateway URL. |
| `kong` | Auth's sign-in and sign-up endpoints, Realtime's socket, Storage's public bucket; everything else needs the anon key | REST, Storage and Realtime apply row-level security per user; the functions check the caller's session; the callbacks are closed. |
| `functions`, `n8n`, `auth`, `rest`, `realtime`, `storage`, `db` | Not public | Private network only. n8n's webhooks require the shared `NOTEBOOK_GENERATION_AUTH` header. |

## How the signup gate decides

A new user is admitted when one of these holds, and refused otherwise:

1. **Owner bootstrap.** The app's start-up stores the SHA-256 of 32 random bytes and sends the bytes as user
   metadata through the Auth admin API; the insert deletes the hash. The nonce is never logged and cannot be
   replayed.
2. **Allowlist.** The address, or `@` and its domain, is in `INSIGHTSLM_ALLOWED_SIGNUPS`. The match is exact.
3. **Open mode.** `INSIGHTSLM_SIGNUP_MODE=open`, set deliberately.

`tests/smoke.sh` checks that a stranger and a forged nonce are refused and an allowlisted address is admitted.

## Residual risks

**Admission is by address.** Addresses are not verified (`GOTRUE_MAILER_AUTOCONFIRM=true`). Someone who knows
an allowlisted address can sign up as it before its owner does.

**Your documents go to third parties.** OpenAI gets source text and chat context, Google gets podcast scripts,
and web pages are fetched through Jina's reader. Choose providers whose terms fit your material, or point
`OPENAI_BASE_URL`, `GEMINI_BASE_URL` and `READER_BASE_URL` elsewhere.

**Authenticated users can make the backend fetch URLs.** Adding a website source makes n8n fetch it through the
reader; that is the feature. Keep signup closed to people you trust.

**n8n with a public domain.** If you give `n8n` a domain to customise the workflows, its editor is protected
only by the owner password (`N8N_OWNER_PASSWORD`), and an n8n user can read every credential it stores. Turn
off `INSIGHTSLM_MANAGE_WORKFLOWS` if you change the workflows, or the next start overwrites them.

**Anyone with access to the Railway project has everything**: the database password, `JWT_SECRET` (from which
the service-role key follows), n8n's encryption key and the model keys.

**A refused signup looks like a server error** ("Database error saving new user").

**The Vault root key** is a file on the `db` volume, beside the data it protects, because Railway gives a service
one volume.
