# Third-party notices

Licences for code copied into or built into this repository's images are vendored in `licenses/` and shipped
inside every image this repository builds, at `/usr/share/licenses/insightslm-railway/`.

## InsightsLM: MIT

The `app` and `functions` images contain InsightsLM, built from https://github.com/theaiautomators/insights-lm-public
at the commit in `UPSTREAM.md`, under the MIT licence (`licenses/INSIGHTSLM-LICENSE`), with the changes listed
there. The `app` image also carries upstream's six n8n workflow definitions and its migration, which it applies
and provisions. This repository's own files are MIT.

## n8n: Sustainable Use License

The template runs n8n's official image (`n8nio/n8n`) unmodified; this repository does not build, modify or
redistribute n8n. n8n's licence allows you to use it for your own internal business purposes or for
non-commercial or personal use; read its terms at https://github.com/n8n-io/n8n/blob/master/LICENSE.md before
offering an InsightsLM deployment to others. The workflows this template creates in n8n are InsightsLM's (MIT),
rewritten as `ARCHITECTURE.md` describes.

## Copied into the images

| What | From | Licence | Notice |
|---|---|---|---|
| Web app, edge functions, migration, n8n workflows | theaiautomators/insights-lm-public | MIT | `licenses/INSIGHTSLM-LICENSE` |
| Five database init scripts | supabase/supabase `docker/volumes/db` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |
| Kong declarative config, trimmed and extended | supabase/supabase `docker/volumes/api/kong.yml` | Apache-2.0 | `licenses/SUPABASE-LICENSE` |

InsightsLM's npm dependencies are installed from its lockfile (with the fixes in `UPSTREAM.md`) and carry their
own licences; so do the modules bundled into the edge functions and the `pg` client.

## Base images

| Image | Licence |
|---|---|
| `supabase/postgres`, `supabase/storage-api`, `supabase/edge-runtime`, `kong` | PostgreSQL, Apache-2.0, MIT |
| `supabase/gotrue`, `postgrest/postgrest`, `supabase/realtime` (run unmodified) | MIT, MIT, Apache-2.0 |
| `node`, `alpine/git` (build only) | Their own licences; Alpine packages under theirs |
