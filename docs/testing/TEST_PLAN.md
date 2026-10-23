# Sprint 1 test plan (F01–F09)

**Date:** 3 Oct 2026 (updated 4 Oct 2026: F05 added, Sprint 1 gaps closed, first full local run)  
**Coverage:** Features F01 (tooling), F02 (database), F03 (contracts), F04 (auth), F08 (server basics), F09 (UI shell)  
**Source plans:** EcoFin-API `docs/testing/plans/B1.md`, `B3.md`, `B5.md`, `B6.md`; EcoFin-Web `docs/testing/plans/B2.md`, `B7.md`, `B9.md`; contracts `packages/contracts/docs/testing/plans/B4.md`

## How to run when the environment is fixed

C01 plan: [docs/testing/plans/C01.md](plans/C01.md)

All commands run from the repo root with the Windows network fix: prefix npm/npx commands with `export NODE_OPTIONS=--no-network-family-autoselection;` (Git Bash) or `$env:NODE_OPTIONS = "--no-network-family-autoselection"` (PowerShell).

### Prerequisites
- Node 24 (from `.nvmrc`)
- Docker Desktop running
- Windows fix: `NODE_OPTIONS=--no-network-family-autoselection`
- Fresh `npm ci` in EcoFin-API (it also installs and builds `packages/contracts`) and in EcoFin-Web

### Database setup
```bash
npm run db:start
npm run db:reset
# Expected: "Applying migration 20261002000000_v1_baseline.sql..." + both seeds, "Finished supabase db reset"

npm run db:smoke
# Expected: "passed 79, failed 0"
# Note: the smoke_test.sql now sets `SET TIME ZONE 'Africa/Cairo';` at the start,
# so it no longer fails between 21:00–24:00 UTC (day-close ledger issue).

npm run db:smoke -- supabase/tests/f04_auth_test.sql
# Expected: "passed 48, failed 0" (F04 auth tests)

npm run db:smoke -- supabase/tests/f05_tenant_test.sql
# Expected: "passed 41, failed 0" (F05 tenant isolation)

npm run db:smoke -- supabase/tests/f06_permissions_test.sql
# Expected: "passed 67, failed 0" (F06 permissions + grant limits)

npm run db:smoke -- supabase/tests/f07_audit_test.sql
# Expected: "passed 20, failed 0" (F07 audit log)
```

### Contracts
```bash
npm run build:contracts
npm run test:contracts   # also part of `npm test` at the API root
# Expected: all pass (baseline test, role defaults, error codes, schemas, version, contract types, consumer smoke test)
```

### API unit and integration tests
```bash
cd ../EcoFin-API

# Unit tests
npm test
# Expected: 190 tests pass, 13 skipped (env from src/test/setup-env.ts)

# Integration tests (require local Supabase running, env from supabase status)
S=$(npx -y supabase@2.119.0 status -o json)
RUN_INTEGRATION=1 SUPABASE_URL=http://127.0.0.1:54321 \
  SUPABASE_ANON_KEY=$(echo "$S" | node -pe 'JSON.parse(require("fs").readFileSync(0)).ANON_KEY') \
  SUPABASE_SERVICE_ROLE_KEY=$(echo "$S" | node -pe 'JSON.parse(require("fs").readFileSync(0)).SERVICE_ROLE_KEY') \
  FRONTEND_URL=http://localhost:5173 \
  SMTP_URL=smtp://127.0.0.1:54325 MAIL_FROM="EcoFin CI <ci@ecotech.test>" \
  MAILPIT_URL=http://127.0.0.1:54324 \
  npx vitest run
# Expected: B5 health integration (1) and B6 auth integration (12) tests pass
```

Integration files run sequentially when `RUN_INTEGRATION=1` because they share the seeded database. Concurrency checks inside each file still run in parallel. SMTP is required for application invitations and password resets; without `SMTP_URL`, the app reports that email was not sent. Mailpit HTTP polling cannot receive mail that was never sent.

### Web unit tests
```bash
cd ../EcoFin-Web
npm test
# Expected: all pass (B2 tooling, B7 auth, B9 shell)
```

### Web E2E tests
```bash
# First run (once per session)
npx playwright install chromium

# Then run with both sets of env vars
E2E_OWNER_EMAIL=owner.one@ecotech.test \
  E2E_OWNER_PASSWORD=LocalDev-Only-2026! \
  E2E_MULTI_EMAIL=multi.shop@ecotech.test \
  E2E_MULTI_PASSWORD=LocalDev-Only-2026! \
  E2E_MULTI_SHOP_NAME=dev-shop-two \
  E2E_RESET_EMAIL=owner.two@ecotech.test \
  E2E_RESET_PASSWORD=LocalDev-Only-2026! \
  RUN_E2E=1 npx playwright test
# Expected: B2 smoke (RTL/LTR), B7 auth (expired token, 401 path, logout, forgot/reset, shop picker, activation routes),
#           B9 shell (language switch, 403 guard) tests pass
```

## Written-skipped and manual tests

