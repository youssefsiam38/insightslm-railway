# syntax=docker/dockerfile:1
#
# InsightsLM for Railway: the web app, plus the start-up that sets up its database and wires its n8n workflows.
#
# InsightsLM is a Vite single-page app on Supabase, with its processing in n8n; its guide has the deployer run
# the migration in the Supabase dashboard, import and wire the workflows in n8n by hand, and host the static
# build. This image builds the app once from a pinned commit, with placeholder values for the two VITE_*
# settings Vite inlines, and at start-up: sets up the database and owner (setup.mjs), provisions the workflows
# in n8n's official image through its REST API (provision-n8n.mjs), writes the real values into the build, and
# serves it (serve.mjs).
#
# Changes to upstream's files: index.html loses a third-party script (cdn.gpteng.co) that upstream's page
# loads from its site builder; package.json and the lockfile carry non-breaking fixes for published advisories
# (images/app/deps; the build first checks upstream's manifests are the ones those fixes were made from).
ARG GIT_IMAGE=docker.io/alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26
ARG NODE_IMAGE=docker.io/library/node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
ARG INSIGHTSLM_COMMIT=76cf9d808056c3b7afac3c1cb9bd180014ff6f64
ARG UPSTREAM_PACKAGE_JSON_SHA256=4969bdff166699326a9d07ea1a7c7a632f8bf799ecf8f2595456e720e18e5020
ARG UPSTREAM_PACKAGE_LOCK_SHA256=44624a54e3d4c606634a9ecf119074f30432d68c48be265b6fec585f18568da7

FROM ${GIT_IMAGE} AS source
ARG INSIGHTSLM_COMMIT
ARG UPSTREAM_PACKAGE_JSON_SHA256
ARG UPSTREAM_PACKAGE_LOCK_SHA256
RUN git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/theaiautomators/insights-lm-public.git "${INSIGHTSLM_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${INSIGHTSLM_COMMIT}" \
    && rm -rf /src/.git \
    && echo "${UPSTREAM_PACKAGE_JSON_SHA256}  /src/package.json" | sha256sum -c - \
    && echo "${UPSTREAM_PACKAGE_LOCK_SHA256}  /src/package-lock.json" | sha256sum -c - \
    && test "$(grep -c 'cdn.gpteng.co/gptengineer.js' /src/index.html)" = 1 \
    && sed -i '\#<script src="https://cdn.gpteng.co/gptengineer.js" type="module"></script>#d' /src/index.html \
    && ! grep -q gpteng /src/index.html
COPY images/app/deps/package.json images/app/deps/package-lock.json /src/

FROM ${NODE_IMAGE} AS builder
WORKDIR /build
COPY --from=source /src/package.json /src/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY --from=source /src/ ./
# Placeholders, replaced at start-up. URL-shaped where the code may parse them; `.invalid` never resolves.
ENV VITE_SUPABASE_URL=https://insightslm-railway-placeholder-supabase-url.invalid \
    VITE_SUPABASE_ANON_KEY=insightslm-railway-placeholder-supabase-anon-key
RUN npm run build
COPY images/app/fill-public-env.mjs /tmp/fill-public-env.mjs
RUN node /tmp/fill-public-env.mjs --index /build/dist /opt/insightslm/pristine

FROM ${NODE_IMAGE} AS runtime-deps
WORKDIR /opt/insightslm/runtime
COPY images/app/runtime/package.json images/app/runtime/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund --ignore-scripts

FROM ${NODE_IMAGE}
ARG INSIGHTSLM_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown
ARG BUILD_DATE=1970-01-01T00:00:00Z

ENV NODE_ENV=production PORT=3000 INSIGHTSLM_COMMIT=${INSIGHTSLM_COMMIT}
WORKDIR /app

COPY --from=builder --chown=node:node /build/dist /app/dist
COPY --from=builder /opt/insightslm/pristine /opt/insightslm/pristine
COPY --from=runtime-deps /opt/insightslm/runtime /opt/insightslm/runtime
COPY --from=source /src/n8n/ /opt/insightslm/workflows/
COPY --from=source /src/supabase/migrations/ /opt/insightslm/migrations/
COPY lib/mint-supabase-keys.mjs images/app/setup.mjs images/app/provision-n8n.mjs images/app/fill-public-env.mjs \
     images/app/serve.mjs images/app/gate.sql /opt/insightslm/
COPY --chmod=0755 images/app/entrypoint.sh /usr/local/bin/insightslm-app-entrypoint
COPY licenses/ /usr/share/licenses/insightslm-railway/

RUN test -s /opt/insightslm/pristine/.index \
    && grep -q '^assets/' /opt/insightslm/pristine/.index \
    && test "$(ls /opt/insightslm/workflows/InsightsLM___*.json | wc -l)" = 6 \
    && ls /opt/insightslm/migrations/*.sql >/dev/null \
    && ! grep -rq gpteng /app/dist \
    && for f in setup provision-n8n fill-public-env serve mint-supabase-keys; do node --check "/opt/insightslm/$f.mjs" || exit 1; done

USER node

LABEL org.opencontainers.image.title="insightslm-railway-app" \
      org.opencontainers.image.description="InsightsLM's web app for the Railway template, with the start-up that sets up its database and provisions its n8n workflows. Not affiliated with the InsightsLM project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/insightslm-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      io.insightslm-railway.upstream.commit="${INSIGHTSLM_COMMIT}"

EXPOSE 3000
ENTRYPOINT ["/usr/local/bin/insightslm-app-entrypoint"]
