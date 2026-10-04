# syntax=docker/dockerfile:1
#
# EcoFin API image. Built by .github/workflows/deploy-dev.yml and pushed to
# ghcr.io; the VM only pulls and runs it (see docs/05-operations/deployment.md).
# The repo is an npm workspace: packages/contracts (@ziadkhaled-wb/contracts) is built
# first and shipped next to the bundled server.

ARG NODE_VERSION=24

# --- build: contracts, then type-check and bundle src/server.ts --------------
FROM node:${NODE_VERSION}-bookworm-slim AS build
WORKDIR /app
COPY package.json package-lock.json ./
COPY packages/contracts/package.json packages/contracts/
RUN npm ci --no-audit --no-fund --ignore-scripts
COPY packages/contracts packages/contracts
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- runtime: production dependencies + the bundle, running as `node` --------
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ENV NODE_ENV=production \
    PORT=3001
WORKDIR /app
COPY package.json package-lock.json ./
COPY packages/contracts/package.json packages/contracts/
RUN npm ci --omit=dev --no-audit --no-fund --ignore-scripts && npm cache clean --force
COPY --from=build /app/packages/contracts/dist packages/contracts/dist
COPY --from=build /app/dist ./dist

USER node
EXPOSE 3001

# deploy.sh waits for this to report "healthy" before keeping a release.
HEALTHCHECK --interval=10s --timeout=5s --start-period=20s --retries=3 \
    CMD ["node", "-e", "fetch('http://127.0.0.1:' + (process.env.PORT || 3001) + '/health').then((r) => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]

CMD ["node", "--enable-source-maps", "dist/server.js"]
