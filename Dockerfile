# syntax=docker/dockerfile:1
#
# EcoFin API image. Built by .github/workflows/deploy-dev.yml and pushed to
# ghcr.io; the VM only pulls and runs it (see docs/05-operations/deployment.md).

ARG NODE_VERSION=24

# --- build: type-check and bundle src/server.ts into dist/server.js ----------
FROM node:${NODE_VERSION}-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- runtime: production dependencies + the bundle, running as `node` --------
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=3001
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist ./dist

USER node
EXPOSE 3001

# deploy.sh waits for this to report "healthy" before keeping a release.
HEALTHCHECK --interval=10s --timeout=3s --start-period=15s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || 3001) + '/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]

CMD ["node", "--enable-source-maps", "dist/server.js"]
