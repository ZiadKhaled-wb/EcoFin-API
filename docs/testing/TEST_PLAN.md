# Sprint 1 test plan (F01–F09)

**Date:** 3 Oct 2026  
**Coverage:** Features F01 (tooling), F02 (database), F03 (contracts), F04 (auth), F08 (server basics), F09 (UI shell)  
**Source plans:** EcoFin-API `docs/testing/plans/B1.md`, `B3.md`, `B5.md`, `B6.md`; EcoFin-Web `docs/testing/plans/B2.md`, `B7.md`, `B9.md`; contracts `packages/contracts/docs/testing/plans/B4.md`

## How to run when the environment is fixed

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
  npx vitest run
# Expected: B5 health integration (1) and B6 auth integration (12) tests pass
```

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

**F04 (B6 API auth, B7 Web auth):**
- Login audit: "login with username that doesn't exist in the shop" (cross-shop security check, mentioned in B6-03 but no explicit row for the audit behavior)
- Session revocation on permission change: audit row written, but "when do permissions change?" is not addressed (out of scope for F04; depends on future admin/config features)
- Refresh token reuse window: the 11-second wait in B6-25 tests the behavior but does not cover edge cases like "refresh immediately after revocation" (integration test sufficient)

**F08 (B5 server basics):** None. All error codes, validation, helmet headers, CORS, rate limiting and health checks are covered.

**F09 (B9 UI shell):**
- Language switch persistence across browser restart (tested in B9-12 with localStorage, but no e2e reload test beyond B9-20's "choice survives reload")
- RTL/LTR with long Arabic text and edge cases like numbers, links in lists (visual check B9-23, but no automated row for text overflow or link color in RTL)

## Deferred stories

**F05 (B8), F06 (B10), F07 (B11):** Test plans not written. These stories are deferred to a later run.
