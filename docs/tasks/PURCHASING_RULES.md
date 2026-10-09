# Purchasing tasks (U01–U06): rules for the builder agent

Read this file first, then your own task file (`docs/tasks/U0x.md`). Both are binding. If anything in them conflicts with the code, the docs or each other, **stop and ask**. Don't guess, and don't build a stand-in.

## 0. Setup report (before any code)
1. Follow `AGENT_SETUP.md` and print its setup report. Context7 tools are named `mcp__context7__resolve-library-id` and `mcp__context7__query-docs`. If they are missing, print `STATUS: NEEDS_USER` and stop.
2. Then read, in this order:
   - `AGENTS.md`
   - `.claude/skills/ecotech-build/SKILL.md`
   - this file
   - your task file
   - the decisions it names in `DECISIONS.md`
   - the files it lists under "Copy this pattern"
3. Print a **plan**: the SQL functions, routes, contract schemas, Web screens and test files you will create, each with its file path. Then **wait for "go"**.

## 1. Where and how you work
- Two repos: `D:\EcoFin Version 1\EcoFin API` (server, SQL, contracts) and `D:\EcoFin Version 1\EcoFin Web` (client).
- Branch `feat/<task-id>-<name>` in each repo, cut from the latest `main`: `git checkout main && git pull && git checkout -b feat/...`.
- **Stage named files only.** Never `git add .`, `git add -A` or `git add <folder>`; another agent may share the folder. Check with `git diff --cached --stat` before every commit.
- Small commits. End every commit message with the attribution line your environment gives you.
- **Push your branch and open a PR only when the person running you says so.** Never merge. Never push to `main`. Never tag. Never publish packages.
- **Never** touch a remote database, `supabase link`, `db push`, the Vercel or Azure deploys, `.env` values, tokens or passwords.

## 2. The machine (Windows 11, Node 24, D: drive is exFAT)
- **API install:**
  - Never run plain `npm install` or `npm ci` in `EcoFin API` on D:. It fails on the workspace link and once wiped `node_modules`.
  - Use `npm ci --workspaces=false`, then `node scripts/exfat-sync-contracts.mjs`. That script builds `packages/contracts` and copies it into `node_modules`; run it again after **every** contracts change.
- **Web install:** `npm install` works; it needs the `NPM_TOKEN` user environment variable, which is already set. Never print it.
- **Lockfile changes in the API** (the contracts pin only): edit `package.json` and `package-lock.json` the way the I06 commit did (two `"0.x.y"` strings). Don't regenerate the lockfile.
- **Local Supabase:**
  - Start it: `npx -y supabase@2.119.0 start`.
  - Apply your new migration: `npx -y supabase@2.119.0 db reset`. This is local only and re-seeds the demo users.
  - Alternatively: `docker exec -i supabase_db_ecofin-api psql -U postgres -v ON_ERROR_STOP=1 < supabase/migrations/<file>.sql`, then insert its version into `supabase_migrations.schema_migrations`.
- **Docker Desktop crash** ("sailor-ingest.sock" / stale socket): stop and tell the person running you. Never click "Reset to factory defaults".
- **Regenerate DB types** after the migration: `npm run db:types`.

## 3. Rules you must never break (summary of `ecotech-build`; the skill wins on details)
- **Tenant:** the org comes only from `app.current_org_id()` in SQL. Every foreign id in a request is checked to belong to the same org; another shop's id answers `*_NOT_FOUND`.
- **Writes:** only through a new `SECURITY DEFINER` function with `SET search_path = ''`, in **one new migration**. Never edit an existing migration or the baseline.
  - It starts with `v_emp := app.require_permission('<key>')`.
  - It checks `app.require_branch_access(branch)` for branch data.
  - It locks the rows it changes `FOR UPDATE`, in `product_id` order for lines.
  - It writes **one** `app.write_audit(...)`.
  - Grants: `REVOKE ALL ... FROM PUBLIC, anon, authenticated`, then `GRANT EXECUTE ... TO authenticated`. `app.*` helpers get no grants.
- **Reads** use `app.has_permission(...)`, not `require_permission`, so an expired shop can still read. Each read also goes into the `t.no_permission_ok` allowlist in `supabase/tests/security_guards_test.sql`, with a reason.
- **Stock and cash:**
  - They change only by inserting `stock_movements` / `cash_movements`. Never write `stock_levels`, `cash_balances`, or a unit's status or branch; triggers own them.
  - New units are created only through `app.create_units(...)` (I04).
- **Money:**
  - DB: `numeric(18,2)`; `products.avg_cost` is `numeric(18,4)`.
  - API/JSON: decimal **strings** (`Money` from the contracts).
  - Never JS `number` arithmetic on money. Use the contracts' money helpers (F12, `packages/contracts/src/money.ts`).
- **Documents:**
  - Numbers come from `app.next_document_number(org, branch, '<doc_type>')`. Prefixes: PO, PI, PR, SP.
  - Issued documents are never edited or deleted; corrections are linked reversals.
- **Idempotency:** every function that posts stock or money takes `p_idempotency_key` (8–128 characters).
  - The same key again returns the first result and changes nothing.
  - `system:` keys are refused (`app.lock_idempotency_key`).
  - Every such function gets a row in `t.replay_tested` in `supabase/tests/ledger_invariants_test.sql`.
