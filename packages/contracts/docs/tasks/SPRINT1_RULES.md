> **Historical (written when contracts were a separate repo).** Since D26 this package lives in `EcoFin-API/packages/contracts` as an npm workspace; `file:../EcoFin-Contracts` no longer applies. Current rules: `EcoFin-API/docs/tasks/SPRINT1_RULES.md` and `EcoFin-API/DECISIONS.md`.

# Sprint 1: rules for every builder and reviewer

Read this, then your own `docs/tasks/<ID>.md`. It applies to every Sprint 1 task in every repo (API, Web, Contracts).

## Setup (already done by the master)
- The master ran `AGENT_SETUP.md` for this session. Don't repeat it. Read only: `AGENTS.md`, your skill (`.claude/skills/ecotech-build/SKILL.md` or `ecotech-review`), your task file and what it points to.
- Context7 is available as the `mcp__claude_ai_Context7__*` tools. Use them before writing code against any library API you aren't sure of.
- security-guidance is **not active** this session. Builders: before returning, run the security checklist from `ecotech-review` on your own diff. Reviewers: run it in full.
- Playwright MCP is **not available**. Client builders write Playwright tests as files (skipped unless `RUN_E2E=1`) and mark the "UI check" as `n.a. (no Playwright MCP)`.

## Environment (Windows 11, Git Bash or PowerShell, Node 24)
- **Network fix:** every `npm`/`npx`/`node` command that touches the network needs
  `NODE_OPTIONS=--no-network-family-autoselection` (Node's IPv6 race times out here). In Bash: `export NODE_OPTIONS=--no-network-family-autoselection` at the start of each command.
- Your worktree starts without `node_modules`: run `npm ci` first.
- **Never** run `rm -rf node_modules` or delete anything under `node_modules/@ecotech` by hand: it's a junction to the shared `EcoFin-Contracts` folder, and deleting through it once wiped that repo (DECISIONS D21). Use `npm ci` only.
- API tests need test env vars (until F01/F08 make `npm test` self-contained):
  `NODE_ENV=test SUPABASE_URL=https://ci-test.supabase.co SUPABASE_ANON_KEY=x SUPABASE_SERVICE_ROLE_KEY=y FRONTEND_URL=https://ci-test.example.com`
- The API server **can't be started** right now (known env problem). Don't try to fix it, don't run `npm run dev`.
- Docker is running and the Supabase CLI works through `npx -y supabase@2.119.0 ...`. See `docs/testing/ENVIRONMENT.md` (API repo).
- **Never** touch a remote database, never `supabase link`, never `db push`, never use the Supabase MCP for writes. Never read or print `.env` values.

## Git
- You work **only** in the worktree folder named in your task, on the branch named there. Commit there (small commits, clear messages). Never push. Never commit to `main` or `integration/sprint-1`. Never run `git checkout` on another branch inside the main repo folders.
- End every commit message with:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Shared files
Each task lists the shared files it **owns** (package.json, package-lock.json, app/route wiring, CI files, `.env.example`). Only the owner edits them.
- Need a package and you don't own `package.json`? Install it with `npm install <pkg>@<exact version> --no-save` so your tests run, and list `<pkg>@<version> (dep|devDep)` in your summary. The master adds it at merge.
- Need a route registered, a script added or an env var documented in a file you don't own? Put the exact lines in your summary under "Master must add".

## Docker
Docker is only for running local Supabase (`supabase start`). **Never** add a `Dockerfile`, `docker-compose*` or `.dockerignore` to any repo. `supabase/.temp` and `supabase/.branches` must stay gitignored; only `supabase/config.toml`, `supabase/migrations/**` and seed files are committed.

## How to work
- Follow `ecotech-build` exactly. Tests first. Smallest change that makes them pass.
- Don't overthink, and don't refactor outside your scope.
- A business rule you can't find in the slice, data model or baseline SQL: **stop and report**. Don't guess. Something you need that isn't merged yet: **stop and report**. Don't build a stand-in.
- Tests that need the running server or DB: write them **now** as real test files that skip unless `RUN_INTEGRATION=1` (Vitest: `describe.skipIf(process.env.RUN_INTEGRATION !== '1')`) or `RUN_E2E=1` (Playwright). They must be complete, so they run as they are once the env works.
- Never edit `supabase/migrations/20261002000000_v1_baseline.sql`. New SQL goes in a **new** migration with the timestamp your task gives you.
- Contracts: import shapes from `@ecotech/contracts`. Don't define API types locally. Don't change the contracts package unless your task says so. If a schema you need is missing, stop and report.

## Test plan (required)
Write `docs/testing/plans/<ID>.md` in the repo you worked in, one row per test:

| Test ID | Done-when item | Type (unit/integration/e2e/manual) | Preconditions (env vars, seed data, logged-in role) | Steps (exact commands or HTTP requests with body) | Expected result (status code, body, DB rows) | Automated file:test name | Status (passing now / written-skipped / manual) |

Every "Done when" item and every security rule you touched (cross-shop, permission 403, idempotency, audit row) needs at least one row.

## What you return
The `ecotech-build` summary (section 4), plus:
```
Branch: <branch>   Worktree: <path>   Last commit: <sha>
Tests: passing now <n> / written-skipped <n> / manual <n>
Master must add: <deps, scripts, routes, env vars, or "none">
```
