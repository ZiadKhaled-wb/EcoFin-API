# INT-4 · Merge cash sale end to end (EC-133): report

Run on 14 Oct 2026, on the local stack only: Supabase through `npx supabase@2.119.0` (Docker 29.1.3), the
API with its job worker (`JOBS_POLL_SECONDS=5`), the Web dev server, and T02's fake ETA as a process
(`npm run fake-eta`). No real ETA host was called, no remote database was used. Branch
`int/int-4-cash-sale` in both repos.

How to repeat: [ENVIRONMENT.md › INT-4 update](../ENVIRONMENT.md#int-4-update-14-oct-2026): fresh
`db reset`, fresh fake ETA, then `RUN_E2E=1 npx playwright test e2e/int4-cash-sale.spec.ts` in EcoFin-Web.
The spec runs `scripts/int4-verify.mjs` and `scripts/db-reconcile.mjs` at the end. Logins: [LOGINS.md](LOGINS.md).
Evidence files are in `EcoFin-Web/test-results/int-4/` (not committed).

## Result

**15 of 16 checks pass. Check g fails on one open story bug (S04, below). No glue bug was found in the
application code**: every route, header, contract and job the flow uses was already wired. The glue
changes were seed, test tooling and CI.

| # | Check | Result | Evidence |
|---|---|---|---|
| a | Owner creates a device, gets a code; the cashier's browser pairs; shift opened with a float | **PASS** | `a-owner-pairing-code.png`, `a-cashier-shift-open.png`; `GET /api/shifts/current` → `device_id` = the paired device, `opening_float` 500.00 |
| b | Barcode typed + Enter adds the item; serialized product asks for the serial; 5 % accepted | **PASS** | `b-pos-cart.png` (dialog "Serials of INT4 Phone", total 5,950.00) |
| c | 8 % → Ask a manager → manager approves in a second browser context → sale; reuse refused | **PASS** | `c-cashier-waiting.png`, `c-manager-approvals.png`, `c-sale-with-approval.png`; int4-verify c: `approvals.entity_id` = the sale; reuse → 4xx `APPROVAL_INVALID` |
| d | Cash 950 (handed 1,000) + bank transfer 5,000 with reference; change; double-click Pay | **PASS** | `d-payment-split.png`, `d-sale-completed.png` (change 50.00); int4-verify d: 1 sale for the idempotency key |
| e | One transaction: stock, unit, drawer, bank, VAT, number, audit | **PASS** | int4-verify e: stock −qty per line, unit sold, drawer +950, bank +5,000 (= total), `tax_total` 730.71 = Σ lines = T01 (14 % inside the price), number `MAIN-SL-26-000001` first in its sequence, audit `sale.created` |
| f | ETA accepted; the fake recomputed the same UUID; sale 2 `previousUUID` = sale 1 UUID; count per UUID 1 | **PASS** | int4-verify f: both `accepted`, chained, each received once, 0 bad hashes, 0 chain breaks |
| g | Receipt in Arabic: totals, discount, payments, serial, warranty, QR with the fiscal UUID; reprint shows "copy" | **FAIL** (bug INT4-B1) | `g-receipt-ar.png`, `g-receipt-ar-reprint.png`: Arabic preview with totals, both payments, change, serial, the UUID and the QR (int4-verify g: `qr_payload` contains the UUID). Server numbering right (`g-prints.json`: first `{print_no 1, copy false}`, reprint `{print_no 2, copy true}`), but `window.print()` is never called (`marks: []`), so the paper and its COPY mark can't be checked in the dev build |
| h | Fake rejects the next receipt on `itemCode`; monitor shows the reason; code fixed; Correct and resend → accepted with `referenceOldUUID` | **PASS** | `h-monitor-rejected.png` (reason + `itemData[0].itemCode`), `h-monitor-corrected.png`; int4-verify h; fake record: new receipt Valid with `referenceOldUuid` = the rejected UUID |
| i | Product with no ETA code → blocked `ITEM_CODE`; diagnosis names the product; code set → Retry → accepted | **PASS** | `i-monitor-blocked.png` (Retry disabled until fixed), `i-monitor-accepted.png`; int4-verify i: accepted, a `BLOCKED:ITEM_CODE` event |
| j | History by serial, then by number; shop A void after the UUID → "use a return"; shop B (ETA off) void → stock and cash back | **PASS** | `j-history-by-serial.png`, `j-void-refused-shop-a.png` (no Void button, "The ETA receipt has been issued. Use a return."), `j-void-a-response.json` (`409 VOID_FISCALIZED`), `j-void-shop-b.png` ("Sale voided", Voided); int4-verify j: stock net 0, cash net 0 |
| k | Warranty lookup → claim → replace with another in-stock serial; both serials show the chain; damaged +1, sellable −1 | **PASS** | `k-warranty-lookup.png`, `k-warranty-replaced.png`, `k-chain-*.png`; int4-verify k |
| l | Cashier: no ETA monitor menu, `/api/fiscal` 403; shop B never sees shop A sales or receipts | **PASS** | spec l: cashier `GET /api/fiscal` 403, `/api/fiscal/summary` 403, no menu link; owner B: `GET /api/sales/:a` 404, `POST /api/sales/:a/receipt-prints` 404, `GET /api/fiscal/:a` 404 |
| m | Second device; two cashiers sell the last unit at the same moment | **PASS** | `m-responses.json`: `[201 created, 409 OUT_OF_STOCK]`; int4-verify m: 1 sale line, sellable 0 |
| n | POS, receipt, monitor, warranty in Arabic and English | **PASS** | `n-{pos,sale,monitor,warranty}-{ar,en}.png`: `dir` rtl/ltr right, no raw i18n key in the page text, no missing-key console warnings (note: i18next is not in debug mode, so the text scan is the real check) |
| o | Reconciliation; `fiscal_day_summary` counts every receipt, `all_accepted` right | **PASS** | `db:reconcile: passed`; day summary for branch A: total 5, accepted 5, waiting 0, `all_accepted: true`; int4-verify o |
| p | CI: API `check`, `db`, `integration` and Web `check`, `e2e` on pull requests, with the new spec | **PASS, with gaps** | see §p |

`int4-verify.txt` (last run): 11 passed, 0 failed (c, d, e, f, g, h, i, j, k, m, o).

### p · CI

- **EcoFin-API `.github/workflows/ci.yml`** (`on: push [main], pull_request`): `check` (migration
  order, typecheck, lint, format, `npm test`, cross-shop / permission / audit checks, build), `db`
  (start, `db reset`, migrations-twice, every file in `supabase/tests/`, ledger / numbering / stock-cash
  proofs, reconcile), `integration` (`RUN_INTEGRATION=1 npm test`, reconcile). The new
  `src/test/fake-eta-server.test.ts` runs in `check` and `integration`; the dev seed change runs in `db`.
- **EcoFin-Web `.github/workflows/ci.yml`** (`on: pull_request, push`): `check` (typecheck, lint,
  format, test, build) and `e2e` (`npx playwright test`, all of `e2e/`, so `int4-cash-sale.spec.ts` is
  included). This branch adds a step that starts the fake ETA and points the API's `ETA_PREPROD_*`
  hosts at it, with `JOBS_POLL_SECONDS=5` and `E2E_API_DIR=api`.
- **Gaps:**
  1. The Web `e2e` job checks out **EcoFin-API `main`**: the INT-4 spec needs this branch's dev seed
     and `npm run fake-eta`, so **the API PR must merge first**; until then the Web e2e job fails on it.
  2. INT4-g fails in CI until bug INT4-B1 is fixed (the CI e2e runs the dev server, StrictMode on).
  3. Never run by CI: `npm run eta:preprod-smoke` (needs the shop's pre-production credentials: INT-6),
     and anything on a real printer, scanner or POS computer.
  4. CI uses `--workers` default; locally the full e2e suite was run with 2 workers.

## Test totals, before and after

"Before" = `main` with no INT-4 change. The only tests added are `fake-eta-server.test.ts` (3 tests) and
the INT-4 spec (13 tests). The SQL and Web unit "before" figures were measured; the API and Web e2e
"before" figures are **derived** (after minus the INT-4 additions, every existing test passing in the
after run), not a separate run on `main`.

| Suite | Before | After |
|---|---|---|
| API `npm test` (unit; integration files skipped) | 900 passed, 459 skipped | 903 passed, 459 skipped |
| API `RUN_INTEGRATION=1 npm test` | 1,359 / 1,359 | **1,362 / 1,362** (106 files) |
| Contracts | 317 / 317 | 317 / 317 |
| `supabase/tests/*.sql` (fresh `db reset`) | 47 files, 3,102 / 0 | **47 files, 3,102 / 0** (with the new seed and before the smoke fix: 3,101 / 1, see glue fix 2) |
| Proofs: ledger, numbering, stock-cash, reconcile | passed | passed |
| Web `npm test` | 648 / 648 | **648 / 648** (78 files) |
| Web e2e, 2 workers | 26 / 26 | **38 / 39**: the 26 existing pass, INT-4 12 / 13 (g fails: INT4-B1) |
| typecheck / lint / format | green | green, both repos (Web lint: 1 old warning, 0 errors) |

Notes on flakes seen and not counted as failures: Web `SamplePage.test.tsx` (ar) hit its 5 s timeout
while the browser suite ran in parallel and once on a slow power-saving machine; it passes alone and in the
final full run. `tenant_and_permission_test.sql` fails 5 assertions if run **after** the integration
suite on the same database (it assumes a fresh one, as CI gives it); 372 / 0 after `db reset`.

## Glue fixes (this branch)

No application code was changed in either repo. All fixes are seed, tests, tooling, CI or docs.

| # | Commit | Story | What changed |
|---|---|---|---|
| 1 | `INT-4: cash sale end to end` (API) | S01–S12, T02, T03, O03 (dev data) | `supabase/seeds/02_dev_data.sql`: shops `int4-shop-a` (ETA on, preprod, fake creds, RIN, activity code, branch ETA code + building number, safe 5,000, bank account, OWNER / BRANCH_MANAGER / 2 CASHIERs, caps 5 / 15, chair, serialized phone 12 m with 3 serials, lamp without ETA code, last-unit product) and `int4-shop-b` (ETA off, a product, a cashier), made through the real write functions as each owner. No devices. Dev seed only |
| 2 | same | test tooling | `supabase/tests/smoke_test.sql:148`: "cash: balance and branch copied" read `cash_movements LIMIT 1` without a filter, so it assumed the table was empty; it now reads its own account's movement. Same assertion, now on the row it meant (it failed only because the seed now has cash movements) |
| 3 | same | T02 (test tooling) | `src/test/fake-eta.ts`: optional fixed port and extra POS devices; `src/test/fake-eta-server.ts` + `npm run fake-eta`: the fake as a process on 127.0.0.1:4010 with controls on 127.0.0.1:4011 (`invalid-next`, `fail-next` accept-then-drop / 503 / 422, `in-progress`, `state` with counts per UUID); test `fake-eta-server.test.ts`. Not imported by the app, not in the build (checked: 0 matches in `dist/server.js`) |
| 4 | same | INT-4 | `scripts/int4-verify.mjs`: the database checks (service role, local URL only) |
| 5 | `INT-4: cash sale end to end` (Web) | INT-4, T02 (CI) | `e2e/int4-cash-sale.spec.ts`; `.github/workflows/ci.yml` e2e job starts the fake ETA and sets `ETA_PREPROD_*`, `JOBS_POLL_SECONDS=5`, `E2E_API_DIR` |
| 6 | API | docs | `docs/testing/ENVIRONMENT.md` (INT-4 section), `int-4/LOGINS.md`, this report, `STAGING_CHECKLIST.md`, TEST_PLAN rows |

## Open bugs

| ID | Severity | Story | Where | Proposed Jira title |
|---|---|---|---|---|
| INT4-B1 | **Medium** | S04 (EC-71) | `EcoFin-Web/src/features/receipts/PrintReceipt.tsx:173-179` (`aliveRef` set `false` in an effect cleanup, never set back to `true`) and `:197` (`if (!aliveRef.current) return;` before `window.print()`) | "S04: Print logs the receipt print but never opens the print window under React StrictMode (aliveRef cleared by the dev effect re-run)" |
| INT4-B2 | Low | T03 (EC-91) | `EcoFin-API/supabase/migrations/20261014090000_t03_eta_monitor.sql:223` (diagnosis builds `'name', q.name_ar`), shown by `EcoFin-Web/src/pages/tax/FiscalDrawer.tsx:67` | "T03: ETA monitor diagnosis shows the product's Arabic name in the English UI (no name_en fallback)" |

INT4-B1 detail: in development React StrictMode mounts, unmounts and remounts every component once;
the cleanup sets `aliveRef.current = false` and nothing sets it back. Every click on **Print** then
records a print on the server (`POST /api/sales/:id/receipt-prints` → print number, audit
`sale.receipt_printed`) and returns before `window.print()`: nothing is printed, the dialog stays
open, and the next attempt is numbered as a **copy** although no original was ever printed. A
production build does not re-run effects, so it is probably not affected, but that must be checked
on staging (INT-6, step g). Not fixed here: it is inside S04's logic and touches printed fiscal
documents. Fix suggestion for the S04 owner: set `aliveRef.current = true` in the effect body.

## Environment fixes

- `.env.local` (git-ignored) holds the API's local env; `dotenv` reads only `.env`, so it is loaded
  into the shell (`set -a; . ./.env.local; set +a`). A value with `<` or spaces must be quoted
  (`MAIL_FROM="EcoFin <support@ecotech.test>"`).
- The API needs `SMTP_URL=smtp://127.0.0.1:54325` and `MAIL_FROM` locally (as CI sets them); without
  them the INT-2 `shop-setup` e2e fails with "no invite email" (environment only, not a bug).
- The fake ETA keeps its POS chain in memory, and a device's ETA serial is unique in the database:
  run INT-4 from a fresh `db reset` and a freshly started fake ETA.
- Playwright empties `test-results/` at the start of every run; to rerun one check (`-g "h:"`) without
  losing `test-results/int-4/run.json`, pass `--output=<another folder>`.
- `NODE_OPTIONS=--no-network-family-autoselection` for every npm / node command on this machine.

## EC-133

"Done when": the full flow passes locally (API + Web e2e): **all but g**; every suite green: **yes,
except the INT-4 e2e check g**; the report lists every check with evidence: **yes**. Check g fails on an
open story bug (INT4-B1), which the rules allow when the failing check is listed as an open bug.
EC-133 can move to **In Review**, with INT4-B1 linked as a blocker for the staging print step (INT-6 g).
Merge order: **EcoFin-API first**, then EcoFin-Web (its CI uses API `main`).
