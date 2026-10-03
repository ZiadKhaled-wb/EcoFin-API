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
`git worktree remove --force` (and some recursive deletes) follow the npm workspace link `node_modules/@ecotech/contracts` (a junction to `packages/contracts`) and delete its target. That happened once, when the package was still a separate folder (DECISIONS D21, D26). Unlink the links first: see D21 for the exact commands.

## Not possible yet
- Starting the API server, and so every HTTP-level integration and e2e test. Those are written and skipped unless `RUN_INTEGRATION=1` / `RUN_E2E=1`. See `docs/testing/TEST_PLAN.md`.
- Live browser walkthroughs (no Playwright MCP this session).
