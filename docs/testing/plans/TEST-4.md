# TEST-4 · Sales tests (EC-134)

| Jira point | Existing CI test file: name | Gap / added coverage |
|---|---|---|
| 1. Idempotency | s01_sale_core_test.sql: same key; sales.integration.test.ts: cashier sells once; s07_sales_history_test.sql: idempotent replay; s12_warranty_test.sql: open same key replay | Generic catalog guard for all 21 authenticated public definers; full replay snapshots; five concurrent API submissions. |
| 2. Atomicity | S01/S02/S03 SQL: refused calls leave nothing behind; S07 closed-shift refusal; S12 replacement unavailable | All public tenant row counts, complete counters and balance/unit states; three-line failures; final audit failures for void and replacement. |
| 3. Payments and discounts | s02_split_payments_test.sql: payment refusals and ledger reconciliation; s03_discounts_test.sql: 5% cap, stacking, approvals and tax; discounts.integration.test.ts: approvals and server rejection; S01 price overrides and audit | Exists for existing refusals; new 200-sale seeded SQL property and snapshot assertions, exact 5.01% API boundary, wrong cashier/cart through API, ten-round approval race. |
| 4. ETA | eta.integration.test.ts: accepted-then-drop lookup, 503 retry and receipt hash/chain; t03.integration.test.ts: rejected reason, USE_CORRECTION, correction, alerts and correction race | Existing timeout/rejection paths reused; 5000 arithmetic snapshots, three-sale outage with increasing attempts and monitor counts; correction race extended to ten rounds. |
| 5. Languages | int4-cash-sale.spec.ts: split sale in English, receipt in Arabic; n: translated pages in both languages | Two independent full POS sales (ar/en), shared INT-4 fixtures, exact database receipt amounts and SVG QR payload. |

Tests and tooling only; application code and dependency versions are unchanged. The user's API push/PR instruction overrides the execution document's no-push rule. Web remains unpushed.

## Added and strengthened tests

| Test ID | Done-when item | Type | Automated file: test name | Status |
|---|---|---|---|---|
| TEST4-01 | generic completeness: every authenticated public definer with an idempotency argument is explicitly registered | SQL | supabase/tests/sales_idempotency_test.sql | validated locally |
| TEST4-02 | sale repeats same id | SQL | supabase/tests/sales_idempotency_test.sql | validated locally |
| TEST4-03 | sale different arguments returns original unchanged | SQL | supabase/tests/sales_idempotency_test.sql | validated locally |
| TEST4-04 | shift repeats same id | SQL | supabase/tests/sales_idempotency_test.sql | validated locally |
| TEST4-05 | repeat sale and shift take no rows, balances or document counters | SQL | supabase/tests/sales_idempotency_test.sql | validated locally |
| TEST4-06 | TEST4-B2 client price rejected rather than ignored (known failure) | SQL | supabase/tests/sales_atomicity_test.sql | validated locally (known failure) |
| TEST4-07 | line 3 out of stock | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-08 | underpaid three-line sale | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-09 | store credit above balance | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-10 | line 3 discount beyond cashier cap | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-11 | stacking line and sale beyond cap | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-12 | negative payment | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-13 | non-cash above total | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-14 | transfer without reference | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-15 | credit for walk-in | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-16 | other shop account | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-17 | other branch account | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-18 | line 2 serial already sold | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-19 | TEST4-B1 revoked direct device still accepted (known failure) | SQL | supabase/tests/sales_atomicity_test.sql | validated locally (known failure) |
| TEST4-20 | void fails at final audit insert | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-21 | replacement fails at final audit insert | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-22 | shift closed after cart built | SQL | supabase/tests/sales_atomicity_test.sql | validated locally |
| TEST4-23 | seed 0.4242 case  | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-24 | seed 0.4242 case  | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-25 | seed 0.4242 case  | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-26 | seed 0.4242 case  | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-27 | seed 0.4242: drawer increased by cash minus change | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-28 | 200 sales posted | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-29 | all stock equals ledgers | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-30 | all cash equals ledgers | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-31 | all store credit equals ledgers | SQL | supabase/tests/sales_money_properties_test.sql | validated locally |
| TEST4-32 | 5000 seeded ETA snapshots obey every arithmetic and exact-byte UUID rule | unit | src/eta/build-receipt.property.test.ts | API CI passed; Web e2e pending |
| TEST4-33 | five concurrent requests and last unit on two devices (10 rounds) | integration | src/routes/sales.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-34 | TEST4-B2: unprivileged client price is ignored by the API (expected failure) | integration | src/routes/sales.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-35 | one approval cannot authorize two concurrent sales (10 rounds) | integration | src/routes/discounts.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-36 | server refuses 5.01% and stacked discounts before writing; other cashier/cart cannot use approval | integration | src/routes/discounts.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-37 | void and warranty claim on one sale have one winner (10 rounds) | integration | src/routes/warranty.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-38 | three outage receipts grow attempts, appear in monitor, recover in order and clear alerts | integration | src/eta/eta.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-39 | two corrections at once give one 202, one 409 and one new UUID (10 rounds) | integration | src/eta/t03.integration.test.ts | API CI passed; Web e2e pending |
| TEST4-40 | full POS sale and prepared QR receipt in ar | e2e | e2e/sale-languages.spec.ts | API CI passed; Web e2e pending |
| TEST4-41 | full POS sale and prepared QR receipt in en | e2e | e2e/sale-languages.spec.ts | API CI passed; Web e2e pending |

