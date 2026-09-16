# Maintenance

## Release process

1. Make the change on a branch. The `test` workflow builds every image and runs the full suite on every push
   and pull request.
2. Run locally:
   ```bash
   docker compose build --pull
   tests/static.sh && tests/smoke.sh && tests/persistence.sh
   ```
3. Tag `vX.Y.Z`. The `publish-image` workflow builds the five images (`db`, `kong`, `storage`, `functions`,
   `app`) as local candidates, runs the smoke and persistence suites against them, and only then retags and
   pushes those exact images to GHCR as `X.Y.Z`, `X.Y` and `latest`.
4. Update the Railway template (id in `RAILWAY_TEMPLATE.md`): the image tags of the five services, with
   `templateChangeSetStage` then `templateChangeSetApply`. Tags only; the generator rejects digests. Republish
   the overview with `railway templates update <id> --readme-file marketplace/OVERVIEW.md` if it changed. Never
   put angle-bracket placeholders in the overview or variable descriptions: Railway strips them.
5. Deploy the updated template into a scratch project. Add a temporary service running `tests/mock-ai.py` (or
   use real keys), point `OPENAI_BASE_URL`, `GEMINI_BASE_URL` and `READER_BASE_URL` on `app` and
   `OPENAI_BASE_URL` on `functions` at it, and run
   ```bash
   OWNER_EMAIL=... OWNER_PASSWORD_FILE=... INSIGHTSLM_SMOKE_AI=1 ALLOWED_EMAIL=... \
     tests/railway-smoke.sh https://APP https://KONG
   ```
   Then redeploy every service, run it again, and delete the scratch project.

## Bumping InsightsLM

1. Read the commits between the pinned commit and the candidate: `supabase/migrations/`, `supabase/functions/`,
   `n8n/*.json`, `package.json`, `index.html`.
2. Change `ARG INSIGHTSLM_COMMIT` in `images/app/Dockerfile` and `images/functions/Dockerfile`.
3. If `package.json` or the lockfile changed, the app build stops at the hash check: regenerate
   `images/app/deps` (`npm audit fix --package-lock-only --omit=dev` on upstream's files) and update the two
   hashes.
4. Build and run the suites; provisioning stops on any workflow change it does not recognise.

### Breaking-change checklist

- [ ] New migration files: they run once each, in name order, in one transaction each. Upstream's current
      migration creates policies without `IF NOT EXISTS`; a later file editing it will not be re-run.
- [ ] Workflow nodes renamed or new hard-coded addresses: update `REWRITES` in `images/app/provision-n8n.mjs`.
- [ ] The audio pipeline's nodes (`Check is FFMPEG Installed`, `Convert to File`, `Execute Command`, the
      read/write file nodes): update `withoutFfmpeg`.
- [ ] New credential types referenced by a workflow: provisioning stops with "which this template does not
      provide"; add them to `CREDENTIALS`.
- [ ] New or renamed edge functions: update the list in `images/functions/patch-functions.mjs`, and the Kong
      routes if a new function is only for n8n.
- [ ] New `VITE_*` variables in `src/`: add a placeholder in `images/app/Dockerfile` and a shape in
      `fill-public-env.mjs`.
- [ ] Webhook paths in the workflows: they are also in the `functions` variables of the template.

## Bumping n8n

Provisioning uses the REST API n8n's own editor uses (`/rest/login`, `/rest/owner/setup`, `/rest/credentials`,
`/rest/workflows`, `/rest/workflows/:id/activate`), which is not a public, versioned API. After a bump, the
smoke test's start-up and workflow sections are the ones that matter; check n8n's release notes for changes to
publishing, credentials and the Code node's binary data. Record the digest in `UPSTREAM.md` and the tag in the
template.

## Bumping the Supabase stack

Keep it in step with the wacrm template, which shares the `db`, `kong` and `storage` wrappers. The edge runtime:
bundles are built with the same image they run on; bump both together (one `ARG`).

## What to watch

| Source | Why |
|---|---|
| https://github.com/theaiautomators/insights-lm-public/commits/main | Migrations, functions, workflows. |
| https://github.com/n8n-io/n8n/releases | REST API and workflow format changes. |
| https://github.com/supabase/edge-runtime/releases | Bundle format changes. |

## Rolling back

Republish the template with the previous image tags. **The database does not roll back.** n8n's workflows are
rewritten by the older app image on its next start. Restore the `db` and `storage` volumes, taken at the same
moment, from a backup taken before the upgrade if needed.

## Rotating secrets

| Secret | Effect of changing it |
|---|---|
| `JWT_SECRET` (`auth`) | New API keys and sessions: redeploy `kong`, `rest`, `realtime`, `storage`, `functions`, `app`. |
| `NOTEBOOK_GENERATION_AUTH` (`functions`) | Referenced by `app`; redeploy `functions` and `app` (which updates n8n's credential). |
| `N8N_ENCRYPTION_KEY` (`n8n`) | Never on a running install: n8n can no longer decrypt its credentials. |
| Model keys (`app`) | Redeploy `app` (and `functions` for `OPENAI_*`). |

## Backups

Railway volume backups cover `db` and `storage`. Back up both together: files are referenced by rows. n8n's
workflows and credentials are in the `n8n` database on the same volume.
