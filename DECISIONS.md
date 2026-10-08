# Decisions (server repo)

### D42. Category filters include one level of children
Category-aware product queries use `category_id = ANY(app.category_with_children(org, category_id))`.
The helper is tenant-scoped and returns the requested category plus its direct children only.

Decisions taken during Sprint 1 that the docs don't already settle. Newest last. Each one is the simplest option that follows the docs.

## Sprint 1 (3 Oct 2026)

### D1. Contracts package lives in a third repo `EcoFin-Contracts/` (decided by the team)
- Package `@ziadkhaled-wb/contracts`, built with `tsc`, version `0.1.0`.
- Both repos depend on it with `"@ziadkhaled-wb/contracts": "file:../EcoFin-Contracts"` **for now**.
- **Before merging Sprint 1 to `main`:** create the GitHub repo `EcoFin-Contracts`, push it, tag `v0.1.0`, and switch both repos to `"github:<owner>/EcoFin-Contracts#v0.1.0"`. Until then **GitHub CI can't install this repo**, because `../EcoFin-Contracts` doesn't exist on the runner.
- The new repo has no `main` yet. Its first commit is on `integration/sprint-1`; `main` is created when you publish it.

### D2. Writes go through SECURITY DEFINER functions (decided by the team)
`ecotech-build` rule 11. The API never writes tables directly.

### D3. The partner's existing auth code is reviewed and reused where it passes the rules (decided by the team)

### D4. Worktrees are created by the master with `git worktree add`, as siblings of the repos
The Agent tool's built-in worktree isolation would branch the wrong repository (the workspace folder sits inside a home-directory git repo). So the master creates `EcoFine/wt-<agent>` with `git worktree add -b feat/<id>-<slug> ... integration/sprint-1` and hands each builder its path. The worktrees sit next to the repos so `file:../EcoFin-Contracts` resolves the same way in a worktree as in the repo. Worktrees are removed after merge.

### D5. Sprint 1 contracts cover every Sprint 1 endpoint up front
F03 (contracts 0.1.0) defines the schemas for F04 auth, F06 my-permissions / permission override / branch assignment, F07 audit search and F08 health. Later Sprint 1 builders don't change the contracts package. If one finds a schema missing, it stops and reports, and the master adds the schema. This keeps one version, `0.1.0`, for the tag in D1.

### D6. F08 starts after F03 is merged (still inside wave 1)
F08's error handler must return the F03 error shape. Building it in parallel would need a stand-in, which the rules forbid. F02 and F03 run in parallel. F08 is cut from `integration/sprint-1` once F03 is merged. Wave 2 still waits for all three.

### D7. Shared-file ownership per wave (API repo)
| Wave | `package.json` + lockfile | `.github/workflows/*` | `src/app.ts` / route wiring | `.env.example` |
|---|---|---|---|---|
| 0 | B1 | B1 | B1 | B1 |
| 1 | B3 | B3 | B5 | B5 |
| 2 | B6 | B6 | B6 | B6 |
| 3 | B8 | B8 | B8 | B8 |
| 4 | B10 | B10 | B10 | B10 |
The master adds the contracts dependency at F03 merge. Non-owners install with `--no-save` and list what they need.

### D8. Reserved migration timestamps (new migrations only, baseline never edited)
`20261003060000` F04 · `20261003080000` F05 · `20261003100000` F06 · `20261003110000` F07. A task that doesn't need its slot leaves it unused.

### D9. Local Supabase CLI runs through `npx supabase@2.119.0`
It isn't installed globally. Scripts use `npx supabase ...` (or a pinned `supabase` devDependency if F02 chooses one).

### D10. Node network workaround on the dev machine
`NODE_OPTIONS=--no-network-family-autoselection` is needed for npm and Node network calls on this machine. It's machine-specific, so it goes in `docs/testing/ENVIRONMENT.md` and not in the scripts.

### D12. One-time Prettier reformat when F01 lands (both repos)
Prettier settings are the same in both repos: `{ singleQuote, semi, trailingComma: "all", printWidth: 100, endOfLine: "lf" }` with the default 2-space indent. The server code was 4-space, so F01 reformats every server source file once, with no logic change. `.gitattributes` (`* text=auto eol=lf`) stops Windows `core.autocrlf` from breaking `format:check`. Branches cut before F01 must rebase and run `npm run format`.

### D13. typescript-eslint `no-unsafe-*` rules stay off for now
They give about 55 errors that come from the untyped Supabase client in the old auth code. F01 turns on the safe type-aware rules (no-floating-promises, no-misused-promises, await-thenable, only-throw-error, …). **Follow-up:** turn on `recommended-type-checked` once the typed DB client (`src/types/database.types.ts`, F02) and the contracts (F03) are in use.

### D14. The service-role client is used only for pre-session auth steps
Before a user has a session, the API can't use their JWT. The service-role client is allowed **only** in one module (`src/services/auth.admin.ts` or equivalent) for: resolving `tenantSlug + username` to the login email, checking whether the employee, shop and subscription are active before issuing tokens, and inserting `login_attempts` (the baseline grants that table to the service role only). Everything after login uses a per-request client built from the user's JWT (plus `x-org-id`). Reads a logged-in user needs across shops (their list of shops) go through a `SECURITY DEFINER` function in a new migration, not the service role.

### D15. License and activate-workspace endpoints are removed from Sprint 1
The old `check-license` / `activate-workspace` code targets tables that aren't in the V1 baseline (`saaslicenses`). The data model says owners join through an emailed invite (P01/P02). **Updated by the user's decision (3 Oct):** the server routes, services, limiter and tests are removed in F08 (B5), because the contracts dropped the `LICENSE_*` codes. The client pages are removed in F04 (B7). Git history keeps the old code for P01/P02 to port.

### D16. Token transport and storage
The API returns the access and refresh tokens in the JSON body (contracts `auth`). The client keeps the partner's approach: tokens persisted in `localStorage` through the zustand store, with the trade-off documented in `authStore.ts`. Silent refresh happens before expiry, and logout revokes the session on the server. **Follow-up (hardening):** move the refresh token to an httpOnly cookie and add a strict CSP.

