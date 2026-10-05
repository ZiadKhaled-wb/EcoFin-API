# Test plan TEST-1 (foundation security and ledger tests, EC-128)

Task file: TEST1_EXECUTION.md. Tests and CI only, no app code. Run 6 Oct 2026 against local Supabase.

## Coverage before TEST-1 (step 2)

| Point (EC-128) | Existing test file:name | Gap (filled by TEST-1) |
|---|---|---|
| 1. Cross-tenant, API | `src/test/cross-shop/cases.ts` + `check.test.ts` (every route, CI gate `check:cross-shop`); `src/routes/*.integration.test.ts` | F14 file cases used an id that doesn't exist; no test with a **real** shop B file / customer, none with the user's own token straight against PostgREST and Storage → `files.cross-shop.integration.test.ts` |
| 1. Cross-tenant, DB | `f05_tenant_test.sql` 2.x (RLS loop over tenant **tables**, fixtures in ~5 tables) | Views not covered; no loop run as **both** shops; few tables held other-shop rows; no write-function-with-B-id cases → `tenant_and_permission_test.sql` 1–3 |
| 2. Permissions | `f06_permissions_test.sql` 1–2 (61 keys via `app.require_permission`; `set_employee_*` denials) | `register_file` had one denial (logo) in `f14_files_test.sql` 2.5; no generic list that makes a new write function without a denial test fail → `tenant_and_permission_test.sql` 4, `security_guards_test.sql` 5 |
| 3. No direct table writes | `f05_tenant_test.sql` 1 (tenant tables), `f10_ledger_test.sql` 4.1 (caches, ledgers) | Not generic over **all** public tables / views / sequences; nothing on `anon` EXECUTE, definer `search_path`, RLS + SELECT policy per table → `security_guards_test.sql` |
| 4. Ledger | `f10_ledger_test.sql` 1–6 (single steps; append-only stock/cash as postgres; reversal once stock/cash; D33 replay of a sale); `f07_audit_test.sql` 2 (audit append-only); `db:reconcile` | Invariants over the **whole DB** straight from the tables; store credit; `payments` / `payment_allocations` / `store_credit_movements` append-only; **service_role**; payment reversal once; generic key-uniqueness and replay-test lists → `ledger_invariants_test.sql` |
| 5. Money | `packages/contracts/src/money.test.ts` (F12: half-up, 1000/3, VAT 114/100, 500 random cases) | `2.675 → 2.68`, `-0.005 → -0.01`; 100/3 inclusive sums to 100.00; every helper returns a decimal string and refuses a JS number → added to `money.test.ts` |

## Write functions (step 4)

Every `public` function `authenticated` can EXECUTE. `security_guards_test.sql` 5.2 fails if a new one doesn't call `app.require_permission` (or isn't allowlisted there); `tenant_and_permission_test.sql` 4.0 fails if a new one has no denial case.

