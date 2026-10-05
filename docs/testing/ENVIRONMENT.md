# Test environment (dev machine), checked 3 Oct 2026

What can and can't run on the Sprint 1 dev machine (Windows 11, Git Bash + PowerShell). Update this file when the environment changes.

## Summary

| Check | EcoFin-API | EcoFin-Web |
|---|---|---|
| `npm ci` | ✅ (needs the network fix below) | ✅ |
| `typecheck` | ✅ | ⚠️ no script on `main` (F01 adds it) |
| `lint` | ✅ | ✅ |
| unit tests | ⚠️ 2 of 4 files fail at import with the local `.env` (`SUPABASE_URL` invalid); **112/112 pass** with the CI test env vars | ⚠️ no test runner on `main` (F01 adds it) |
| `build` | ✅ | ✅ (chunk-size warning only) |
| Start the server | ❌ known env problem, **not attempted** | n.a. |
| Docker | ✅ Docker Desktop 29.1.3 (had to be started) | |
| Supabase CLI | ✅ through `npx -y supabase@2.119.0` (not installed globally) | |
| `supabase start` | ✅ local stack starts; the baseline migration applies | |
| `supabase db reset` | ✅ rebuilds from the baseline with no errors | |
| `smoke_test.sql` | ⚠️ **as shipped: fails** at line 29. **One-line fix: passed 79, failed 0** (details below) | |
| `psql` on the host | ❌ not installed; use `docker exec <db container> psql ...` | |
| Playwright MCP | ❌ failed to connect this session | |
| Context7 | ✅ (claude.ai connector) | |

## Network fix (machine-specific)
Node's IPv4/IPv6 "happy eyeballs" race times out on this network: `npm ping` and Node's `fetch` get `ETIMEDOUT`, while `curl` works. Fix for every npm/npx/node command:
```bash
export NODE_OPTIONS=--no-network-family-autoselection
```
This only applies to this machine. Don't put it in scripts or CI.

## API unit tests
`src/utils/env.ts` validates env at import time. With the local `.env`, `src/middleware/auth.test.ts` and `src/services/auth.service.test.ts` fail before any test runs. With the values CI uses, all pass:
```bash
NODE_ENV=test SUPABASE_URL=https://ci-test.supabase.co SUPABASE_ANON_KEY=x \
SUPABASE_SERVICE_ROLE_KEY=y FRONTEND_URL=https://ci-test.example.com npm test
# Test Files 4 passed (4), Tests 112 passed (112)
```
F01 (B1) makes `npm test` self-contained.

## Local database
Checked in a throwaway Supabase project in the scratchpad (not in this repo): `supabase init`, copy the baseline migration, `supabase start`, `supabase db reset`.

```bash
export NODE_OPTIONS=--no-network-family-autoselection
npx -y supabase@2.119.0 start      # first run pulls images (~several minutes)
npx -y supabase@2.119.0 db reset   # "Applying migration 20261002000000_v1_baseline.sql... Finished"
export MSYS_NO_PATHCONV=1          # Git Bash: stop it rewriting /tmp paths
docker cp ecotech-agent-kit/smoke_test.sql supabase_db_<project_id>:/tmp/smoke.sql
docker exec supabase_db_<project_id> psql -U postgres -d postgres -f /tmp/smoke.sql
```
Local URLs: DB `postgresql://postgres:postgres@127.0.0.1:54322/postgres`, API `http://127.0.0.1:54321`, Mailpit `http://127.0.0.1:54324`.

### Smoke test result
- **As shipped** (`ecotech-agent-kit/smoke_test.sql`): `ERROR: invalid input syntax for type uuid: "owner-a@x"` at line 29. The fixture does `INSERT INTO auth.users VALUES (id, email)`, which assumes a two-column stub `auth.users`. Real Supabase `auth.users` starts with `instance_id`.
- **With one change**, `INSERT INTO auth.users (id, email) VALUES`: **passed 79, failed 0** after a fresh `db reset`.
- F02 (B3) commits the smoke test into this repo with that fix, and adds the CI job.

### Port note
The Supabase stack uses ports 54321–54329. Only one local Supabase project can run at a time with default ports, so run `supabase stop` before starting another one.