### D17. Failed-login limits
Lockout after **5 failed attempts per identifier (per shop) in 15 minutes**, counted from `login_attempts`, which returns `TOO_MANY_LOGIN_ATTEMPTS` (429). Both numbers are env-configurable (`LOGIN_MAX_FAILURES`, `LOGIN_WINDOW_MINUTES`). This sits on top of the per-IP `loginLimiter`. It's a technical default, not a business rule; change it if the business sets one.

### D18. Client permission code is split between F09 and F06
F09 (wave 3) builds `usePermissions()` (reads `GET /api/me/permissions` through the contract) and the `<RequirePermission>` route guard. F06 (wave 4) adds `useCan`, `<Can>` and `useBranchAccess` on top of it, plus the server half. Both are coded against the same contract, so neither needs a stand-in.

### D19. Route markers make a forgotten check fail CI
Every API route carries a permission marker (`requirePermission(key)`, `authenticatedOnly()` or `publicRoute()`), a cross-shop case (F05) and an audit-registry entry for writes (F07). Scripts and unit tests fail when a route is missing any of them.

### D20. `/health` may use the server (service-role) client for one read-only query
`anon` has no grants, so a public health check can't touch the DB any other way. Allowed: one cheap read-only query with a short timeout, returning only the contract fields. That's the only service-role use outside D14's auth module.

### D21. Incident: `EcoFin-Contracts` wiped by a worktree removal, rebuilt and verified (3 Oct, 12:06)
**What happened:** the master ran `git worktree remove --force` on an API worktree. On Windows, git followed the npm `file:` link `node_modules/@ziadkhaled-wb/contracts` (a junction) and deleted its **target**: the whole `EcoFin-Contracts` folder, `.git` included. The repo had never been pushed.
**Recovery:** the repo was re-initialised, and the F03 builder's recorded steps were replayed in order (its writes and commands, including its own commits). The rebuilt package passes all 27 tests, and its built `dist/`, `package.json`, README and CHANGELOG are **byte-identical** to the reviewer's `npm pack` of the approved version. Commit hashes in `EcoFin-Contracts` differ from the original; content doesn't.
**Rule from now on (anyone, not just agents):** before deleting a worktree or clone that has run `npm ci`/`npm install`, unlink every link inside it first, then remove it. A junction is removed safely with `cmd /c rmdir <link>` (it never touches the target). In Git Bash:
```bash
find <worktree> -path '<worktree>/.git' -prune -o -type l -print | while read -r l; do cmd //c rmdir "$(cygpath -w "$l")"; done
git worktree remove --force <worktree>
```
Publishing `EcoFin-Contracts` to GitHub (D1) removes the single point of failure.

### D22. A story starts once its real dependencies are merged, not the whole previous wave (user OK, 3 Oct)
To finish sooner, F09 (B9, client only) starts as soon as F03 and the F04 client half (B7) are merged, without waiting for the F04 server half (B6). F05 still waits for B6, and wave 4 still waits for F05 and F09.

### D23. `select-shop` returns `{ user, shop }`, not new tokens (contract fix in 0.1.0)
Supabase tokens carry no shop. The active shop is chosen per request by the `x-org-id` header, which the DB checks against the caller's memberships. So `POST /api/auth/select-shop` checks that the shop is one of the caller's (`my_shops()`), writes `auth.login` in that shop, and returns `{ user, shop }`. The client keeps its tokens and sends `x-org-id`. The contract stays at `0.1.0` because it hasn't been published yet.

### D24. Auth hardening found while building F04
- `must_change_password` is cleared only by the API, through the service-role client in `auth.admin.ts` (an extension of D14), **after** Supabase confirms the password change. The DB function isn't executable by `authenticated`, so a user can't clear the flag directly through PostgREST.
- Local `jwt_expiry` is 900 s (15 min). A logged-out access token is refused by the API at once, but PostgREST accepts it until it expires, so a short expiry narrows that window. **Production:** set the same JWT expiry in the Supabase project settings.
- `/refresh` has its own generous per-IP limiter (not the login limiter), so silent refreshes from one shop IP can't block logins.
- The error handler recognises zod errors by name, as well as with `instanceof`, because the contracts package carries its own zod copy.

### D25. Follow-ups from the F04 review
- **Per-request status gate (F05):** employee active, shop active, subscription not ended and `must_change_password` are re-checked on every request, not just at login, because a token can be obtained straight from GoTrue with the public anon key.
- D14 is extended: change-password also counts failed current-password checks in `login_attempts` through the service role (D17 lockout).
- **Known, accepted for now:** an authenticated user can call `auth_record_login` / `auth_record_logout` directly through PostgREST and forge the `x-forwarded-for` / `user-agent` that `app.write_audit` stores. That's a baseline-wide property of `write_audit` reading request headers. **Follow-up:** have PostgREST behind the API only (no public PostgREST access), or sign the client-IP header.
- **Known, accepted for now:** login lockout is check-then-act, so a parallel burst from many IPs can slightly exceed the limit. An unknown username answers a little faster (timing). Both are low risk; revisit in hardening.

### D26. No third repo: contracts live in `EcoFin-API/packages/contracts` (supersedes D1 and §4; user decision, 4 Oct)
- `EcoFin-API` is an npm workspace (`packages/*`). `@ziadkhaled-wb/contracts` (same name, version `0.1.0`) lives in `packages/contracts`, and the API uses it through the workspace, so nothing outside the repo is needed to build, test or deploy the API.
- It is published privately to **GitHub Packages** by a CI workflow on tags `contracts-v*` (`publishConfig.registry = https://npm.pkg.github.com`, auth through `NPM_TOKEN`).
- `EcoFin-Web` depends on `"@ziadkhaled-wb/contracts": "0.1.0"` from GitHub Packages (`.npmrc` with `${NPM_TOKEN}`). **Until the first publish**, `integration/sprint-1` only uses a local copy. That is a **blocker before `main`**.
- No file may reference a `../` path outside its repo. No Dockerfile changes.
- GitHub Packages requires the npm scope to equal the owning GitHub user/org: publishing `@ecotech/*` needs a GitHub org `ecotech` (or a scope rename). See the run report.
- The old `EcoFin-Contracts` folder is deleted after the move; its history is kept inside `EcoFin-API`.