| Function | Needs | Denial case (role without the key) | Cross-shop case |
|---|---|---|---|
| `set_employee_permission(p_employee_id, p_permission_key, p_granted, p_reason)` | `employee.manage` | BRANCH_MANAGER | 3.1 (B's employee) |
| `set_employee_branches(p_employee_id, p_branch_ids, p_reason)` | `employee.manage` | BRANCH_MANAGER | 3.2 (B's employee), 3.3 (B's branch) |
| `register_file(...)`, one case per purpose (13) | per purpose: logo/other `org.settings_manage`, product_image `catalog.manage`, customer_id `customer.edit`, survey_photo `survey.submit`, signature/contract_pdf/promissory_note `installment.create`, delivery_proof `delivery.manage`, expense_receipt `expense.create`, legal_document `legal.manage`, import `import.data`, export `export.data` | first non-owner role lacking the key (CASHIER, WAREHOUSE or BRANCH_MANAGER) | 3.4 (B's folder), 3.5 (B's file id), 3.6 (B's customer: **known bug**) |
| allowlisted, no permission: `session_context`, `my_shops`, `my_permissions`, `auth_record_login`, `auth_record_logout`, `auth_record_password_change` | session / login helpers, write nothing but the caller's own audit | n.a. | n.a. |

No F10/F11 write function takes an idempotency key yet; only the D33 helper `app.lock_idempotency_key` does (replay-tested). `ledger_invariants_test.sql` 4.5 fails when one is added without a replay test.

## Tests

| Test ID | Done-when item | Type | Preconditions | Steps | Expected result | Automated file:test name | Status |
|---|---|---|---|---|---|---|---|
| T1-01 | 3. No direct writes: anon has no privilege on any table, view or sequence | SQL (generic) | `db:reset` | `npm run db:smoke -- supabase/tests/security_guards_test.sql` | 1.1–1.2 pass | security_guards_test.sql 1.x | passing (local) |
| T1-02 | 3. authenticated has no INSERT/UPDATE/DELETE/TRUNCATE on any public table | SQL (generic) | same | same | 2.1 pass | security_guards_test.sql 2.1 | passing |
| T1-03 | 1. RLS on + SELECT policy on every table with organization_id (allowlist: `jobs`) | SQL (generic) | same | same | 3.1–3.4 pass | security_guards_test.sql 3.x | passing |
| T1-04 | 2. Every SECURITY DEFINER in public/app pins `search_path = ''` | SQL (generic) | same | same | 4.1–4.2 pass | security_guards_test.sql 4.x | passing |
| T1-05 | 2. Every callable public function calls `app.require_permission` (allowlist of 6 helpers) | SQL (generic) | same | same | 5.1–5.3 pass | security_guards_test.sql 5.x | passing |
| T1-06 | 3. anon can EXECUTE nothing in public or app | SQL (generic) | same | same | 6.1–6.2 pass | security_guards_test.sql 6.x | passing |
| T1-07 | 1. Cross-tenant read, every table **and view**, as A and as B, also aimed at the other shop | SQL (generic) | `db:reset` (dev seed shops) | `npm run db:smoke -- supabase/tests/tenant_and_permission_test.sql` | 0 foreign rows in 92 readable relations; own rows visible; B has rows in 28 tables / 34 tables+views of 93 | tenant_and_permission_test.sql 1.x, 2.1–2.4 | passing |
| T1-08 | 1. Cross-tenant write: each write function called by A with B's id fails, nothing changes | SQL | same | same | 3.1–3.5 pass; 3.6 known bug | tenant_and_permission_test.sql 3.x | passing (3.6 marked known bug) |
| T1-09 | 2. Every write function denies a role without its permission (with valid arguments) | SQL (generic) | same | same | 15 × PERMISSION_DENIED, the same 15 calls work for the owner; completeness 4.0/4.0b | tenant_and_permission_test.sql 4.x | passing |
| T1-10 | 4. Cache = SUM(ledger) for stock, cash, store credit after in/out/reversal, whole DB | SQL | `db:reset` | `npm run db:smoke -- supabase/tests/ledger_invariants_test.sql` | 1.1–1.5 pass | ledger_invariants_test.sql 1.x | passing |
| T1-11 | 4. UPDATE/DELETE on stock/cash/store-credit movements, payments, payment_allocations, audit_log → APPEND_ONLY as postgres and service_role | SQL | same | same | 2.0–2.9 pass (24 refusals) | ledger_invariants_test.sql 2.x | passing |
| T1-12 | 4. Reversed once only (stock, cash, payment) + every `reverses_*` column has a unique index | SQL | same | same | 3.1–3.4 pass | ledger_invariants_test.sql 3.x | passing |
| T1-13 | 4. Replaying a key returns the same document, no second row; unique (org, key) on all 21 key tables; every key-taking function has a replay test | SQL | same | same | 4.1–4.5 pass | ledger_invariants_test.sql 4.x | passing |
| T1-14 | 5. Half-up at 2 decimals: 2.675 → 2.68, -0.005 → -0.01 | unit | none | `npm run test -w @ziadkhaled-wb/contracts` | pass | money.test.ts "roundMoney: one rule, half-up to 2 decimals" | passing |
| T1-15 | 5. 100.00 inclusive in 3 lines at 14% adds back to 100.00 | unit | none | same | pass | money.test.ts "TEST-1: 100.00 inclusive split in 3 lines…" | passing |
| T1-16 | 5. Helpers return 2-decimal strings and refuse JS numbers | unit | none | same | 16 + 1 cases pass | money.test.ts "TEST-1: the helpers work in decimals, never JS numbers" | passing |
| T1-17 | 1. F14 with real shop B data: file id / customer list read like missing (404), upload for B's customer refused, aimed at B → 403 | integration | local stack, `RUN_INTEGRATION=1` | `npx vitest run src/routes/files.cross-shop.integration.test.ts` | 4 pass | files.cross-shop.integration.test.ts "through the API…" | passing |
| T1-18 | 1./3. With A's own token straight to PostgREST/Storage: no B rows, no B object, no table writes, no B path via `register_file` | integration | same | same | 4 pass; 1 `it.fails` (known bug) | files.cross-shop.integration.test.ts "straight against the database…" | passing (1 known bug) |
| T1-19 | CI runs every SQL file (glob) and the integration suites in their own job | CI | GitHub | open a PR | jobs `check`, `db`, `integration` green | .github/workflows/ci.yml | to verify on the first PR |

## Required CI jobs (step 8.4, set by a person)

GitHub → Settings → Branches → branch protection rule for `main` → "Require status checks to pass before merging" → add these three checks (workflow `CI`):

- `check`
- `db`
- `integration`

Also tick "Require branches to be up to date before merging". Until this is set, a failing test does not block the merge.

## Known bugs (tests marked, app not changed)

| Test | What's wrong | Where |
|---|---|---|
| tenant_and_permission_test.sql `KNOWN BUG 3.6`; files.cross-shop.integration.test.ts `it.fails` "register_file pointing at shop B's customer…" | `register_file` stores `p_entity_type`/`p_entity_id` without checking the record belongs to the caller's shop. The API checks it (F05 `assertSameOrg`), a direct call with the user's own JWT does not, so shop A can create a file row pointing at shop B's customer (no B data is exposed). | `supabase/migrations/20261005120000_f14_register_file.sql:53-56` |
