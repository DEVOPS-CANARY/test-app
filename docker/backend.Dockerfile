# syntax=docker/dockerfile:1
#
# NestJS backend image (test-app). Rendered by the platform's golden path;
# edit freely, `copier update` shows template changes as a diff.
#
# Build (context is ./backend, so docker/backend.Dockerfile.dockerignore applies):
#   docker build -f docker/backend.Dockerfile -t test-app-backend:dev backend
#
# The same image serves two purposes:
#   app:        node dist/main.js                                (default CMD)
#   migrations: node node_modules/prisma/build/index.js migrate deploy

# Pinned by tag AND digest: the tag documents the version for humans, the digest
# guarantees the exact bytes. Renovate bumps both together.
ARG NODE_IMAGE=node:22.23.3-alpine3.24@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402

# --- base: shared OS layer ----------------------------------------------------
FROM ${NODE_IMAGE} AS base
# Prisma's query engine links against OpenSSL; Alpine does not ship it by default.
RUN apk add --no-cache openssl
WORKDIR /app

# --- build: full toolchain, compiles TypeScript ---------------------------------
FROM base AS build
# The manifests are bind-mounted, not copied: they never become a layer, and the
# package manager's download cache lives in a BuildKit cache mount.
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=package-lock.json,target=package-lock.json \
    --mount=type=cache,target=/root/.npm \
    npm ci
COPY . .
RUN npx prisma generate && npm run build

# --- prod-deps: runtime dependencies only ---------------------------------------
FROM base AS prod-deps
RUN --mount=type=bind,source=package.json,target=package.json \
    --mount=type=bind,source=package-lock.json,target=package-lock.json \
    --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

# --- runtime --------------------------------------------------------------------
FROM base AS runtime
# The runtime never installs packages, so drop the package managers that ship
# with the base image: less to patch (Trivy flags npm's own bundled deps) and
# nothing for an attacker to install tools with.
RUN rm -rf /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/corepack \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
    /opt/yarn-* /usr/local/bin/yarn /usr/local/bin/yarnpkg

ENV NODE_ENV=production \
    PORT=3001

# --link: each copy is its own layer, reused even when earlier layers change.
COPY --link --from=prod-deps /app/node_modules ./node_modules
# Generated Prisma client, plus the Prisma CLI and engines so the migration Job
# can run from this same image (prisma is a devDependency, so prod-deps lacks it).
COPY --link --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY --link --from=build /app/node_modules/@prisma ./node_modules/@prisma
COPY --link --from=build /app/node_modules/prisma ./node_modules/prisma
COPY --link --from=build /app/prisma ./prisma
COPY --link --from=build /app/dist ./dist
COPY --link package.json ./

# Links the image to its repo in GHCR (visibility, permissions, README).
LABEL org.opencontainers.image.source="https://github.com/DEVOPS-CANARY/test-app"

# Files stay owned by root and are only readable by the app user, so a
# compromised process cannot rewrite its own code. Numeric UID:GID (the image's
# `node` user) lets Kubernetes' runAsNonRoot verify the user is not root.
USER 1000:1000

EXPOSE 3001
# exec form: node is PID 1 and receives SIGTERM directly -> enableShutdownHooks()
CMD ["node", "dist/main.js"]