## ⚠️ Deleting worktrees on Windows
`git worktree remove --force` (and some recursive deletes) follow the npm workspace link `node_modules/@ziadkhaled-wb/contracts` (a junction to `packages/contracts`) and delete its target. That happened once, when the package was still a separate folder (DECISIONS D21, D26). Unlink the links first: see D21 for the exact commands.

## Not possible yet
- Starting the API server, and so every HTTP-level integration and e2e test. Those are written and skipped unless `RUN_INTEGRATION=1` / `RUN_E2E=1`. See `docs/testing/TEST_PLAN.md`.
- Live browser walkthroughs (no Playwright MCP this session).

## INT-1 update (5 Oct 2026)

What changed since the 3 Oct check, and the environment fixes used for INT-1 (no code or script changes):

| Item | Status |
|---|---|
| Docker Desktop | ✅ 29.1.3, had to be started by hand again |
| `supabase start` + `db reset` (twice in a row) | ✅ every migration and both seeds apply; second reset also clean |
| SQL tests | ✅ smoke 79/0, f04 48/0, f05 41/0, f06 67/0, f07 20/0, f10 30/0, f11 16/0, f13 32/0, f14 10/0 |
| Start the API server | ✅ **now works** with local env vars (below). The local `.env` points to a remote project and is not used: shell variables override it (dotenv never overwrites). |
| Start the Web app | ✅ `npx vite` with local `VITE_*` vars in the shell (they override `.env`) |
| Web `npm ci` | ❌ without a GitHub Packages token: `401 Unauthorized` on `@ziadkhaled-wb/contracts`. Needs `NPM_TOKEN` (classic token, `read:packages`) as a **user environment variable**, never written into `.npmrc`. Note: `npm ci` deletes `node_modules` before it fails. |
| Playwright browsers | ⚠️ Playwright 1.63 needs `chromium_headless_shell-1243`: run `npx playwright install chromium` once |
| Playwright MCP | ✅ connected this session. It writes logs to `.playwright-mcp/` in the folder it was started from; delete that folder after a walkthrough. |

### Local env for the API (server and integration tests)
```bash
export NODE_OPTIONS=--no-network-family-autoselection
export NODE_ENV=development PORT=3001            # NODE_ENV=test for vitest
export SUPABASE_URL=http://127.0.0.1:54321
export SUPABASE_ANON_KEY=<ANON_KEY from: npx -y supabase@2.119.0 status -o json>
export SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY from the same command>
export FRONTEND_URL=http://localhost:5173 MAILPIT_URL=http://127.0.0.1:54324
npx tsx src/server.ts                 # GET http://localhost:3001/health -> {"status":"ok","db":"ok"}
RUN_INTEGRATION=1 npx vitest run      # with NODE_ENV=test: 526/526 on 5 Oct
```

### Local env for the Web app and its e2e suite
```bash
export VITE_API_URL= VITE_DEV_API_TARGET=http://localhost:3001
export VITE_SUPABASE_URL=http://127.0.0.1:54321 VITE_SUPABASE_ANON_KEY=<local ANON_KEY> VITE_SENTRY_DSN=
npx vite --port 5173 --strictPort
# e2e (both apps up): E2E_BASE_URL=http://localhost:5173 E2E_API_URL=http://localhost:3001 plus the
# E2E_* logins from docs/testing/int-1/LOGINS.md (E2E_MULTI_SHOP_NAME='Dev Shop Two', E2E_RESET_EMAIL=owner.two@...)
RUN_E2E=1 npx playwright test         # 21/21 on 5 Oct
```

### Workaround used when no `NPM_TOKEN` was available (local only, nothing committed)
Build the same contracts version from its release tag and install it without saving:
`git archive contracts-v0.4.0 packages/contracts` into a scratch folder, `tsc -p tsconfig.build.json` there (copy `zod`, `big.js`, `@types/node`, `@types/big.js` in as real copies, not links), `npm pack`, then in EcoFin-Web `npm install --no-save <tgz>`. `package.json` and the lockfile stay untouched. Replace with a normal `npm ci` once a token is set.