| Story | Test ID | Done-when item | Type | Preconditions | Steps | Expected | File:test | Status |
|---|---|---|---|---|---|---|---|---|
| F01 | B1-02 | Gate: type error fails | manual | Clean tree | Create `src/gate-ts.ts` with `const x: number = 'a'; export default x;`, run `npm run typecheck`, delete the file | Exit 2 (observed) | n.a. | passing now (observed once, not committed) |
| F01 | B1-03 | Gate: lint error fails | manual | Clean tree | Create `src/gate-lint.ts` with `export const a: any = 1;`, run `npm run lint`, delete | Exit 1 (observed) | n.a. | passing now (observed once) |
| F01 | B1-04 | Gate: failing test fails | manual | Clean tree | Create `src/gate.test.ts` with `expect(1).toBe(2)`, run `npm test`, delete | Exit 1 (observed) | n.a. | passing now (observed once) |
| F01 | B1-05 | Gate: format error fails | manual | Clean tree | Create `src/gate-fmt.ts` with `export const a   =  1` (no semicolon, extra spaces), run `npm run format:check`, delete | Exit 1 (observed) | n.a. | passing now (observed once) |
| F01 | B1-06 | ci.yml runs the gates on pull_request | manual | n.a. | Read `.github/workflows/ci.yml`: triggers `pull_request` and push to `main`; steps npm ci, typecheck, lint, format:check, test, build; Node from `.nvmrc` | All six steps present, no `continue-on-error`. First real run happens on the PR (needs GitHub) | n.a. | manual |
| F01 | B1-07 | CONTRIBUTING steps work in a fresh clone | manual | Clean `git clone --branch feat/F01-server-tooling` of the worktree, `core.autocrlf=true` | `npm ci`, then the five scripts | All pass (observed); LF endings enforced by `.gitattributes`, so `format:check` passes on Windows | n.a. | passing now |
| F01 | B1-08 | `.env.example` lists every variable in env.ts | manual | n.a. | Compare keys in `src/utils/env.ts` (NODE_ENV, PORT, SERVICE_NAME, SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY, SUPABASE_JWT_SECRET, FRONTEND_URL, LOG_LEVEL, LOG_DRAIN_URL, RATE_LIMIT_REDIS_URL) with `.env.example` | All 11 present, each with required/optional comment; optional ones commented out where empty values would fail validation | n.a. | passing now |
| F01 | B2-01 | All scripts pass without a .env | manual | worktree, Node 24, no .env | `npm ci && npm run typecheck && npm run lint && npm run format:check && npm test && npm run build` | every command exits 0 | n/a | passing now |
| F01 | B2-03 | Type error blocks | manual | temp file `src/zz.ts` with `export const a: number = 'x';` (deleted after) | `npm run typecheck` | exit 2 | n/a | manual (proved locally) |
| F01 | B2-04 | Lint error blocks | manual | temp `src/zz.ts` with `export const b: any = 1;` | `npm run lint` | exit 1 (no-explicit-any) | n/a | manual (proved locally) |
| F01 | B2-05 | Format error blocks | manual | temp `src/zz.ts` with `export const c = {a:1}` | `npm run format:check` | exit 1 | n/a | manual (proved locally) |
| F01 | B2-06 | Failing test blocks | manual | temp `src/zz.test.ts` with `expect(1).toBe(2)` | `npm test` | exit 1 | n/a | manual (proved locally) |
| F01 | B2-07 | ci.yml runs all gates on pull_request | manual | GitHub | open a PR | typecheck, lint, format:check, test, build jobs steps run | .github/workflows/ci.yml | manual (needs GitHub) |
| F01 | B2-08 | Fresh clone works | manual | clean clone of the branch into scratchpad | CONTRIBUTING steps, then the gate chain | all exit 0 | n/a | manual (see summary) |
| F01 | B2-09 | .env.example lists every VITE_* | manual | none | `grep -rho "VITE_[A-Z_]*" src vite.config.ts` and compare with `.env.example` | every name present | n/a | manual (checked) |
| F01 | B2-10 | Arabic login is RTL | e2e | RUN_E2E=1, `npx playwright install chromium`, dev server | `RUN_E2E=1 npx playwright test` | html dir=rtl, lang=ar | e2e/smoke.spec.ts: Arabic (default) renders right-to-left | written-skipped |
| F01 | B2-11 | English login is LTR | e2e | as above; needs language switch (F09) | as above | html dir=ltr | e2e/smoke.spec.ts: English renders left-to-right | written-skipped (test.fixme until F09) |
| F02 | B3-15 | The CI `db` job runs green on GitHub | manual | Branch pushed, PR opened against `integration/sprint-1` (or `main`) | Open the PR's Checks tab, job `CI / db` | Steps: setup-cli 2.119.0, `supabase db start`, `supabase db reset`, re-run check prints `Second migration run: no changes`, super admin step prints `password_ok=true` / `is_super_admin=true`, smoke prints `passed 79, failed 0`, stop. Job green | `.github/workflows/ci.yml` job `db` | manual (needs GitHub) |
| F03 | B4-05 | Baseline missing fails clearly | manual | set `ECOFIN_BASELINE_SQL=/nope.sql` | `npm test` | suite fails with "Baseline SQL not found at ..." | src/baseline.test.ts (module load) | manual |
| F03 | B4-12 | Consumer smoke test under plain Node | manual | scratchpad | `npm pack`; in a new `"type":"module"` project `npm install ./ecotech-contracts-0.1.0.tgz`; `node t.mjs` importing `PERMISSION_KEYS`, `CONTRACTS_VERSION`, `AuthLogin`; also tsc with `moduleResolution: bundler` + `verbatimModuleSyntax` | prints `61 0.1.0 true`; tsc passes | (manual, done 3 Oct 2026) | manual (done, passed) |
| F04 | B6-23 | Two users from two shops, one after the other; each /me runs as its own user | integration | `db:reset`, local env | log in `owner.one@` then `owner.two`+`dev-shop-two`; `GET /api/auth/me` with each token, interleaved | each 200 with its own employee and org | auth.integration.test.ts: "two users from two shops log in one after the other…" | written-skipped (passed locally) |
| F04 | B6-24 | One login in two shops: selection, shop-B role, another shop refused | integration | same | `multi.shop@` login; `/me` without header, with `x-org-id` shop two, shop one, a random UUID; `owner.one` with shop two | 400 `SHOP_SELECTION_REQUIRED`; ACCOUNTANT in shop two; CASHIER in shop one; 403 `SHOP_NOT_ALLOWED` twice | auth.integration.test.ts: "one login in two shops…" | written-skipped (passed locally) |
| F04 | B6-25 | Refresh: new token works; old refresh token can't be reused | integration | same | login; refresh; `/me` with the new token; refresh again with the new token; wait 11 s; refresh with the first token | 200, 200, then 401 `TOKEN_INVALID` | auth.integration.test.ts: "refresh: the new access token works…" | written-skipped (passed locally) |
| F04 | B6-26 | Logout: old access token -> 401 on /me; refresh token -> 401 | integration | same | login; `POST /api/auth/logout`; `/me`; refresh | 200 `{ok:true}`; 401 `TOKEN_INVALID`; 401 `TOKEN_INVALID` | auth.integration.test.ts: "logout: the old access token gets 401…" | written-skipped (passed locally) |
| F04 | B6-27 | Reset: email in Mailpit -> token -> /reset-password -> new password works, old fails | integration | same; fewer than 2 recovery emails in the last hour | forgot-password; read the link from `http://127.0.0.1:54324/api/v1/search?query=to:...`; follow it; `POST /api/auth/reset-password {token,newPassword}`; log in with new and old; restore with change-password | 202; link found; 200; new 200; old 401 | auth.integration.test.ts: "reset: forgot-password email in Mailpit…" | written-skipped (passed locally) |
| F04 | B6-28 | Reset refuses a normal login token | integration + unit | same | `POST /api/auth/reset-password` with a password-login access token | 401 `TOKEN_INVALID`, password unchanged | auth.integration.test.ts: "reset-password refuses a normal login token…"; auth.service.test.ts: "a normal (password-login) access token is refused…" | written-skipped / passing now |
| F04 | B6-29 | Login and logout each write one audit row; a failed login writes a login_attempts row and no audit row | integration | same | count `audit_log` for cashier.two; login; logout; a failed login with a fresh identifier | +1 `auth.login`, +1 `auth.logout`; 1 `login_attempts` row `success=false`; no extra audit row | auth.integration.test.ts: "login and logout each write one audit row…" | written-skipped (passed locally) |
| F04 | B6-30 | 6th failure -> 429 (real DB) | integration | same | 5 failed logins for a fresh identifier, then a 6th | 401 x5, then 429 `TOO_MANY_LOGIN_ATTEMPTS` | auth.integration.test.ts: "the 6th attempt after 5 failures…" | written-skipped (passed locally) |
| F04 | B6-31 | Change password: other sessions end, this one stays, audit row | integration + unit | same | two logins of owner.two; change password with the second; refresh with the first; `/me` with both | 200; first refresh 401 `TOKEN_INVALID`; first token 401, second 200; +1 `auth.password_change`; seed password put back | auth.integration.test.ts: "change-password: other sessions end…"; auth.service.test.ts: "verifies the current password, updates it…" | written-skipped (passed locally) / passing now |
| F04 | B6-32 | Wrong current password -> 401 INVALID_CREDENTIALS (not a token code), session unchanged | integration + unit | same | change-password with a wrong current password | 401 `INVALID_CREDENTIALS`; `/me` still 200; attempt recorded | auth.integration.test.ts: "change-password with a wrong current password…"; auth.service.test.ts: "wrong current password -> 401…" | written-skipped / passing now |
| F04 | B6-33 | GoTrue revocation check (library behaviour) | manual | stack up, local anon key | curl: password grant -> `GET /auth/v1/user` -> `POST /auth/v1/logout?scope=local` -> `GET /auth/v1/user` -> refresh | 200, 204, then 403 `session_not_found`, refresh 400 `refresh_token_not_found` (GoTrue v2.197.0). PostgREST still accepts the old JWT until it expires (see summary). | n.a. | manual (observed 3 Oct) |
| F04 | B6-35 | select-shop (D23): multi-shop token, no x-org-id, picks a shop | unit (HTTP) + integration | mocked / local stack | `POST /api/auth/select-shop {orgId}` with a multi-shop token, no `x-org-id`; then a shop the login isn't in; no token | 200 contract `{ user, shop }` (shop B, ACCOUNTANT), `my_shops` read with no header, `auth_record_login` in shop B (+1 `auth.login` row for the shop-B employee); then `/me` with `x-org-id` B works; other shop 403 `SHOP_NOT_ALLOWED` with no audit; no token 401 | routes/auth.test.ts: "POST /api/auth/select-shop" (4 cases); auth.service.test.ts: "selectShop" (2); auth.integration.test.ts: "select-shop: a two-shop login picks shop B…" | passing now / written-skipped (passed locally) |
| F04 | B6-41 | Unknown username / another shop's username with this shop's slug: same as a wrong password, audit-wise too | integration | `db:reset`, local stack, `RUN_INTEGRATION=1` | login `ghost.<ts>` and `cashier.two` with slug `dev-shop-one`, and `owner.one` with a wrong password, all from one IP | all 401 `INVALID_CREDENTIALS` with the same body (bar requestId); +1 `login_attempts` row each (`success=false`, slug kept); 0 `audit_log` rows from that IP | auth.integration.test.ts: "unknown username / other-shop username: same 401 as a wrong password, login_attempts only" | passing now (local + CI db job) |
| F04/F05 | B6-42 | Role change applies to the next request on the same token | integration | same; employee created by the test | login; `/me` = CASHIER; service sets role ACCOUNTANT; `/me` with the same token | ACCOUNTANT, no re-login (per-request `session_context()`) | auth.sessions.integration.test.ts: "a role change applies to the very next request on the same token" | passing now (local + CI db job) |
| F04/F05 | B6-43 | Disabling the employee ends the live session at once; refresh does not get around it | integration | same | login; set `is_active=false`; `/me`; refresh; `/me` with the new token; new login; re-enable | 403 `ACCOUNT_DISABLED` on the live token, the refreshed token and a new login; works again after re-enabling | auth.sessions.integration.test.ts: "disabling the employee blocks the live token at once…" | passing now (local + CI db job) |
| F04/F05 | B6-44 | Archiving the employee ends the live session at once | integration | same | login; set `archived_at`; `/me` | 403 `ACCOUNT_DISABLED` | auth.sessions.integration.test.ts: "archiving the employee blocks the live token at once" | passing now (local + CI db job) |
| F04 | B6-45 | Refresh immediately after logout | integration | same | two logins of one user; logout the first; refresh both at once | first 401 `TOKEN_INVALID`; second 200 (only one session ended) | auth.sessions.integration.test.ts: "refresh immediately after logout is refused…" | passing now (local + CI db job) |
| F04 | B6-46 | Refresh immediately after change-password | integration | same | two logins; change password on the first; refresh both at once | other session 401 `TOKEN_INVALID`; this one 200 | auth.sessions.integration.test.ts: "refresh immediately after change-password…" | passing now (local + CI db job) |
| F05 | B8-01…22 | Tenant isolation: context + status gate, org keys refused, strict validate, assertSameOrg, file paths, cross-shop suite and CI gate, SQL grants/RLS/storage | unit + SQL + integration | see `docs/testing/plans/B8.md` | see B8.md | see B8.md | src/middleware/*.test.ts, src/utils/tenant.test.ts, src/test/cross-shop/*, supabase/tests/f05_tenant_test.sql | passing now (CI on PR 9: check + db green) |
| F06 | B10-01…22 | Permissions: all 61 keys denied/granted/removed/owner, setters (permission, other shop, reason, owner/self, one audit row), my_permissions, middleware over 61 keys, route markers + CI check, HTTP and cross-shop | unit + SQL + integration | see `docs/testing/plans/B10.md` (client: EcoFin-Web B10-web.md) | see B10.md | see B10.md | supabase/tests/f06_permissions_test.sql, src/middleware/permissions.test.ts, src/test/route-access/*, src/routes/employees.integration.test.ts | passing now (local) |
| F07 | B11-01…14 | Audit: forwarded headers (request id, resolved IP, user agent, device), search endpoint (audit.view, filters, pagination, actor names), audit registry + CI check, one row per write route, append-only and read rules in SQL, cross-shop | unit + SQL + integration | see `docs/testing/plans/B11.md` (client: EcoFin-Web B11-web.md) | see B11.md | see B11.md | src/routes/audit*.test.ts, src/test/audit-registry/*, supabase/tests/f07_audit_test.sql | passing now (local) |
| Q02 | Q02-01…08 | Monitoring: test error in the tracker with its request id; 5xx reported (4xx not); off without a DSN; privacy scrubbing; dead jobs and ledger mismatches alert; test route safe across shops; uptime monitors | unit + integration + manual | see `docs/testing/plans/Q02.md` (client: EcoFin-Web Q02-web.md) | see Q02.md | see Q02.md | src/utils/monitoring.test.ts, src/middleware/errorHandler.monitoring.test.ts | passing now (local) / manual after keys |
| F14 | F14-01…17 | File storage (EC-33): a file URL expires; another shop's file is not found (task: 404, slice says 403); upload checks (size, magic-byte type, purpose permission, entity shop); failed metadata write leaves no object; `register_file` SQL; D19 route checks | route + unit + SQL + integration | see `docs/testing/plans/F14.md` | see F14.md | see F14.md | src/services/files.*.test.ts, src/routes/files*.test.ts, supabase/tests/f14_files_test.sql, packages/contracts/src/files.test.ts | unit, route, SQL and integration passing (integration and SQL on local stack, 5 Oct 2026) |
| F13 | F13-01…09 | Background jobs: a failing job retries then lands in the failed list; a daily job runs once per shop per day with two server instances; claim/succeed/fail/dead rules, shop time zones, access, worker logs | SQL + unit + integration | see `docs/testing/plans/F13.md` | see F13.md | see F13.md | supabase/tests/f13_jobs_test.sql, src/jobs/*.test.ts | passing now (local) |
| F10 | F10-01…11 | Ledger core: 100 parallel sales of the last 10 units sell exactly 10; one idempotency key from 50 parallel requests changes things once; reconciliation after the full suite; on hand / cash = ledger sums, no overselling, append-only, reverse once, caches only via the ledger | SQL + pgbench | see `docs/testing/plans/F10.md` | see F10.md | see F10.md | supabase/tests/f10_ledger_test.sql, scripts/db-ledger-proof.mjs, scripts/db-reconcile.mjs | passing now (local) |
| F11 | F11-01…08 | Document numbering: 1,000 concurrent creations (pgbench, with rollbacks) give 1,000 unique, ordered, gap-free numbers; format, separate sequences per shop/branch/type/year, rollback reuse, other shop refused, no direct access | SQL + pgbench | see `docs/testing/plans/F11.md` | see F11.md | see F11.md | supabase/tests/f11_numbering_test.sql, scripts/db-numbering-proof.mjs | passing now (local) |
| F12 | F12-01…12 | Money and tax utilities (contracts 0.4.0): exact splits (1000 / 3) and proportional allocation, half-up rounding, tax-inclusive and exclusive conversions, line-level rounding rule, EGP formatting AR/EN | unit | see `docs/testing/plans/F12.md` | see F12.md | see F12.md | packages/contracts/src/money.test.ts | passing now |
| F04 | B6-40 | Local JWT expiry 15 min and reset link to the web page (D24) | manual | stack restarted after the config change | curl password grant; forgot-password; read the Mailpit message | `expires_in: 900`; link has `redirect_to=http://localhost:5173/reset-password` | n.a. (supabase/config.toml) | manual (observed) |
| F04 | B7-19 | e2e: expired access token, refresh runs, the NEW token works | e2e | RUN_E2E=1, API + Supabase running, seeded owner | `... -g "expired access token"` | /api/auth/refresh returns 200; stored token replaced; `GET /api/auth/me` with the new token and orgId returns 200 (old-token rejection not asserted: the contract does not promise rotation) | e2e/auth.spec.ts: expired access token: the silent refresh runs and the NEW token works on /me | written-skipped |
| F04 | B7-19b | e2e: 401 path, exactly one refresh, retried call succeeds | e2e | as above | `... -g "401 path"` | garbage token + future expiry; two parallel calls through the app's api client both return 200; exactly 1 refresh request | e2e/auth.spec.ts: 401 path: a garbage token with a future expiry... | written-skipped |
| F04 | B7-20 | e2e: log out, the old token returns 401 | e2e | as above | `... -g "log out"` | logout call ok, redirect to /login, GET /api/auth/me with the old token returns 401 | e2e/auth.spec.ts: log out, then the old token is rejected with 401 | written-skipped |
| F04 | B7-21 | e2e: forgot password, Mailpit, reset, log in | e2e | as above, dedicated reset user (E2E_RESET_*), Mailpit on :54324, `site_url` points at the dev server | `... -g "forgot password"` | same message shown; email link opens the reset page; new password saved; login with it works; the original password is restored through /api/auth/change-password | e2e/auth.spec.ts: forgot password, Mailpit email, reset page, new password, log in | written-skipped |
| F04 | B7-22 | e2e: one login, two shops, picker | e2e | as above, seeded two-shop user | `... -g "two shops"` | lands on /select-shop; choosing a shop opens /dashboard with orgId stored | e2e/auth.spec.ts: one login with two shops sees the picker | written-skipped |
| F04 | B7-23 | e2e: activation routes removed | e2e | as above | `... -g "activation routes"` | both paths end on /login | e2e/auth.spec.ts: the removed activation routes land on the login page | written-skipped |
| F04 | B7-24 | Manual: walk login, picker, forgot and reset in Arabic (RTL) and English | manual | dev server + API; English needs the F09 language switch | open /login, /select-shop, /forgot-password, /reset-password in each language | layout mirrors correctly, no clipped text, messages readable | n/a | manual (no Playwright MCP) |
| F08 | B5-17 | `/health` against local Supabase | integration | `RUN_INTEGRATION=1`, local Supabase running, env vars set | `GET /health` | 200, `db:'ok'` | src/controllers/health.integration.test.ts | written-skipped |
| F08 | B5-23 | Missing env var stops the server clearly | manual | server can start (not possible on this machine now); no `SUPABASE_URL` in env or `.env` | `npm run dev` | process exits with code 1, log line `Invalid environment configuration. Fix these variables: SUPABASE_URL (missing)`, no values printed | manual | manual |
| F09 | B9-18 | No hard-coded UI strings in touched files | manual | none | grep touched `.tsx` for Arabic letters outside tests and `DesignSystemPage` | none found | n/a | manual (done) |
| F09 | B9-19 | typecheck, lint, format:check, test, build | manual | none | `npm run typecheck && npm run lint && npm run format:check && npm test && npm run build` | all pass (see summary for the 3 known D23 errors) | n/a | manual |
| F09 | B9-20 | e2e: switch AR and EN on the sample page, layout mirrors, strings change, choice survives reload | e2e | `RUN_E2E=1`, owner seed user, dev server | `npx playwright test e2e/shell.spec.ts` | `lang`/`dir` flip, heading changes, sidebar moves from right to left | `e2e/shell.spec.ts: the sample page switches Arabic <-> English and the layout mirrors` | written-skipped |
| F09 | B9-21 | e2e: cashier types the URL of an `audit.view` page, sees 403 | e2e | `RUN_E2E=1`, cashier seed user | open `/sample/restricted` after login | 403 text visible; page text absent; URL unchanged | `e2e/shell.spec.ts: a cashier typing the URL ...` | written-skipped |
| F09 | B9-22 | e2e: owner opens the same page | e2e | `RUN_E2E=1`, owner seed user | open `/sample/restricted` | page heading visible | `e2e/shell.spec.ts: an owner opens the same page` | written-skipped |
| F09 | B9-23 | Manual: visual check of RTL/LTR and the mobile sidebar | manual | dev server, browser at 360, 768, 1280 px | open `/sample` in AR and EN; open the menu at 360 px; open the branch and language controls | layout mirrors, no overflow, drawer opens from the start edge, 44 px targets | n/a (no Playwright MCP) | manual |

| INT-1 | INT1-a | Owner A logs in through the UI, lands in shop A, sees every menu | manual (Playwright MCP) | both apps + local stack, seeded owner.one | log in at /login; open the menu | /dashboard, branch "Shop One Main", 11 top-level menus (AR and EN) | EcoFin-Web test-results/int-1/a-owner-a-*.png (not committed) | passing (local, 5 Oct 2026) |
| INT-1 | INT1-b | Cashier A sees only allowed menus; typing a guarded URL is blocked | manual + unit + e2e | as above, cashier.one | log in; open the menu; type /audit, /settings, /employees | menu: Dashboard, Sales, Customers; each typed URL shows the 403 page | EcoFin-Web src/components/guards/RequireNavItem.test.tsx; e2e/shell.spec.ts, e2e/audit.spec.ts | passing (fixed in INT-1: menu-item routes were unguarded) |
| INT-1 | INT1-c | Two-shop login gets the picker; switching shop changes data (`x-org-id`) | manual + API + e2e | as above, multi.shop | log in; pick Dev Shop Two; open /select-shop; pick Dev Shop One | picker lists both shops with roles; requests carry the chosen `x-org-id`; role, permissions and branch change (ACCOUNTANT/BR1 shop two -> CASHIER/BR1 shop one) | docs/testing/int-1/api-checks.log [c]; e2e/auth.spec.ts "one login with two shops" | passing (no in-app switch link: open bug) |
| INT-1 | INT1-d | Cross-shop through the API: shop B ids from shop A -> 403/404, nothing leaks | API (live) | API on :3001 + local stack | see `scripts`: docs/testing/int-1/api-checks.log | x-org-id B -> 403 SHOP_NOT_ALLOWED; shop B employee -> 403/404 with no B data; shop B branch refused exactly like a non-existent one (422 BRANCH_NOT_IN_ORG); audit search/list show no shop B rows | docs/testing/int-1/api-checks.log [d] | passing (local, 5 Oct 2026) |
| INT-1 | INT1-e | One write -> exactly one audit_log row with employee, request id and IP | API (live) + integration | as above | PUT /api/employees/:id/permissions with x-request-id | 200; one row: employee owner.one, request id, client IP, shop A | api-checks.log [e]; src/routes/audit.integration.test.ts | passing |
| INT-1 | INT1-f | Logout kills the old token; silent refresh works; forgot-password email in Mailpit and reset page changes the password | API (live) + UI + e2e | as above, Mailpit :54324 | logout in UI then call /me with the old token; corrupt the stored access token and open /audit; e2e forgot/reset | 401 TOKEN_INVALID; 401 -> refresh -> page loads with a new token; reset flow passes | api-checks.log [f]; test-results/int-1/f-silent-refresh-audit-en.png; e2e/auth.spec.ts | passing |
| INT-1 | INT1-g | Owner deactivates cashier A -> the cashier's next request is rejected | API (live) | as above | set employees.is_active=false (no deactivate endpoint yet), call /me with the live token, log in again, re-enable | 403 ACCOUNT_DISABLED on the live token and on a new login | api-checks.log [g]; src/routes/auth.sessions.integration.test.ts | passing (deactivation done in the DB: no endpoint yet) |
| INT-1 | INT1-h | Arabic (RTL) and English for a, b, c | manual (Playwright MCP) | as above | switch language on each screen | dir/lang switch; no untranslated strings (only the "العربية" switch label and data like shop names stay as is) | test-results/int-1/*-ar.png, *-en.png | passing |
| INT-1 | INT1-i | CI runs these suites on a pull request | manual (config read) | n.a. | read .github/workflows/ci.yml in both repos | API: check + db jobs (SQL tests, full RUN_INTEGRATION suite); Web: typecheck, lint, format, test, build. Skipped by CI: Web e2e (RUN_E2E), API f14_files_test.sql | both ci.yml | passing with gaps (see INT-1 REPORT) |
| TEST-1 | T1-01…19 | Foundation security and ledger (EC-128): generic catalog guards (anon, table writes, RLS + SELECT policy, definer search_path, permission call in every callable function), cross-tenant read over every table and view as both shops, cross-tenant writes and a permission denial for every write function, ledger invariants over the whole DB (also as service_role), reversal once, idempotency, money rounding cases, F14 across shops with real data and the user's own token; CI runs every SQL file and a separate integration job | SQL + unit + integration + CI | see `docs/testing/plans/TEST-1.md` | see TEST-1.md | see TEST-1.md | supabase/tests/security_guards_test.sql, tenant_and_permission_test.sql, ledger_invariants_test.sql; packages/contracts/src/money.test.ts; src/routes/files.cross-shop.integration.test.ts | passing (local, 6 Oct 2026); 1 known bug marked (register_file entity shop) |
| EC-142 / EC-143 | EC142-01…04, EC143-01…05 | register_file refuses another shop's record, an unknown entity type, an id without a type (own record still works); deactivate / reactivate an employee: refusals (permission, reason, owner, self, other shop), one audit row each, the live token refused at once, the session back after reactivating | SQL + integration | `db:reset`; local stack | `npm run db:smoke -- supabase/tests/tenant_and_permission_test.sql` (3.6–3.10, 4.x) and `supabase/tests/ec143_employee_active_test.sql`; `RUN_INTEGRATION=1 npx vitest run src/routes/files.cross-shop.integration.test.ts src/routes/employees.integration.test.ts` | as described | tenant_and_permission_test.sql, ec143_employee_active_test.sql, files.cross-shop.integration.test.ts, employees.integration.test.ts "EC-143: …", cross-shop/cases.ts `PUT /api/employees/:employeeId/active`, audit.integration.test.ts driver | passing (local, 6 Oct 2026) |

## Totals

| Story | Passing now | Written-skipped | Manual |
|---|---|---|---|
| F01 | 6 | 2 | 10 |
| F02 | 14 | 0 | 1 |
| F03 | 11 | 0 | 2 |
| F04 | 33 | 8 | 2 |
| F08 | 23 | 1 | 1 |
| F09 | 15 | 3 | 2 |
| **Overall** | **102** | **14** | **18** |

## Gaps

**F01 (B1 server, B2 client):** None. All security rules and done-when items are covered in the tooling checks.

**F02 (B3 database):** None. All migration, seed, smoke test and RLS rule checks are in the plans.

**F03 (B4 contracts):** None. All permission keys, roles, error codes and schema checks are covered.

**F04 (B6 API auth, B7 Web auth):** closed 4 Oct 2026.
- Login audit for an unknown username, or another shop's username with this shop's slug: B6-41 (`login_attempts` row, no `audit_log` row, same 401 as a wrong password).
- Session revocation on a change to the employee: there is no permissions admin yet, but every request re-reads the employee (F05 `session_context()`), so a role change applies on the next request and disabling or archiving ends live sessions at once, refresh included: B6-42…44. Permission overrides themselves are F06's to test.
- Refresh immediately after revocation (logout, change-password): B6-45, B6-46.

**F09 (B9 UI shell):** closed 4 Oct 2026 (EcoFin-Web `e2e/rtl.spec.ts`, plan B9-24…27).
- Long Arabic text (mixed digits and Latin) in shop and branch names at 360 and 1280 px: wraps or truncates, never overflows (B9-24, B9-25).
- Links in RTL: the forgot-password link and the sidebar links mirror and keep their style (B9-26, B9-27).
- Language choice surviving a reload: already covered by B9-20 (passing locally).
- The walkthrough (B7-24, B9-23) found the top bar overflowing below ~720 px and dropdowns wider than a phone screen with long names; both fixed in EcoFin-Web.

**B9-21 and B9-22** (the 403 guard) pass since F06 serves `GET /api/me/permissions` (local run, 4 Oct).

## 4 Oct 2026 run (local stack)
- API: `RUN_INTEGRATION=1` full suite 290/290; SQL smoke 79/0, f04 48/0, f05 41/0. CI `db` job now runs the SQL tests and the integration suites on every PR.
- Web: e2e 15 passed, 2 failing by design until F06 (B9-21/22); unit 93/93.

## Deferred stories

**F05 (B8):** `docs/testing/plans/B8.md`. **F06 (B10):** `docs/testing/plans/B10.md` + EcoFin-Web `B10-web.md`. **F07 (B11):** `docs/testing/plans/B11.md` + EcoFin-Web `B11-web.md`. **F10:** `docs/testing/plans/F10.md`. **F13:** `docs/testing/plans/F13.md`. **Q02:** `docs/testing/plans/Q02.md` + EcoFin-Web `Q02-web.md`. **F11:** `docs/testing/plans/F11.md`. **F12:** `docs/testing/plans/F12.md`. **F14:** `docs/testing/plans/F14.md`.
## P01 shop provisioning

See [P01 plan](plans/P01.md) for SQL, unit, integration and Web coverage; final results in [P01 report](reports/P01_report.md).

## P05 subscription plans and limits

See [P05 plan](plans/P05.md) and [P05 report](reports/P05_report.md).

## O01 — branches

See [O01 plan](plans/O01.md).

## O02 — employees (EC-41 / EC-143 part 2)

See [O02 plan](plans/O02.md) and [O02 report](reports/O02_report.md). Covers immediate session refusal after deactivation and permission changes on the next request.

## P03 — shop settings (EC-36)

See [P03 plan](plans/P03.md). Covers the "Done when" (discount cap and installment policy change the behaviour they control) and the FinTech-Pro rules kept in D40.

## P04 — legal and financing profile (EC-37)

See [P04 plan](plans/P04.md). Covers the installment switch on contracts and the creditor stored on every contract (D43).

## C02 — products (EC-43)

See [C02 plan](plans/C02.md). Covers the slice's Done when (created, found by barcode through the POS lookup, archived, still shown in old sales) and the D44 rules.

## C03 — barcode labels (EC-44)

See [C03 plan](plans/C03.md). Covers the units-by-serial read and the scan check of a printed label (D45).

## TEST-2 — shop setup tests (EC-130)

See [TEST-2 plan](plans/TEST-2.md): each Sprint 2 test requirement mapped to the CI test that proves it (roles, extra permissions, deactivation, plan limits, VAT golden cases, old documents, ar/en setup walk).

## I01 — stock view (EC-47)

See [I01 plan](plans/I01.md). Covers the Done when (every number equals its ledger sum, for every product and branch) and the D47 rules.

## I02 — stock adjustments and counts (EC-48)

See [I02 plan](plans/I02.md). Covers the Done when (a posted count makes the stock equal the counted numbers and leaves ledger entries with the reason) and the D48 rules.

## I03 — branch transfers (EC-49)

See [I03 plan](plans/I03.md). Covers the Done when (stock is never counted in both branches or in neither; in-transit stock shows in I01) and the D49 rules.

## I04 — serial/IMEI units (EC-50)

See [I04 plan](plans/I04.md). Covers the Done when (a duplicate serial is rejected; a unit that isn't in stock in that branch can't be sold; a unit's history shows every step) and the D50 rules.

## I05 — movement history (EC-51)

See [I05 plan](plans/I05.md). Covers the Done when (every movement links to the document that caused it) and the D51 rules (filters, running balance, export.data, the 10 000-row limit, audit).

## I06 — low-stock alerts (EC-52)

See [I06 plan](plans/I06.md). Covers the Done when (a product below its min level appears in the low list and on the dashboard) and the D52 rules (per-branch levels, archived products and deactivated branches never low).

## U01 — suppliers (EC-53)

See [U01 plan](plans/U01.md). Covers the Done when (the statement balance equals invoices − payments − returns, and equals `v_supplier_balances`) and the D53 rules (active-only uniqueness of name and phone, no archive with a balance or open documents, who may read, shop-wide statements).

## U02 — purchase invoices (EC-54)

See [U02 plan](plans/U02.md). Covers the Done when (approving a multi-line invoice adds each quantity exactly once, the moving-average cost is right, the supplier balance rises by the total) and the D54 rules (net cost before VAT, approve once, drafts only, serials, current tax rates at approval).

## U06 — purchase approval by amount (EC-58)

See [U06 plan](plans/U06.md). Covers the Done when (a user below the owner can't approve a large invoice; the approval list shows the waiting invoices) and the D55 rules (strictly greater, total with VAT, owner note, pending stays pending, one pending approval per invoice).

## K01 — vaults (EC-59)
See [K01 plan](plans/K01.md). Covers the Done when (a transfer changes both balances once; the ledger view adds up to the balance) and the D56 rules (safes and banks only, one opening balance, source-branch access, default vault and balance guards).

## U03 — supplier payments (EC-55)
See [U03 plan](plans/U03.md). Covers the Done when (a double-click pays once; invoice and supplier balances update) and the D58 rules (fully allocated, oldest first, never above the outstanding, safe not below 0, owner-only reversal).

## K03 — expenses (EC-61)
See [K03 plan](plans/K03.md). Covers the Done when (an expense reduces the vault balance; a shift expense reduces the shift's expected cash) and the D61 rules (a vault or the open shift, categories, receipt, no edit or delete, owner-only reversal once, the report by category).

## K02 — shifts / cash drawer (EC-60)
See [K02 plan](plans/K02.md). Covers the Done when (expected cash = float + drawer ledger sum, not the whole vault; a closed shift can't take sales) and the D60 rules (one open shift per cashier and device, floats and drops as cash transfers, count by denomination, a difference needs a reason, takeover with cash.transfer).

## U05 — purchase orders (EC-57)
See [U05 plan](plans/U05.md). Covers the Done when (receiving part of an order leaves the rest open; a special customer order shows its purchase order status) and the D59 rules (received means approved, no over-receipt, statuses, cancel with a reason, U02/U06 unchanged).

## U04 — purchase returns (EC-56)
See [U04 plan](plans/U04.md). Covers the Done when (stock and supplier balance each change exactly once; you can't return more than you bought) and the D57 rules (approved invoices only, the invoice's branch, exact serial units, D41 tax, recomputed average, credit or cash refund).

## INT-3 — stock and cash end to end (EC-131)

See [INT-3 plan](plans/INT-3.md): one flow in a fresh shop, purchase order → invoice with IMEI units → payment from the safe → return → branch transfer → adjustment → shift with an expense, with the stock view, movement history, low-stock alert, supplier balance and safe checked at every step.

## TEST-3 — stock and cash reconciliation tests (EC-132)

See [TEST-3 plan](plans/TEST-3.md): each Sprint 3 test requirement mapped to the CI test that proves it (levels and balances equal their ledgers and never go below zero, two requests for the last unit or the last pound, IMEI units in one place and sold once, approval by amount).

## S01 — sale core (EC-68)

See [S01 plan](plans/S01.md). Covers the Done when (the four ledger / reconciliation checks, a double submit creates one sale, the last unit can't be sold twice) and the D62 rules (the open shift, server prices and overrides, PRICE_CHANGED, the tax snapshot in both VAT modes, IMEI units, every refusal leaving nothing behind, who may sell and read).
## R01 — customers (EC-63)

See [R01 plan](plans/R01.md). Covers the Done when (a user without `customer.view_pii` sees masked IDs; duplicate national IDs are rejected) and the D62 rules (the national ID parser, birth date and gender from the ID, who may change an ID, phones, block with a reason, who may read, search by name, phone and ID, the `customers` module).

## R02 — customer account (EC-64)

See [R02 plan](plans/R02.md). Covers the Done when (the open balance equals contract totals − payments − returns) and the D74 rules (contract total after a reschedule, fees kept apart, overdue and aging, the account, the schedule, the statement and its closing check, who may, the 3 routes).

## R03 — credit profile and limit (EC-65)

See [R03 plan](plans/R03.md). Covers the Done when (the server blocks an installment sale over the limit even if the client sends it directly) and the D72 rules (the explicit limit and its history, exposure, the score and the behaviour, the check and its errors, exceptions as approvals on the spot, the commit-time trigger, the preview, who may, the 8 routes).

## R04 — guarantors (EC-66)

See [R04 plan](plans/R04.md). Covers the Done when (editing a customer never deletes their guarantors; a contract that needs a guarantor can't be created without one, whoever writes it) and the D71 rules (national ID and masking as customers, who may, links and limits, archive, the policy count, the contract helpers and the commit-time trigger, ID photos, the 11 routes).

## R05 — field surveys (EC-67)

See [R05 plan](plans/R05.md). Covers the Done when (photos are private; a required survey blocks the installment sale until approved, whoever writes the contract) and the D75 rules (assign / save / submit / decide / reassign / cancel, the answers' validation, photos tied to an assigned survey of the caller, who may and the collector who sees only their own, the residence part of the credit score and the profile's latest survey, the requirement read, the 10 routes).

## N01 — installment rules engine (EC-80)

See [N01 plan](plans/N01.md). Covers the Done when (schedule lines always sum to the total payable; changing the policy changes new contracts only; the server rejects terms that break the policy) and the D76 rules (the 35 golden cases run by both engines, a generated sweep, the eight policy rules, the confirm side for N02, the two commit-time triggers, the preview and who may call it).

## N02 — installment sale and contract (EC-81)

See [N02 plan](plans/N02.md). Covers the Done when (the contract total = cash price − down payment + markup; the down payment is in the drawer; the contract shows on the customer account) and the D77 rules (one transaction, every refusal leaves nothing, the customer checks, credit exceptions, guarantors and surveys, payment methods, zero down payment, idempotency, never edited, the contract read).

## N03 — collections (EC-82)

See [N03 plan](plans/N03.md). Covers the Done when (the same allocation for the same inputs; a double-click records one payment; the last payment closes the contract; a same-day reversal leaves the contract as it was) and the D78 rules (oldest line first, profit then principal; several contracts and split methods in one receipt; no overpayment and no store credit; no late fees; any branch; completion; reversal; visibility; the four concurrency rounds).

## S02 — split payments (EC-69)

See [S02 plan](plans/S02.md). Covers the Done when (a sale paid half cash, half bank transfer posts each amount to the right place and the shift shows both) and the D64 rules (exact total, cash with change, bank reference, store credit, nothing left behind on a refusal, names-only account list, replays).

## S03 — discounts (EC-70)

See [S03 plan](plans/S03.md). Covers the Done when (a cashier can't exceed their cap through the API; the tax on a discounted sale is correct) and the D65 rules (line discount then sale discount spread by largest remainder, a per-line effective cap, the on-the-spot approval as a single-use 15-minute request bound to a server-side cart fingerprint).

## S07 ? sales history and void (EC-74)

See [S07 plan](plans/S07.md): accessible-branch history, immutable full stock/cash/tax reversal, rules, fiscal cancellation, idempotency and concurrent voids.

## S12 - Warranty

See [S12 plan](plans/S12.md): dates/backfill, out-of-warranty decisions, serial chains, transitions, photos, ledger invariants, API security and AR/EN receipt verification.

## T02 — ETA e-receipts (EC-90)

See [T02 plan](plans/T02.md). Covers the Done when: (2) a retried submission doesn't create a duplicate (an answer lost after the ETA took the submission, a 422 DuplicateSubmission and a 503 each end with the receipt received once by the fake ETA); (1) acceptance by the ETA pre-production system is `npm run eta:preprod-smoke`, **not run yet: it needs the shop's pre-production credentials** ([setup](../eta/SETUP.md)). And the D67 rules: a fiscal record with every consumer sale, the UUID chain per POS by compare-and-set, blocked receipts, secrets in Vault, the 20-hour alert, the environment guard.


## T03 — ETA submission monitor and corrections (EC-91)

See [T03 plan](plans/T03.md). Covers the Done when: (1) a rejected receipt shows the ETA's reason and, after the fix, is resubmitted as a corrected receipt (a new UUID with `referenceOldUUID`, the original `previousUUID`) and accepted by the fake ETA; (2) a blocked receipt becomes prepared after its data is fixed. And the rules: a rejected receipt is never plainly retried, a correction is a job, the POS head moves only when the rejected receipt was the newest, the event log is append-only, the diagnosis is computed live, deadlines (24 h, 96 h for a correction), bulk retry, the alert counts and the day-close summary.

## O03 — POS devices (EC-146)

See [O03 plan](plans/O03.md). Covers the Done when: (1) a paired POS computer opens a shift and makes a sale whose `device_id` is set and whose ETA receipt is prepared, not `BLOCKED:NO_DEVICE` (O03-I, against a fake ETA; O03-S for the trigger); (2) a revoked device's next request is rejected with `DEVICE_REVOKED` (O03-I, O03-U for the middleware); (3) creating one device over the plan limit fails with `PLAN_LIMIT_REACHED` (O03-S on `starter`, O03-I). And the D69 rules: only hashes are stored, a hand-made `x-device-id` is no device, pairing is rate limited, another shop can do nothing with a device, its code or its token. The plan also lists the shared test helpers that now pair a device before they open a shift.

## INT-4 — cash sale end to end (EC-133)

One flow, server and client together, against the fake ETA (`npm run fake-eta`): `EcoFin-Web/e2e/int4-cash-sale.spec.ts` (one test per check, in order) plus `scripts/int4-verify.mjs` (database, service role, PASS/FAIL per check). Environment: local stack + dev seed (`int4-shop-a`, `int4-shop-b`, [logins](int-4/LOGINS.md)), API with its job worker (`JOBS_POLL_SECONDS=5`), Web dev server; start from a fresh `db reset` and a fresh fake ETA ([ENVIRONMENT](ENVIRONMENT.md#int-4-update-14-oct-2026)). Results: [INT-4 report](int-4/REPORT.md). Staging repeat (real ETA pre-production, POS computer, printer, scanner): [checklist](int-4/STAGING_CHECKLIST.md), done in INT-6.

| Story | ID | Check | Type | Setup | Steps | Expected | Evidence | Status |
|---|---|---|---|---|---|---|---|---|
| INT-4 | INT4-a | Device paired, shift opened with a float on it | e2e + API | owner.a, cashier.a1 | add device, pair code, pair on the cashier's browser, register ETA values, open shift (float 500 from the safe) | header shows the device; `shifts.device_id` = the device, float 500.00 | test-results/int-4/a-*.png | passing (local, 14 Oct 2026) |
| INT-4 | INT4-b | Scan (Enter), serial prompt, 5 % discount | e2e | as a | type barcode + Enter; SKU of the serialized product + Enter; 5 % line discount | line added; "Serials of INT4 Phone"; total 5,950.00 | b-pos-cart.png | passing |
| INT-4 | INT4-c | 8 % over the cap → manager approves in a second context → sale; approval single-use | e2e + DB | manager.a | ask a manager; approve; pay; resend the approval | sale created; `approvals.entity_id` = the sale; reuse → `APPROVAL_INVALID` | c-*.png, int4-verify c | passing |
| INT-4 | INT4-d | Split cash + bank transfer, change, double-click Pay = one sale | e2e + DB | as b | cash 950 (handed 1,000), transfer 5,000 + reference, double-click Pay | change 50.00; one sale for the idempotency key | d-*.png, int4-verify d | passing |
| INT-4 | INT4-e | One transaction: stock, unit, drawer, bank, VAT, number, audit | DB | after d | int4-verify e | stock −qty, unit sold, drawer +950, bank +5,000, tax per T01, next number, audit row | int4-verify e | passing |
| INT-4 | INT4-f | ETA accepted, same UUID at the fake, chained, sent once | DB + fake | after c | wait for the jobs | both accepted; sale 2 `previousUUID` = sale 1 UUID; count per UUID 1; 0 bad hashes | int4-verify f | passing |
| INT-4 | INT4-g | Receipt in Arabic: totals, payments, serial, warranty, UUID/QR; reprint = copy | e2e | AR browser | sale page → Print receipt; print; reprint | all shown; QR present; first print original, second marked COPY | g-receipt-ar.png, g-receipt-ar-reprint.png, g-prints.json (marks `[false, true]`) | passing (after INT4-B1 fix, Web `3b10091`) |
| INT-4 | INT4-h | Rejected (itemCode) → reason in monitor → fix → Correct and resend → accepted | e2e + fake | fake `/admin/invalid-next` | sell; monitor Details; fix code; correct | reason + property shown; accepted with `referenceOldUUID` = old UUID | h-*.png, int4-verify h | passing |
| INT-4 | INT4-i | No ETA code → blocked ITEM_CODE naming the product → set code → Retry → accepted | e2e + DB | INT4-LAMP | sell; Details; set code; Retry | Retry disabled until fixed; product named; accepted | i-*.png, int4-verify i | passing |
| INT-4 | INT4-j | History by serial and number; void with a UUID refused; shop B (ETA off) void puts stock and cash back | e2e + DB | owner.b, cashier.b | search; open sale; void A (UI + API); void B | A: "Use a return", no Void button, API 4xx; B: voided, stock and cash net 0 | j-*.png, int4-verify j | passing |
| INT-4 | INT4-k | Warranty claim → replace with another serial; chain on both serials; damaged +1, sellable −1 | e2e + DB | serials of the run | lookup; open claim; replace | Replaced; both lookups show the history | k-*.png, int4-verify k | passing |
| INT-4 | INT4-l | Cashier: no ETA monitor menu, `/api/fiscal` 403; shop B: shop A sale, receipt print, fiscal row 404 | API | cashier.a1, owner.b | API calls | 403 / 404 | spec l | passing |
| INT-4 | INT4-m | Last unit, two devices in parallel: one sale, one OUT_OF_STOCK | API + DB | cashier.a2 on device 2 | two parallel POST /api/sales | one 201, one 409 OUT_OF_STOCK; one sale line, sellable 0 | m-responses.json, int4-verify m | passing |
| INT-4 | INT4-n | POS, receipt, monitor, warranty in AR (RTL) and EN (LTR), no raw keys | e2e | both languages | open each page | `dir` right; no raw i18n key text; no missing-key console warnings | n-*-ar.png, n-*-en.png | passing |
| INT-4 | INT4-o | Reconciliation; day summary counts every receipt, `all_accepted` right | script + API | end of run | db-reconcile; GET /api/fiscal/day-summary | reconcile passed; total = receipts, all_accepted true once none waits | int4-verify.txt | passing |
| INT-4 | INT4-p | CI runs the suites on pull requests and includes the new spec | config read | n.a. | read both ci.yml | API check/db/integration and Web check/e2e on `pull_request`; Web e2e now starts the fake ETA | REPORT.md §p | passing with gaps (see report) |


TEST-4 sales tests (EC-134): [coverage, CI jobs and known failures](plans/TEST-4.md).

- [EC-147: revoked shift device](plans/EC-147.md) — device checks and manager force-close; local verification in progress.

## N04 — overdue tracking, no late fees (EC-83)

See [N04 plan](plans/N04.md). Covers the Done when (a late customer's total owed never changes; running the job twice in a day changes nothing; a policy can't be saved with a late fee; a banned customer can't buy on installments) and the D79 rules (grace; warning cadence; ban lifted only by hand; legal referral kept until handled; lists and access).

## N05 — early settlement, rescheduling, write-off (EC-84)

See [N05 plan](plans/N05.md). Covers the Done when (the old schedule is still visible after a reschedule; the customer balance after each action is correct) and the D80 rules (rule 5 safety net, waiver limits, owner-only write-off, the reversal guard, statement rows, idempotency, access).

## N06 — collector wallets (EC-85)

See [N06 plan](plans/N06.md). Covers the Done when (a field collection is counted once, in the wallet, until settled; the wallet balance equals its ledger) and the D81 rules (no commission, assignment and who may collect, partial settlement with a recorded shortage, reversal while the cash is in the wallet, route, overdue filter, access and isolation).

## N07 — printed contract and promissory notes (EC-86)

See [N07 plan](plans/N07.md). Covers the Done when (the paper matches the contract exactly; the notes sum to what is left; rules on paper; original then COPY, a reschedule starts an original; access and isolation) and the D82 rules.

## INT-5 — installment lifecycle end to end (EC-135)

See [INT-5 report](int-5/REPORT.md): one flow in a fresh shop through the screens (customer, guarantor, field survey, credit limit, installment sale, printed contract and notes, field collection into the collector's wallet, settlement into the safe, early settlement, an overdue installment that gets a warning and never a fee, the customer account in English and Arabic), with the database checks in `scripts/int5-db.mjs verify`. Spec: EcoFin-Web `e2e/int5-installment-lifecycle.spec.ts`.

## TEST-5 — installment money tests (EC-136)

See [TEST-5 plan](plans/TEST-5.md): schedules that add up over 108 real sales, the allocation order (no late fees: oldest installment, profit then principal), a late installment that never costs more, the credit limit enforced by the server with nothing written on a refusal, a new policy for new contracts only, and the collector wallet equal to its ledger after a mixed day. New: `supabase/tests/test5_installment_money_test.sql` and one case in `src/routes/contracts.integration.test.ts`.

## M02 — opening balances (EC-101)

See [M02 plan](plans/M02.md). Covers the Done when (the system's open debt equals the signed total from the old records; a wrong total is refused; nothing migrated touches the cash or stock ledgers except the opening cash; a bad file saves nothing; a re-import never duplicates; a batch is reversible only before collections and sign-off) and the D85 rules.

## M03 — full export (EC-102)

See [M03 plan](plans/M03.md). Covers the Done when (the export restores into a clean environment with matching totals; every tenant table is in the export or deliberately excluded with a reason; no secret column leaves the database; national IDs masked unless `customer.view_pii`; no cell can run a formula, Arabic opens correctly; a big shop is paged and streamed, not loaded; every export audited; `export.data` works in an expired shop) and the D86 rules.

## K04 — day close and reconciliation (EC-62)

See [K04 plan](plans/K04.md). Covers the Done when (the day-close numbers equal the sum of the day's documents; a broken balance is flagged by the preview, the stored issues and the nightly check) and the D84 rules (an open shift blocks, the hash, a note with warnings, a closed day refuses entries for its branch only, reopen and close again, drift, access and isolation).

## D01 — owner dashboard (EC-93)

See [D01 plan](plans/D01.md). Covers the Done when (every number on the dashboard equals its detailed report for the same filters, for all branches and for each branch; each tile links to its page already filtered; a caller sees only the tiles they can open; the read answers in under 300 ms on the seed shop) and the D87 rules.

## S05 — returns and exchanges (EC-72)

See [S05 plan](plans/S05.md). Covers the Done when (returning one item of an installment sale after two payments gives the right remaining debt; stock, cash and tax each change once) and the D88 rules (amounts from the stored line, the exact serial, refund caps, the period and its owner override, warranty refunds, exchanges, the ETA return receipt, R02's balance, concurrency).

## D02 — sales and margin report (EC-94)

See [D02 plan](plans/D02.md). Covers the Done when (the report's totals match the sales and returns documents of the period for every grouping; every grouping and filter works; cost and margin only with `report.financial`; another shop's data is never reachable) and the D89 rules.

## D03 — receivables aging (EC-95)

See [D03 plan](plans/D03.md). Covers the Done when (the total equals the sum of the open contract balances; by customer, branch and collector, the five buckets, principal and profit, drill-down to contracts; only `report.financial`; another shop's data is never reachable) and the D90 rules.
