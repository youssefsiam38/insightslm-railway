# Upstream provenance

Everything the bundle runs, where it comes from, and what this repository changes. Digests are
multi-architecture index digests as resolved on 2026-09-16. The Railway template references tags, because
Railway's template generator rejects digest references; the Dockerfiles and `compose.yaml` pin tag and digest.

## InsightsLM

| | |
|---|---|
| Project | https://github.com/theaiautomators/insights-lm-public |
| Licence | MIT (`licenses/INSIGHTSLM-LICENSE`) |
| Commit pinned | `76cf9d808056c3b7afac3c1cb9bd180014ff6f64` (2026-01-16, `main`) |
| Why a commit | Upstream publishes no releases or images. |
| Used | `src/` (web app), `supabase/functions/`, `supabase/migrations/`, `n8n/*.json` |

The source is fetched by commit id, so git verifies the content.

### What this repository changes

| Part | Change | Why |
|---|---|---|
| `index.html` | The `cdn.gpteng.co/gptengineer.js` script tag is removed (build fails unless it is found exactly once). | A third-party script from the site builder, loaded into every session. |
| `package.json`, `package-lock.json` | `npm audit fix --omit=dev` (non-breaking): `@supabase/supabase-js` 2.49.8 → 2.116.0, `react-router-dom` 6.27.0 → 6.30.6, `@remix-run/router` 1.20.0 → 1.23.4 and transitive fixes. The build checks upstream's manifests' hashes first. | Published advisories. Two moderate React Router advisories remain; their fix is React Router 7. |
| Edge functions | `esm.sh/@supabase/supabase-js@2` pinned to `@2.116.0`; `generate-note-title` reads `OPENAI_BASE_URL` (default `https://api.openai.com/v1`). Bundled to eszip. | Reproducible bundles; an OpenAI-compatible endpoint option. |
| Edge function routing | A main service of this repository's own; the two callbacks require the service-role key. | Upstream deploys them unauthenticated. |
| n8n workflows | Rewritten at provisioning time: addresses per node (see `ARCHITECTURE.md`), credential ids mapped to this deployment's, and the audio pipeline's ffmpeg check, disk files and Execute Command replaced by a Code node that writes WAV. | Upstream's workflows point at its author's project; n8n's official image has no ffmpeg. |
| Web app runtime | Served by `images/app/serve.mjs` (Node, no dependencies). | Upstream deploys the build to a static host. |

## Supabase

| Component | Image | Digest | Licence |
|---|---|---|---|
| Postgres (pgvector) | `supabase/postgres:17.6.1.136` | `sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00` | PostgreSQL, Apache-2.0 |
| Auth | `supabase/gotrue:v2.197.0` | `sha256:1736a63078f5922b198c4cbe50f80ab9a2d3b54fe8b7b6cfb2e9dc5dbbc12c6b` | MIT |
| PostgREST | `postgrest/postgrest:v14.17` | `sha256:c9dc201e555f5d8e37e7f39cdd4df0229774996e213bfd7de8d10ac609030f2c` | MIT |
| Realtime | `supabase/realtime:v2.134.10` | `sha256:cbcc6a7986fc28b6dcffa798b077d5fb9c69cd25500371ab49147a86d7edbb03` | Apache-2.0 |
| Storage | `supabase/storage-api:v1.74.0` | `sha256:f1546fac6d1c7e345428ac904bfaa7be7cecd50a1f549fe1cf38c628a7b15c85` | Apache-2.0 |
| Edge runtime | `supabase/edge-runtime:v1.76.2` | `sha256:edd22bef4477b900d5c300e287ce9b18bff9b81a0291bee14ee0b7c7b71a2899` | MIT |
| Kong | `kong:3.9.3` | `sha256:9a2ae6699a2ce0d60592eb176555d3594a22782c20cc6557a61ff3a7e8b559a3` | Apache-2.0 |

The `db`, `kong` and `storage` wrappers are derived from the wacrm template's. `db` also creates n8n's database
at initialisation.

## n8n

| | |
|---|---|
| Image | `n8nio/n8n:2.39.6`, `sha256:1eb33706d9bd902cc83f302ba8d608420dfc0815e03ee4bb1c072367d2c5e259`, unmodified |
| Licence | Sustainable Use License (see `THIRD_PARTY_NOTICES.md`) |

## Build and runtime tools

| Image | Digest | Used for |
|---|---|---|
| `alpine/git:v2.49.1` | `sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26` | fetching upstream by commit |
| `node:22-alpine` | `sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32` | the web app build and runtime |
| `pg` (npm) | 8.23.0, lockfile in `images/app/runtime` | the start-up's database client |