The existing replay assertions in P05, K01, I02, I03, I04, U02, U03, U04, U05, K02 and K03 now also compare a complete snapshot. Existing S07/S12 replays and refusal assertions retain their checks and add snapshots. No existing assertion is removed or relaxed.

## Idempotency registry

The completeness guard compares pg_proc/pg_namespace, SECURITY DEFINER, authenticated EXECUTE and argument names containing idempotency against explicit regprocedure signatures, including overloads. The fixture snapshot counts every public tenant table and records full document counters, stock/cash/credit caches and unit state, so non-sales write functions are covered too.

| Function | Existing CI SQL file | Same key, different arguments |
|---|---|---|
| admin_record_subscription_payment | supabase/tests/p05_subscription_test.sql | original |
| create_cash_transfer | supabase/tests/k01_vaults_test.sql | original |
| post_cash_opening | supabase/tests/k01_vaults_test.sql | original |
| create_invoice_from_po | supabase/tests/u05_purchase_orders_test.sql | original |
| create_purchase_order | supabase/tests/u05_purchase_orders_test.sql | original |
| create_purchase_invoice | supabase/tests/u02_purchase_invoices_test.sql | original |
| post_purchase_return | supabase/tests/u04_purchase_returns_test.sql | original |
| post_supplier_payment | supabase/tests/u03_supplier_payments_test.sql | original |
| reverse_supplier_payment | supabase/tests/u03_supplier_payments_test.sql | IDEMPOTENCY_CONFLICT |
| create_stock_count | supabase/tests/i02_stock_adjustments_test.sql | original |
| post_stock_count | supabase/tests/i02_stock_adjustments_test.sql | IDEMPOTENCY_CONFLICT |
| post_stock_adjustment | supabase/tests/i02_stock_adjustments_test.sql | original |
| create_stock_transfer | supabase/tests/i03_transfers_test.sql | original |
| register_units | supabase/tests/i04_units_test.sql | original |
| open_shift | supabase/tests/k02_shifts_test.sql | original |
| move_shift_cash | supabase/tests/k02_shifts_test.sql | IDEMPOTENCY_CONFLICT |
| post_expense | supabase/tests/k03_expenses_test.sql | original |
| reverse_expense | supabase/tests/k03_expenses_test.sql | IDEMPOTENCY_CONFLICT |
| post_sale | supabase/tests/sales_idempotency_test.sql | original |
| void_sale | supabase/tests/s07_sales_history_test.sql | IDEMPOTENCY_CONFLICT for another sale |
| open_warranty_claim | supabase/tests/s12_warranty_test.sql | IDEMPOTENCY_CONFLICT |

Original means the existing result is returned with no second document. Conflict behavior is checked by the respective existing cases where present and verified against the local function definition. Approval request/decision functions do not take an idempotency parameter and are outside this registry; their single-use behavior is tested separately.

## Reproducibility and fixture limits

- SQL seed 0.4242, 200 sales, one shift, 1–4 lines, 1–5 units, both VAT modes, discounts below 5%, cash/bank/store-credit splits and cash change. Every failure prints the seed, case, cart and payments. Final reconciliation includes every cache and the drawer's exact net cash.
- ETA seed 4242, 5000 cases, 1–4 lines, quantities 1–20, prices 0.01–99999.99, up to three discounted lines and optional document discounts. T01/F12 build the stored snapshot; precision, spec tolerance, header/line amounts and fake ETA byte-parser UUID are checked. The 0% cases exercise both zero-rated and exempt codes.
- Each new unit/integration/browser test is bounded at 60 seconds; SQL statement timeout is 60 seconds for the random suite. Language fixtures are isolated from INT-4's seeded users and POS chain.
- Invalid tax class on the last line cannot be introduced through an authenticated cart: the class comes from the server's product and composite foreign keys require a valid class in that shop. This single case is omitted rather than disabling integrity constraints or changing app code.
- Final-step rollback is forced with a transaction-local test trigger on the final audit insert, for both void and replacement; full snapshots are identical afterwards.
- API npm ci was attempted twice and failed on workspace symlink creation (EISDIR); this filesystem also rejects junctions. npm ci --workspaces=false succeeded. Contract dependencies were clean-installed from the same root lockfile through a temporary test runtime, and the local workspace package copied to node_modules. No manifests/lockfiles changed; normal Linux CI uses npm ci unchanged.

