# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage: produce the static bundle with the exact locked dependencies.
# ---------------------------------------------------------------------------
FROM node:26-slim AS build

WORKDIR /app

# npm ci fails rather than silently updating when package-lock.json drifts.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build

# ---------------------------------------------------------------------------
# Runtime stage: nginx-unprivileged already runs as uid 101 on port 8080.
# ---------------------------------------------------------------------------
FROM nginxinc/nginx-unprivileged:1.29-alpine AS runtime

# Provenance. `az acr build` has no --label flag, so the deployment workflow
# passes these with --build-arg and infra/scripts/resolve-digests.sh refuses to
# deploy an image whose revision label is not the commit being deployed.
ARG IMAGE_REVISION=unknown
ARG IMAGE_SOURCE=https://github.com/ibranibeny/GithubDay
ARG IMAGE_CREATED=1970-01-01T00:00:00Z

LABEL org.opencontainers.image.title="azure-cost-copilot-web" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.created="${IMAGE_CREATED}"

USER root

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
# The template stays outside the web root so the un-rendered ${PLACEHOLDER}
# version is never served.
COPY public/config.template.js /etc/nginx/config.template.js
COPY docker-entrypoint.sh /usr/local/bin/config-entrypoint.sh

# The entrypoint writes config.js into the web root as uid 101, so that
# directory must be owned by the runtime user.
RUN chown -R 101:101 /usr/share/nginx/html \
    && chmod 0555 /usr/local/bin/config-entrypoint.sh

USER 101

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O /dev/null http://127.0.0.1:8080/health/live || exit 1

ENTRYPOINT ["/usr/local/bin/config-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
