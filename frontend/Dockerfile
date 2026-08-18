# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Build stage: produce the static bundle with the exact locked dependencies.
# ---------------------------------------------------------------------------
FROM node:22-slim AS build

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
