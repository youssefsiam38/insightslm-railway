# syntax=docker/dockerfile:1
#
# InsightsLM's Supabase Edge Functions for Railway.
#
# Supabase's self-hosting stack mounts a functions directory into the edge runtime, which fetches each
# function's remote imports (esm.sh, deno.land) the first time it runs. Here the functions are taken from a
# pinned upstream commit, their floating supabase-js import is pinned (patch-functions.mjs), and each is bundled
# into an eszip at build time; the runtime serves only those bundles and fetches nothing. A small main service
# (main/index.ts) routes requests, mints the Supabase API keys from JWT_SECRET, and requires the service-role key
# for the two callbacks that upstream leaves unauthenticated.
ARG GIT_IMAGE=docker.io/alpine/git:v2.49.1@sha256:c0280cf9572316299b08544065d3bf35db65043d5e3963982ec50647d2746e26
ARG NODE_IMAGE=docker.io/library/node:22-alpine@sha256:c610fcdfb1d5b4740dd70c284ed3cb16bb857e0f7166196e36a5501df7a3aa32
ARG EDGE_RUNTIME_IMAGE=docker.io/supabase/edge-runtime:v1.76.2@sha256:edd22bef4477b900d5c300e287ce9b18bff9b81a0291bee14ee0b7c7b71a2899
ARG INSIGHTSLM_COMMIT=76cf9d808056c3b7afac3c1cb9bd180014ff6f64

FROM ${GIT_IMAGE} AS source
ARG INSIGHTSLM_COMMIT
RUN git init -q /src \
    && git -C /src fetch -q --depth 1 https://github.com/theaiautomators/insights-lm-public.git "${INSIGHTSLM_COMMIT}" \
    && git -C /src checkout -q FETCH_HEAD \
    && test "$(git -C /src rev-parse HEAD)" = "${INSIGHTSLM_COMMIT}" \
    && rm -rf /src/.git

FROM ${NODE_IMAGE} AS patched
COPY --from=source /src/supabase/functions /opt/insightslm/src
COPY images/functions/patch-functions.mjs /tmp/patch-functions.mjs
RUN node /tmp/patch-functions.mjs /opt/insightslm/src

FROM ${EDGE_RUNTIME_IMAGE} AS bundles
COPY --from=patched /opt/insightslm/src /opt/insightslm/src
RUN mkdir -p /opt/insightslm/functions \
    && for dir in /opt/insightslm/src/*/; do \
         name=$(basename "$dir"); \
         edge-runtime bundle --entrypoint "/opt/insightslm/src/$name/index.ts" --output "/opt/insightslm/functions/$name.eszip" --timeout 600 \
           || exit 1; \
       done \
    && test "$(ls /opt/insightslm/functions | wc -l)" = 9

FROM ${EDGE_RUNTIME_IMAGE}
ARG INSIGHTSLM_COMMIT
ARG WRAPPER_VERSION=0.0.0-dev
ARG VCS_REF=unknown

COPY --from=bundles /opt/insightslm/functions /opt/insightslm/functions
COPY images/functions/main/index.ts /opt/insightslm/main/index.ts
COPY --chmod=0755 images/functions/entrypoint.sh /usr/local/bin/insightslm-functions-entrypoint
COPY licenses/ /usr/share/licenses/insightslm-railway/

LABEL org.opencontainers.image.title="insightslm-railway-functions" \
      org.opencontainers.image.description="InsightsLM's Supabase Edge Functions, prebuilt as eszip bundles, for the Railway template. Not affiliated with the InsightsLM project." \
      org.opencontainers.image.source="https://github.com/youssefsiam38/insightslm-railway" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${WRAPPER_VERSION}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      io.insightslm-railway.upstream.commit="${INSIGHTSLM_COMMIT}"

EXPOSE 9000
ENTRYPOINT ["/usr/local/bin/insightslm-functions-entrypoint"]