### D27. The API runs as a Docker container on an Azure VM; Cloudflare Workers removed (Q01 · EC-103; user decision, 4 Oct)
- Development API: `https://20.56.139.170.sslip.io` (Caddy + Let's Encrypt in front of the container). Every push to `main` that passes CI runs `.github/workflows/deploy-dev.yml`: `supabase db push` (EcoFin-Development) → image `ghcr.io/ziadkhaled-wb/ecofin-api:sha-<commit>` → deploy over SSH → HTTPS smoke test. Runbook: `docs/05-operations/deployment.md`.
- `src/worker.ts`, `wrangler.jsonc`, the `cloudflare:node` type shim, the `*:worker` scripts and the wrangler packages are gone. Do not reintroduce them.
- `npm run build` = `tsc --noEmit` + an esbuild bundle of `src/server.ts` (dependencies stay external). Plain `tsc` output cannot start under Node: relative imports have no `.js` extension (`ERR_MODULE_NOT_FOUND`).
- Supersedes the "no Dockerfile changes" line of D26: the `Dockerfile` installs the workspace, builds `packages/contracts` and ships its `dist/` next to the bundle.
- Production (`NODE_ENV=production`) requires `CORS_ALLOWED_ORIGINS`; it is set on the VM (`/opt/ecofin/api.env`).
- `integration/sprint-1` goes to `main` with `EcoFin-Web` still on the vendored contracts tarball (D26 called that a blocker). Accepted temporarily to unblock deployment; publishing `@ziadkhaled-wb/contracts` (org or scope decision) stays open and must replace the tarball.
- Local dev: npm workspaces need a file system with symlinks/junctions. A repo on an exFAT drive fails `npm ci` with `EISDIR ... symlink`; keep the repos on NTFS (or WSL).

### D28. Contracts package renamed to `@ziadkhaled-wb/contracts` and published with GitHub's built-in token (user decision, 4 Oct)
- GitHub Packages only accepts a scope equal to the repo owner. EcoFin-API belongs to the user account `ZiadKhaled-wb`, so `@ecotech/contracts` could never be published (D26 left this open). Renamed to `@ziadkhaled-wb/contracts` in both repos instead of creating an `ecotech` org (an org transfer would change repo URLs, image paths, deploy secrets and the Vercel connection).
- `.github/workflows/contracts-publish.yml` publishes with `secrets.GITHUB_TOKEN` (`packages: write`); no `NPM_TOKEN` secret in EcoFin-API. Release = bump `packages/contracts/package.json` version, merge, push tag `contracts-vX.Y.Z`; the workflow refuses a tag that doesn't match the version.
- EcoFin-Web installs the published version from GitHub Packages (`.npmrc` refers only to `${NPM_TOKEN}`): a classic token with `read:packages` lives in Vercel (`NPM_TOKEN`), in the EcoFin-Web Actions secrets (`NPM_TOKEN`) and in each developer's environment. The vendored tarball is removed (closes the D26/D27 blocker).
- The package inherits access from the EcoFin-API repo, so every collaborator with read access to EcoFin-API can install it with their own token.

### D29. F06 access: contracts 0.2.0, one permissions read per request, open question on escalation (user decision on the contract, 4 Oct)
- **Contracts 0.2.0** (user decision): the B10 spec puts the employee id in the URL (`PUT /api/employees/:employeeId/permissions|branches`) and requires a reason on both changes, but 0.1.0 had `employeeId` in both bodies and no `reason` on the branches body. 0.2.0 adds `EmployeeIdParams`, drops `employeeId` from both bodies and adds the required `reason` to `EmployeeBranchesAssignBody`. Nothing used these schemas yet. Publish after the merge with tag `contracts-v0.2.0` (D28); EcoFin-Web stays on 0.1.0 until it calls these endpoints (it only uses `MePermissionsResponse` and `PermissionKey`, unchanged).
- **How the API checks**: `requirePermission(key)` reads `public.my_permissions()` once per request (shared with `GET /api/me/permissions`); `app.has_permission` isn't exposed through PostgREST. The DB stays the real check: every write function starts with `app.require_permission(...)`.
- **Setters are settings, not documents**: `set_employee_permission` and `set_employee_branches` have set semantics (same input twice = same state), so no idempotency key. Each successful call writes one audit row (`employee.permission_set` / `employee.branches_set`) with before/after and the reason. Setting a key back to the role default deletes the override instead of storing a redundant row. An empty branch list is allowed.
- **Refusals**: another shop's employee `NOT_FOUND` (404, looks like a missing id); the owner as target, changing your own access, or going beyond your own keys/branches `FORBIDDEN` (403); another shop's branch `BRANCH_NOT_IN_ORG` (422); empty reason `VALIDATION_FAILED`.
- **Who can grant what (user decision, option 3, 4 Oct; migration `20261003105000_f06_grant_limits.sql`)**: only OWNER has `employee.manage` by default and the owner can grant it, but a non-owner holding it is limited: (1) only the owner can grant or remove `employee.manage` itself; (2) a non-owner can grant or remove only keys they hold; (3) a non-owner can add or remove only branches they work in (branches left unchanged in the list are fine; the user chose to apply the rule to branches too). Refusals are `FORBIDDEN` (403) and write no audit row. The owner keeps full control, except over the owner's own access.
- **Client**: `useCan`, `<Can>`, `useBranchAccess` in EcoFin-Web `src/features/me/` (fail closed while loading). Found while testing: a 401 that came back after another call's refresh had finished triggered a second refresh; the axios interceptor now retries with the current token when the token changed since the request was sent.

### D30. F07 audit: contracts 0.3.0 actor names, reset-password not audited, filter-by-person from the rows (user decisions, 4 Oct)
- **Actor names** (user decision): `AuditRow` gains `actorName` (contracts 0.3.0), read together with the row through the `audit_log -> employees` foreign key (employee names are readable in-shop, so no migration and no service role). Platform actions have no employee, so `actorName` is null. Publish with tag `contracts-v0.3.0` after the merge; EcoFin-Web moves to 0.3.0 for the audit screen.
- **reset-password writes no audit row** (user decision): a login can belong to several shops, so there's no single shop log for it. The audit registry lists it as `none` with that reason; every attempt is in `login_attempts`. Refresh and forgot-password are `none` too (no data changes; no session).
- **Filter by person**: there's no employees list endpoint yet, so the screen filters by clicking an actor's name in a row (a chip clears it), not from a dropdown.
- **How it's enforced**: every write route names the audit action it writes in `src/test/audit-registry/registry.ts` (`npm run check:audit` fails on a missing one, D19); `audit.integration.test.ts` drives each route with an action and checks exactly one row with that action, the request id and the client IP.
- **Search**: `GET /api/audit` (`audit.view`) reads through the caller's own client, so RLS (`audit_log_tenant_read`) decides; the shop filter comes from the session as well. No read function needed: migration slot `20261003110000` stays unused.
- **Device id**: the API forwards the client's `x-device-id` to the database only when it's a UUID; `app.write_audit` drops another shop's device.

### D31. F12 money: big.js in the contracts package, half-up, tax rounded per line (user decision on the library, 4 Oct)
- **Library** (user decision): `big.js` 7.0.1 (small, no dependencies, exact decimals, half-up built in), a runtime dependency of `@ziadkhaled-wb/contracts` so API and Web share one implementation (contracts 0.4.0; `@types/big.js` is a dev dependency, the published types don't expose big.js). The module uses its own big.js constructor in strict mode, so a JS number passed by mistake throws and nobody else's global settings apply.
- **Strings only**: helpers take and return decimal strings (the contract's `Money`); results always have exactly 2 decimals and never read "-0.00". add/subtract/sum accept only values with at most 2 decimals, so rounding can't hide inside a sum; a result that doesn't fit `numeric(18,2)` throws.
- **One rounding rule**: half-up to 2 decimals (a half rounds away from zero: 2.345 -> 2.35, -2.345 -> -2.35).
- **Line level, defined once**: tax is calculated and rounded per line (T01 says line-level); document totals are sums of the rounded lines (`sumTaxLines`) and are never re-taxed. Prices without VAT: tax = round(net x rate%). Prices with VAT: net = round(gross / (1 + rate%)), tax = gross - net, so net + tax = gross exactly. Rates are percentage strings like the `tax_rate numeric(5,2)` columns ("14"). T01 checks these rules against the ETA rounding cases with the client's accountant and may refine them.
- **Exact splits**: `splitMoney` / `allocateMoney` use the largest remainder method in piasters: the parts always add back exactly, leftover piasters go to the largest remainders and ties to the earlier part (1000.00 / 3 = 333.34 + 333.33 + 333.33). Use `allocateMoney` to spread a document discount across lines (T01) and `splitMoney` for installment schedules.
- **Formatting**: `formatEgp(value, 'ar' | 'en')` = Latin digits with the locale's separators, currency after the amount ("1,250.50 EGP" / "1,250.50 ج.م"), rounded half-up first; EcoFin-Web's `formatMoney` uses it.

### D32. F11 numbering: yearly sequences as in the baseline, proven with pgbench (user decision on the format, 4 Oct)
- **Format** (user decision): keep the baseline's `<branch code>-<type>-<yy>-<6 digits>`, e.g. `BR1-SL-26-000123`, one sequence per shop, branch, document type and year (restarts at 000001 each year in the shop's time zone, data model §12). The slice's `BR1-RC-000123` was an example; no migration.
- **How it stays unique and gap-free**: write functions call `app.next_document_number()` inside the transaction that inserts the document. The counter row stays locked until commit, so concurrent documents wait their turn, and a rolled-back document rolls its number back (the next document gets it). Numbers taken outside the document's transaction would leave gaps: don't.
- **Proof**: `supabase/tests/f11_numbering_test.sql` (format, separate sequences, yearly reset, rollback reuse, other shop's branch refused, unique prefix per document type, no direct access) and `npm run db:numbering` (`scripts/db-numbering-proof.mjs`): 1,000 concurrent creations from 40 pgbench sessions, with 400 rolled-back ones mixed in, give exactly 000001..001000, unique, in the order handed out. pgbench ships in the Supabase database image, so there's no new dependency. Both run in the CI `db` job.
- **Test cleanup**: shops, branches and counters can't be deleted (NO_DELETE triggers). The proof's throwaway fixture is removed with triggers off for that one local transaction (`SET LOCAL session_replication_role = replica`); never do this outside local tests.

### D33. F10 ledger core: reconciliation check, idempotency lock for write functions, proven with pgbench (user decisions, 4 Oct)
- **What was already there** (baseline section 17): append-only `stock_movements`, `cash_movements`, `store_credit_movements`; the caches `stock_levels`, `cash_balances`, `store_credit_balances` are changed only by the AFTER INSERT triggers, under a row lock; no overselling (reserved stock counts as taken), no safe/drawer/wallet below zero, a movement reversed once at most, idempotency keys unique per shop on every document table. App users can't write any of these tables.
- **Reconciliation** (migration `20261003120000_f10_ledger.sql`): `app.ledger_mismatches(org DEFAULT NULL)` returns one row per cache that doesn't equal its ledger (stock on hand per product/branch/state, reserved vs active reservations, cash per account, store credit per customer; a cache or ledger side that's missing counts as 0). **Internal only** (user decision): not granted to app users; CI runs it (`npm run db:reconcile`) after the full test suite; the nightly job (F13) and monitoring (Q02) will run it. No endpoint and no permission key.
- **Idempotency lock**: `app.lock_idempotency_key(org, key)` (8-128 characters, else `VALIDATION_FAILED`). Every money/stock write function calls it FIRST, then returns the existing document for that key if there is one, and only then takes the document number and posts. Concurrent requests with one key queue on the lock, so the second returns the first one's document: nothing is posted twice and no number is wasted. Without it, the second request would fail on the unique key after already taking a number (the proof shows this). Same key with a different body (`IDEMPOTENCY_CONFLICT`) is for each write function to check.
- **Proof** (user decision: a test-only sale, since the real `post_sale` is S01): `npm run db:ledger` builds a throwaway shop with 10 units and a sale routine in a scratch schema that follows these rules on the real `sales`, `stock_movements` and `cash_movements` tables. 100 requests from 50 concurrent sessions sell exactly 10; the other 90 get `OUT_OF_STOCK` and leave no sale, movement or number. 50 concurrent requests with one key make one sale, one stock and one cash movement. Then everything reconciles. S01 should run the same proof against its real function. `supabase/tests/f10_ledger_test.sql` covers the single-session rules.
- **Shared proof helpers** in `scripts/db-proof-lib.mjs` (psql/pgbench through `docker exec`, throwaway-shop cleanup with triggers off for that one local transaction). The F11 proof uses them too.

### D34. F13 background jobs: the baseline queue, a worker inside the API, logs for now (user decisions, 5 Oct)
- **Queue**: the baseline `public.jobs` table (statuses queued/running/succeeded/failed/dead, attempts, `max_attempts`, `dead` = the failed list). Migration `20261003130000_f13_jobs.sql` adds service-role-only functions the API calls through PostgREST: `jobs_enqueue_daily`, `jobs_claim` (the `app.claim_jobs` rules plus a filter on the job types the worker has handlers for, so a server that doesn't know a type, e.g. an older version during a deploy, never takes it), `jobs_succeed`, `jobs_fail`, `jobs_ledger_mismatches`, and the read-only support view `app.v_job_runs`. No pg-boss, no pg_cron, no direct Postgres connection.
- **Scheduler** (user decision: API ticker): `src/jobs/worker.ts` runs inside the API (`JOBS_ENABLED`, default true; `JOBS_POLL_SECONDS`, default 30). Each tick asks `jobs_enqueue_daily` to queue each daily job for every active shop whose local time (`organizations.timezone`, Africa/Cairo by default) is past the job's start time. It holds a per-type lock and skips shops that already have that day's run in ANY status, so a daily job runs once per shop per local day however many API instances tick. Shops with an unknown time zone are skipped, not fatal.
- **Retries**: a failed attempt waits 1, 2, 4 ... minutes (at most 1 hour), then the last attempt (`max_attempts`, default 5) makes the job `dead`. A worker that stalls for 15 minutes loses the job to another worker, and only the holder can finish it. Handlers must be safe to run twice.
- **Visibility** (user decision: log now, screen later): every run, retry and dead job is one structured log line (job id, type, shop, attempt, worker); a dead job logs at error level. Support reads `app.v_job_runs` (runbook `docs/05-operations/jobs.md`). A platform-admin screen comes with the platform console (P slices); Q02 turns the error logs into alerts.
- **First job**: `ledger.reconcile`, daily at 03:00 shop time, runs F10's reconciliation per shop; a mismatch is logged at error level and the job still succeeds (retrying wouldn't change it). N04, T02, K04 and Q03 add their jobs to `src/jobs/registry.ts`.
- `supabaseAdmin` (service role) is now allowed in `src/jobs/` too (platform jobs only, through the `jobs_*` functions).

### D35. Q02 monitoring: Sentry for errors, UptimeRobot for uptime, job alerts through Sentry (user decisions, 5 Oct)
- **Error tracking** (user decision: Sentry free plan): `@sentry/node` 11.4.0 in the API (`src/utils/monitoring.ts`) and `@sentry/react` 11.4.0 in EcoFin-Web (`src/lib/monitoring.ts`). Both are off unless a DSN is set (`SENTRY_DSN` on the VM, `VITE_SENTRY_DSN` in Vercel), so local runs, tests and CI send nothing. Errors only: no tracing, no session replay, no profiling.
- **What is reported**: API: every 5xx response, tagged `requestId` (the same id the client gets in `error.requestId` and the log line carries), `orgId`, `userId` (opaque id), `method`, `route`, `path` (no query), `code`; plus unhandled exceptions and rejections (rejections still end the process: `mode: 'strict'`). Web: render errors caught by the ErrorBoundary, uncaught errors, and API calls that fail with 5xx, tagged with the API's `requestId` so one problem can be followed from the browser to the server. Releases: the API image tag (`APP_RELEASE=sha-<commit>`, a Docker build arg) and the Vercel commit.
- **Privacy**: no request bodies, headers, cookies, IP or user info (`dataCollection` all off), no API breadcrumbs, query strings cut from browser breadcrumbs and URLs; sensitive keys (the logger's list) are redacted and emails, 14-digit national ids, Egyptian mobile numbers, bearer tokens and JWTs are masked in every message before an event leaves.
- **Job alerts** (user decision: through the error tracker): a job that lands in the failed list (`job.dead`) and a ledger mismatch (`ledger.mismatch`) are sent to Sentry with job id, type, shop and counts; Sentry emails on new issues. T02 (ETA failures) will use the same `captureProblem`.
- **Uptime** (user decision: UptimeRobot free): two HTTPS monitors, the API `/health` (it also checks the database) and the Vercel site, every 5 minutes, email alerts. Set up by hand (runbook `docs/05-operations/monitoring.md`), nothing in code.
- **Proof**: `POST /api/monitoring/test-error` (permission `org.settings_manage`, writes nothing, audit `none`) always fails with 500; the event in Sentry carries the request id returned to the caller. Verified locally against a fake Sentry ingest with the built server (request id, shop, route, release, environment; no request, user or breadcrumbs).
- The web SDK is loaded lazily (dynamic import) only when a DSN is set: the first screen doesn't grow (about 30 kB gzipped saved).

### D36. F14 file storage: private bucket, service role in one module, metadata through `register_file` (EC-33, task decisions, 5 Oct)
- **Service role** (the decision the task asks to log): "F14: storage objects use the service role inside storage.service only, after session + org + permission checks; metadata goes through `register_file` with the user's JWT." `src/services/storage.service.ts` is the only module that calls storage (`putObject`, `createSignedUrl`, `removeObject`, plus a listing for the orphan report). `supabaseAdmin` is allowed there and in `scripts/files-orphan-report.ts` (the comment in `src/utils/supabase.ts` lists them).
- **Database**: migration `20261005120000_f14_register_file.sql` adds `public.register_file(...)`: `SECURITY DEFINER`, `search_path = ''`, the permission for the purpose as its first check (`app.require_permission`), org from the session, a path under the caller's own shop with no `..`, `.` or backslash (`FILE_PATH_INVALID`), one `file.upload` audit row. No delete function: the baseline blocks deletes.
- **Permissions**: the purpose map is in `src/services/files.rules.ts` (upload) and the same CASE in SQL. The read map sends `logo`, `product_image`, `contract_pdf`, `promissory_note` and `delivery_proof` to any employee (no key). Because the key depends on the purpose, the three file routes carry `authenticatedOnly()` as their access marker and the service checks the key before storage (`npm run check:permissions` stays green). Listing filters rows by the same read map.
- **Not found, not forbidden**: another shop's file is `404 FILE_NOT_FOUND`, the same as a missing one (the task's stricter form of the slice's "403"). A header aimed at another shop is still `403 SHOP_NOT_ALLOWED` from the session check.
- **Entity**: `entityType` must be one of `customer`, `product`, `expense`, `contract`, `legal_case`, `delivery`; its `entityId` must belong to the caller's shop (F05 `assertSameOrg`). Any other type is `VALIDATION_FAILED`. Those six map to tables already in `SAME_ORG_TABLES`.
- **Contracts 0.4.1** (patch, additive): camelCase fields (`entityType`, `sizeBytes`...), matching the other contracts. New error codes: `FILE_NOT_FOUND` (404), `FILE_PATH_INVALID` (422, raised by the SQL), `FILE_TOO_LARGE` (413), `FILE_TYPE_NOT_ALLOWED` (415). The root `package.json` pins 0.4.1 so the workspace links.
- **Multipart**: `multer` 2.4.0 with memory storage and `limits.fileSize = FILE_MAX_BYTES`, the one allowed new dependency. No `@types/multer` (that would be a second dependency): the parts used are declared in `src/types/multer.d.ts`.
- **Env**: `FILE_MAX_BYTES` (default 10485760, max = the bucket's limit) and `FILE_URL_TTL_SECONDS` (default 60, 1 to 3600).
- **Orphans**: `scripts/files-orphan-report.ts` lists objects at least 24 h old with no `files` row. Report only. Wiring it to the job runner is a follow-up (F13 is merged).

- P01: invite token = 32 random bytes in the URL fragment, only its SHA-256 stored, 72 h TTL, single use; super-admin functions check app.is_super_admin() instead of require_permission; service role only for pre-session lookup and accept.

- P05: expiry is by date, never status; read-only writes enforced through require_permission with export.data allowed; org-locking triggers enforce limits and pending invitations count as users; warning starts 14 days before the end date.

O01: branch code is immutable and uppercased; an active same-branch safe is the default (created/filled automatically); deactivation requires a reason and explicit confirmation for open shifts, stock or cash, never for the main branch; inactive branches reject writes through require_branch_access.

O02: Case A username login resolves the linked auth email (username-only invites use <username>@<org UUID>.ecofin.invalid); real-email invites/resets are mailed, otherwise a one-time fragment link is returned; reset tokens expire in 24 h and are consumed before the auth password update; nonowners can only assign held role/override keys; OWNER/self targets and OWNER assignment are protected; pending login edits revoke invites and linked identifiers are locked; deactivation revokes open invite/reset tokens. Existing F06 grant and branch limits already enforce escalation checks.

### D37. EC-142 / EC-143 bug fixes (6 Oct)
- **EC-142**: `register_file` now checks the linked record itself (entity type in the API's list, entity id in the caller's shop, else `NOT_FOUND`), in a new migration that replaces the function. The API check stays as the early answer.
- **EC-143**: `PUT /api/employees/:employeeId/active` (`employee.manage`) through `public.set_employee_active`, with the F06 setter rules (`app.lock_managed_employee`: reason required, other shop = `NOT_FOUND`, not the owner, not yourself). One audit action `employee.active_set` with `is_active` before/after, like `employee.branches_set`. No extra limit for non-owner managers (D29 only limits granting permissions and branches): any holder of `employee.manage` can deactivate anyone but the owner and themself. Contracts 0.4.2 (additive). The Web deactivate action waits for the Employees screen; the Web part of EC-143 is the "Switch shop" menu item.

### D38. Integrate EC-143 with O02
- One employee activation route returns both O02 `id`/`is_active` and EC-143 `employeeId`/`active` fields. Contracts 0.8.1 includes both schema families.
- New compatibility migrations preserve both original migrations, replace the conflicting void RPC signature with the EC-143 table return, and restore O02 token locking/revocation and subscription triggers. A state change writes one `employee.active_set` warning audit; an unchanged state writes none. Deactivation requires a reason; reactivation keeps O02's optional reason. Owner/self and foreign targets use EC-143 `FORBIDDEN`/`NOT_FOUND`.

### D39. Migrations are numbered after the newest one on main; PR 25's migrations renumbered (6 Oct)
- **What happened**: PR 24 (EC-142/143) deployed `20261006110000` to the development database first; PR 25 (P01/P05/O01/O02) was merged later with migrations numbered `20261006010000`-`20261006105000`. `supabase db push` refuses migrations numbered before the newest applied one, so the deploy of PR 25 stopped at the migration step (nothing applied, the VM kept the previous release). `--include-all` would not have worked either: O02 would then create `set_employee_active` after EC-143 already had.
- **Fix**: PR 25's migrations, never applied to a hosted database, are renumbered after `20261006110000`: P01 `110100`, P05 `110200`, O01 `110300`, the signature drop `110350` (now drops EC-143's version before O02 creates its own) and O02 `110400`; `20261006120000` drops O02's `RETURNS void` version before creating the merged one. A fresh build and the development database now run the same files in the same order; the final `set_employee_active` is unchanged.
- **Rule from now on**: a new migration is numbered after the newest migration on `main` at merge time (rebase or renumber before merging). `scripts/check-migration-order.mjs` runs first in the CI `check` job: on a pull request against the target branch, on a push to `main` against the previous commit, so a merge that would break the deploy fails CI (and the deploy doesn't start).
- Never renumber a migration that is already applied on a hosted database: add a new one instead.

### D40. P03 shop settings: refactored from FinTech-Pro, typed columns, FinTech rules kept (EC-36, user decisions, 7 Oct)
- **Source**: FinTech-Pro's settings screen (`server/src/services/settings.ts`, `client/src/pages/SettingsPage.tsx`, the `XConfig` rules in `client/src/lib/xcore.ts`) is the starting point, not a rewrite from scratch. What changed: one untyped `config_data` blob written with the service role became typed columns written only by permission-checked `SECURITY DEFINER` functions; role names (`authorizeRole('OWNER','MODERATOR','ADMIN')`) became the `org.settings_manage` permission; `PUT` became a partial `PATCH`; FinTech's `POST /settings/reset` is dropped (defaults come from P01 provisioning).
- **New columns (user decision)**: `organizations.address`, `organizations.phone`, `org_settings.receipt_fields` (the slice listed them, the baseline had no column).
- **FinTech-Pro rules kept (user decision)**: installment policy gets max months by sale amount (`amount_tiers`), minimum installment per frequency, a down payment rule per frequency plus a max down payment %, and a minimum sale amount (FinTech's `minInvoiceAmount`). The other FinTech tabs are stored now and read by later slices: credit minimum score and weights (R03), days overdue before legal referral per frequency, ban period and warning interval (N04/L01), global minimum stock (C02), theme colour. Currency is a column fixed to EGP. FinTech's credit-score formula itself is not ported (R03 decides).
- **Daily installments (user decision)**: `installment_frequency` gains `daily` (weekly stays), in its own migration. FinTech's "DAYS_OF_MONTH" down payment is the rule `installment_per_day_of_month`, allowed for daily only.
- **Reading**: `GET /api/settings` is open to every employee of the shop (the POS needs receipt, VAT and discount rules) and includes the caller's own cap (`my_discount`). Policy history and all writes need `org.settings_manage`; publishing also needs the installments module. The history read uses `app.has_permission`, so an expired (read-only) shop can still read it.
- **Policy versions**: publishing sends only the changes; the function copies the newest version, applies them, validates and inserts version n+1 (immutable). The same terms again return the current version (no duplicate on a double click). New contracts read `app.current_installment_policy(org)`.
- **Discount cap**: `app.check_discount(pct)` for the sales slices. OWNER has no cap; a role missing from `discount_caps` gets 0%; `discount.above_cap` lets an employee go above it (the approval flow comes with the sales slices). Assumptions to confirm with the client: 0% default, and the defaults for weekly legal referral (63 days, same as monthly).
- **Contracts 0.9.0**: `ShopSettings`, `ShopSettingsUpdateBody`, `InstallmentPolicy`, `InstallmentPolicyBody`; new codes `SETTINGS_INVALID`, `POLICY_INVALID` (400), `TAX_CLASS_NOT_FOUND` (404), `DISCOUNT_ABOVE_CAP` (403).

### D41. T01 VAT engine: one calculation in SQL with a TypeScript copy, golden cases, accountant settings (EC-89, user decisions, 7 Oct)
- **Where the calculation lives (user decision)**: `app.compute_document_tax(jsonb)` in the database is the source of truth; every posting function (S01 sales, S03 returns, orders) calls it, so a client can't send its own tax figures. `computeDocumentTax` in the contracts is the same calculation for screens (POS preview, forms). Both run the same golden cases (`supabase/tests/fixtures/t01_tax_cases.json`: 13 documents, 3 return sequences); the SQL test embeds a copy and `src/test/t01-golden.test.ts` fails if the copies differ.
- **Rules** (D31 applied to documents): line amount = unit price × quantity − line discount − its share of the document discount; the document discount is spread by amount after line discounts with the largest remainder in piasters (leftovers to the larger remainders, ties to the earlier line); tax per line, half-up; prices with VAT: net = round(amount / (1 + rate)), tax = amount − net; totals are sums of the lines. `discount_amount` on a line includes its share of the document discount (matches `sale_lines`).
- **Returns**: `app.return_line_tax` / `returnLineTax` reverse a line's tax proportionally (half-up); the return that empties the line takes the remainder, so all returns of a line add back to it exactly.
- **Snapshots**: issued lines keep `tax_rate` and `tax_amount`; a class rate change applies to new documents only (tested).
- **Default classes**: every shop gets standard 14% (T1/V009), zero-rated (T1/V001) and exempt (T1/V003) through a trigger on `org_settings` insert, so P01's provisioning function is unchanged; existing shops were backfilled; the standard class becomes the default and the delivery fee class. ETA subtype codes to be confirmed with the accountant.
- **Tax classes**: `list_tax_classes` (any employee), `create_tax_class`, `update_tax_class`, `set_tax_class_archived` (`catalog.manage`, audited). The default class, the delivery fee class and a class used by active products can't be archived (`TAX_CLASS_IN_USE`).
- **Accountant settings (user decision: settings with defaults, to confirm)**: `installment_markup_vat` (`not_taxed` default | `taxed`), `delivery_fee_tax_class_id` (standard class), `deposit_vat_timing` (`on_delivery` default | `on_deposit`). Rounding of VAT-inclusive prices follows D31 until the accountant confirms; ETA receipts carry up to 5 decimals (T02).
- **Contracts 0.10.0**; new codes `TAX_CLASS_NAME_TAKEN`, `TAX_CLASS_IN_USE` (409), `TAX_DISCOUNT_TOO_LARGE` (400).

### D43. P04 legal and financing profile: its own permission, tax number moved, installment switch enforced on contracts (EC-37, 8 Oct)
- **Profile apart from settings**: `GET /api/settings/profile` (any employee) and `PATCH /api/settings/profile` (`org.profile_manage`) through `get_shop_profile` / `update_org_profile`: legal name, commercial register, tax registration number, the owner-entered consumer-finance legal status (FRA 18/2020; new column `organizations.consumer_finance_legal_status`, at most 500 characters) and `installments_enabled`. `creditor_model` is read-only (`in_house` in V1; V2 providers become new enum values). One `org.profile_updated` audit row with the changed keys; no change, no row.
- **Tax registration number moved**: it is a legal identifier, so it is edited only through the profile. `update_org_settings` (P03) refuses `tax_registration_no` with `SETTINGS_INVALID`. Implementation: the P03 function is renamed `update_org_settings_p03` (no grants) and the public `update_org_settings` wraps it after that check. **A later migration that replaces `update_org_settings` must replace `update_org_settings_p03` instead**, or redo the wrapper. The Web settings page no longer shows the field; the profile page does.
- **Installment switch, enforced at the contract**: a `BEFORE INSERT` trigger on `contracts` (`app.set_contract_creditor`) raises `INSTALLMENTS_DISABLED` (403) when the shop has installments off, and otherwise sets `contracts.creditor` from the shop's `creditor_model`, so every contract stores its creditor whatever the caller sends. N02 gets this for free; it should still check the switch early for a clear message.
- **Contracts 0.12.0**: `ShopProfile`, `ShopProfileUpdateBody`, `INSTALLMENTS_DISABLED`.

### D44. C02 products: generated barcodes, price-change permission, serialized lock, lookup = active only (EC-43, 8 Oct)
- **Generated barcode**: an empty or null barcode (create, or update with `barcode: null`/`""`) becomes an in-store EAN-13: `'2'` + 11 random digits + the check digit from `app.ean13_check_digit` (weights 1,3 from the left). A unique-index collision retries with new digits up to 5 times, then `PRODUCT_BARCODE_TAKEN`. The old `generate_barcode()` (sequential, collides) is not reused. A barcode the shop types is stored as given (4-32 letters, digits or dashes; no check-digit rule, suppliers' codes vary).
- **Price changes**: `catalog.manage` edits a product; when `cash_price` or `installment_price` actually changes, `update_product` also calls `app.require_permission('catalog.price_change')`. That edit is audited as `product.price_changed` (before/after hold every changed key, prices included); any other edit as `product.updated`. No change, no row. The audit log is the price history (no price table).
- **Cost is never writable here**: `avg_cost` is set only by purchase approval (U0x); a body with it is refused (`VALIDATION_FAILED`) by the strict contract and by SQL.
- **Serialized lock**: `is_serialized` can't change once the product has a `units` row or a `stock_movements` row (`PRODUCT_SERIAL_LOCKED`).
- **Archive**: `is_active` moves together with `archived_at` (archive: false + now(); restore: true + NULL); `is_active` is not in the contract. Archiving is allowed with stock on hand (the client confirms). An archived product can't be edited (`PRODUCT_NOT_FOUND`; restore first). Restore is refused under an archived category (`PRODUCT_CATEGORY_ARCHIVED`) or with an archived tax class (`TAX_CLASS_NOT_FOUND`).
- **Reads**: `list_products` / `get_product` / `lookup_product` are open to any employee. `get_product` includes archived products (old documents keep showing them); `lookup_product` (what the POS calls: exact barcode first, then SKU upper-cased) returns **active products only**. `list_products` matches names (ILIKE, wildcards escaped), a SKU prefix or the exact barcode, and filters categories through `app.category_with_children` (D42).
- **Contracts 0.13.0**: `Product`, `ProductList`, `ProductListQuery`, `ProductLookupQuery`, `ProductCreateBody`, `ProductUpdateBody`, `ProductIdParams`; codes `PRODUCT_NOT_FOUND` (404), `PRODUCT_SKU_TAKEN`, `PRODUCT_BARCODE_TAKEN`, `PRODUCT_SERIAL_LOCKED`, `PRODUCT_CATEGORY_ARCHIVED` (409).

### D45. C03 barcode labels: rendered and printed by the client; units listed by serial (EC-44, 8 Oct)
- **No label storage**: labels are drawn in the browser and printed with the browser's print dialog (a label printer, or "Save as PDF" for the PDF). No table, no audit row (printing changes nothing). The label shows the product name, the cash price and the barcode with its digits; a unit label also shows the serial.
- **Symbology**: a 13-digit code with a valid EAN-13 check digit (C02's generated in-store codes, most supplier codes) prints as **EAN-13**; any other code (and every serial / IMEI) prints as **Code 128**. The encoders live in the Web repo (`src/lib/barcode.ts`, no new dependency) and are tested on known encodings; the POS lookup (`lookup_product`) reads the same code back.
- **Templates** are client constants: rolls 38×25 mm, 50×30 mm, 58×40 mm and an A4 sheet of 3×8 (70×37 mm). The last choice is remembered per browser. Adding a template is a client change only.
- **Units by serial**: `GET /api/products/:id/units` (`list_product_units`, any employee) lists a product's units in the branches the caller can access (OWNER: all), `in_stock` by default, in serial order; another shop's product answers `PRODUCT_NOT_FOUND`. One label per selected unit, its barcode = the serial. Units only exist once purchases / opening stock (U0x, M02) create them.
- **Contracts 0.14.0**: `UnitStatus`, `ProductUnit`, `ProductUnitList`, `ProductUnitsQuery`.

### D46. No product limit per plan (EC-130, 9 Oct)
- Plans limit branches, users and devices only (`plans.max_branches`, `max_users`, `max_devices`, P05). There is **no product limit**: the shop owner decided (9 Oct) that a plan never caps the number of products. TEST-2's "plan limits (… products)" item is closed by this decision; don't add a product counter or trigger.
- C02 review (same day): restoring a product now locks its category and tax class rows before checking them (`20261009090000_c02_restore_locks.sql`); before, an active category wasn't locked and a concurrent category archive could leave an active product in an archived category (reproduced with two sessions, fixed).