- **Errors:** business errors are codes listed in `packages/contracts/src/errors.ts`, raised in SQL as `RAISE EXCEPTION 'CODE: detail'`. Never return raw DB messages.
- **Contracts:**
  - All request and response shapes live in `@ziadkhaled-wb/contracts`. No local API types.
  - When you change them, bump **both** `packages/contracts/package.json` **and** `CONTRACTS_VERSION` in `packages/contracts/src/index.ts`, plus the root pin, and add a `CHANGELOG.md` entry.
- **Web:**
  - No hard-coded text: every string goes in **both** `ar` and `en` files with the same keys.
  - Layout works RTL and LTR.
  - Any id read from the URL (`?x=` or `:id`) that goes into an API path must pass `Uuid.safeParse` first (security review I05).
- No `any`, no `@ts-ignore`, no `eslint-disable` (except the one existing pattern for exhaustive-deps), no `.skip`/`.only` on existing tests, and no deleted or weakened assertions to make a test pass.

## 4. Lessons from I01–I06 (each one cost a CI rerun or a bug)
- A SQL test file runs in **one transaction**: `now()` is the same for every row. Compare history as a set, or insert test rows with `clock_timestamp()`.
- Inside `array_agg(... ORDER BY 1)`, `1` sorts by the constant, not the value.
- Shop two in the seed is on plan `retail` (no `serials` module). For serial cases, register in shop one and let shop two aim at it.
- `security_guards_test.sql` fails if a new public read is missing from its allowlist. `tenant_and_permission_test.sql` fails if a new function has no denial case.
- Cross-shop: `src/test/cross-shop/cases.ts` needs a case for **every** new route, and `src/test/cross-shop/check.test.ts` lists every route key and the total count. The audit registry (`src/test/audit-registry/registry.ts`) needs every non-GET route, and `src/routes/audit.integration.test.ts` needs a driver for each route that writes an audit row.
- Mount static routes (`/approvals`, `/lookup`) **before** `/:id`.
- Bash heredocs mangle backslashes and apostrophes. Write SQL, TS and Python files with your file-writing tool, not through `cat <<EOF`.
- Web:
  - A `Dialog` width needs the important form: `className="max-w-3xl!"`.
  - Hide field labels in table cells with `[&_.field-label]:sr-only`.
  - **Inputs inside `DataTable` cells lose focus on every keystroke**: render editable lines in a plain `<table>` with a row component (see `src/pages/inventory/MinLevelsDialog.tsx`).
  - Run Web tests with `--maxWorkers=2`.
- Known local-only failures (CI is fine; don't "fix" them):
  - `smoke_test.sql` "stale job reclaimed" fails while queued jobs pile up in the local DB.
  - Web `SamplePage` can time out locally.

## 5. Checks to run before you say "done" (all of them, every time)
API (`EcoFin API`):
```
npm run typecheck
npm run lint
npm run format:check
npx vitest run                                    # unit tests
npm run test:contracts
npm run check:cross-shop
npm run check:permissions
npm run check:audit
node scripts/check-migration-order.mjs
for f in supabase/tests/*.sql; do echo "$f: $(npm run -s db:smoke -- "$f" 2>&1 | tail -1)"; done
```
Integration (local stack). Env from `npx -y supabase@2.119.0 status -o json`:
```
SUPABASE_URL=<API_URL> SUPABASE_ANON_KEY=<ANON_KEY> SUPABASE_SERVICE_ROLE_KEY=<SERVICE_ROLE_KEY>
FRONTEND_URL=http://localhost:5173 RUN_INTEGRATION=1 LOG_LEVEL=error
SMTP_URL=smtp://127.0.0.1:54325 MAIL_FROM='EcoFin Local <local@ecotech.test>'
```
- Before each run: `docker exec supabase_db_ecofin-api psql -U postgres -qtAc "delete from public.login_attempts where success = false"`.
- Then: `npx vitest run src/routes/<your>.integration.test.ts src/routes/audit.integration.test.ts src/test/cross-shop/cross-shop.integration.test.ts`.

Web (`EcoFin Web`):
```
npm run typecheck
npm run lint
npx prettier --check src
npx vitest run --maxWorkers=2
```

## 6. What you return (paste real output, not a summary of it)
The `ecotech-build` summary (section 4 of the skill), plus this **evidence block**:
```
API branch / last commit:   <branch> <sha>        Web branch / last commit: <branch> <sha>
git diff --stat main...HEAD (both repos): <paste>
Migration file: <name>      Contracts: package.json <x.y.z> / CONTRACTS_VERSION <x.y.z>
SQL tests (one line per file, the "passed N, failed M" line): <paste all>
check:cross-shop / check:permissions / check:audit / migration order: <paste the last line of each>
API unit tests: <Tests N passed>   Contracts tests: <N passed>   Integration: <N passed, which files>
Web tests: <Tests N passed>   typecheck/lint/prettier: <ok or the errors>
Done-when checklist: every item from the task file, ticked or explained
Decisions written: D<nn> in DECISIONS.md (paste its title line)
Anything you did NOT do, skipped, or are unsure of: <list, or "none">
```
If a check fails and you can't fix it inside your task's scope, say so plainly in "did NOT do". Don't hide it.