## Required CI jobs

API: **CI / check**, **CI / db**, **CI / integration**. Web: **CI / check**, **CI / e2e**. Existing job IDs remain unchanged. SQL is discovered by the existing glob; all integration files run with RUN_INTEGRATION=1. Web starts the local fake ETA and API worker, uses two workers and saves the HTML report and logs on failure. Every job prints known-failure markers to its summary.

Web e2e needs the API TEST-4 PR merged into main before its own PR is checked: its workflow checks out API main, which must contain test4-language-fixture.mjs and the extended int4-verify.mjs.

## Bugs

| ID | Test | Problem | Proposed Jira title |
|---|---|---|---|
| TEST4-B1 | supabase/tests/sales_atomicity_test.sql:55, revoked direct device | Authenticated post_sale accepts a revoked pairing token when called directly; API device middleware cannot protect this path. The known-bug block rolls the successful sale back and raises if behavior changes. | Reject revoked POS devices in direct sale RPC calls |
| TEST4-B2 | supabase/tests/sales_atomicity_test.sql:20; src/routes/sales.integration.test.ts:541, ignored client price | An unprivileged client unit_price is rejected with PRICE_OVERRIDE_DENIED, while TEST-4 requires it to be ignored in favor of the server price. Existing S01 rejection tests remain intact; the new requested behavior is an expected failure. | Ignore unauthorized client unit prices when posting sales |

## Full local CI results

API full local CI passed on 14 October 2026: check, db and integration. All 50 SQL files passed, migration replay and seeded admin checks passed, all concurrency proofs passed, and ledgers reconciled after SQL and integration.

| Suite | Before TEST-4 | After TEST-4 |
|---|---|---|
| API unit (default npm test) | 903 passed / 459 integration-skipped; 106 files total | 904 passed / 465 integration-skipped; 107 files total |
| API full RUN_INTEGRATION=1 | 1362 passed / 106 files | 1368 passed + 1 expected failure / 107 files |
| Contracts | 317 tests / 32 files | 317 tests / 32 files |
| SQL | 3103 assertions / 47 files | 3973 assertions / 50 files |
| Web e2e discovery | 41 tests / 10 files | 43 tests / 11 files; execution follows the API PR |

Before counts are derived from the unchanged baseline plus added-test deltas; the after counts are observed full runs. Unit/integration skips in the default unit job are enabled by RUN_INTEGRATION=1 in the separate job. SQL includes the two explicitly checked known-bug blocks; the API expected failure is TEST4-B2. Web unit/check/e2e validation is recorded in the Web copy after its local CI run.

## Changed API files

- `.github/workflows/ci.yml`
- `docs/testing/TEST_PLAN.md`
- `docs/testing/plans/TEST-4.md`
- `scripts/db-smoke.mjs`
- `scripts/int4-verify.mjs`
- `scripts/test4-known-failures.mjs`
- `scripts/test4-language-fixture.mjs`
- `scripts/test4-prepare.mjs`
- `src/eta/build-receipt.property.test.ts`
- `src/eta/eta.integration.test.ts`
- `src/eta/t03.integration.test.ts`
- `src/routes/discounts.integration.test.ts`
- `src/routes/sales.integration.test.ts`
- `src/routes/warranty.integration.test.ts`
- `src/test/fake-eta-server.ts`
- `supabase/tests/helpers/test4_setup.sql`
- `supabase/tests/helpers/test4_snapshot.sql`
- `supabase/tests/i02_stock_adjustments_test.sql`
- `supabase/tests/i03_transfers_test.sql`
- `supabase/tests/i04_units_test.sql`
- `supabase/tests/k01_vaults_test.sql`
- `supabase/tests/k02_shifts_test.sql`
- `supabase/tests/k03_expenses_test.sql`
- `supabase/tests/p05_subscription_test.sql`
- `supabase/tests/s07_sales_history_test.sql`
- `supabase/tests/s12_warranty_test.sql`
- `supabase/tests/sales_atomicity_test.sql`
- `supabase/tests/sales_idempotency_test.sql`
- `supabase/tests/sales_money_properties_test.sql`
- `supabase/tests/u02_purchase_invoices_test.sql`
- `supabase/tests/u03_supplier_payments_test.sql`
- `supabase/tests/u04_purchase_returns_test.sql`
- `supabase/tests/u05_purchase_orders_test.sql`
