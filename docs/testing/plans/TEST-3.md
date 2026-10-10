# TEST-3 Stock and cash reconciliation tests

**Ticket:** TEST-3 (EC-132). **Done when:** all pass in CI.

Each requirement of the ticket and the test that proves it. Everything below runs in the CI `db` job (SQL files are found by a glob; the proofs are their own steps) or in the `integration` job.

| Requirement | Proved by |
|---|---|
| For every product and branch: stock level = sum of the stock ledger, never below zero | `supabase/tests/test3_reconciliation_test.sql` part 1, after a full day (purchase with IMEIs, payments, cash return, transfer, adjustments, opening unit, shift, expenses); `app.ledger_mismatches()` is empty. `scripts/db-reconcile.mjs` checks the whole database after the SQL tests and again after the integration tests. `src/routes/int3.integration.test.ts` sums the ledgers through the API's own writes. |
| For every vault, bank and drawer: balance = sum of the cash ledger | The same SQL file, part 2: a safe, a bank and a shift drawer all moved that day; each balance equals its ledger sum and the expected amount. `db-reconcile.mjs` and INT-3 as above. |
| Nothing goes below zero | Part 3: a loss and a transfer of more than is left (`OUT_OF_STOCK`), an expense and a supplier payment of more than the account holds (`INSUFFICIENT_FUNDS`); the caches and the stock ledger can't be written directly; the ledger triggers themselves refuse a row that would go below zero. |
| Concurrency: two adjustments or two sales of the last unit at the same moment → one succeeds, one is rejected; nothing goes negative | `scripts/db-stock-cash-proof.mjs` (`npm run db:stock-cash`), the real functions called by a signed-in owner from 20 concurrent sessions: **A** 20 loss adjustments for the last chair → 1 posts, 19 `OUT_OF_STOCK`; **B** 20 write-offs of one IMEI unit → 1; **C** 10 adjustments racing 10 branch transfers for the last chair → 1 of 20; **D** 20 expenses of 1 000.00 from a safe holding 1 000.00 → 1 paid, 19 `INSUFFICIENT_FUNDS`; refused calls leave no document and take no number; levels and the safe end at exactly 0; no deadlocks; **E** everything reconciles. Sales themselves are S01 (Sprint 4): the sale race on the ledger (100 sales of the last 10 units, 50 requests with one key) is `scripts/db-ledger-proof.mjs` (F10). Parallel requests with one idempotency key through the API: `shifts.integration.test.ts` and `expenses.integration.test.ts`. |
| An IMEI unit can't be in two places or sold twice | Part 4: every unit in stock has a positive ledger sum in exactly one branch; a serial can't be registered twice; the unit moved to the second branch can't be written off, transferred or sold in the first; a unit returned to the supplier can't be sold; a sold unit can't be sold again. Also `i04_units_test.sql` (Done when cases) and `i03_transfers_test.sql`. |
| Purchase approval by amount (U06) blocks unapproved invoices on the server | Part 5: with a threshold of 10 000, a manager's approval of a 20 000+ invoice answers `pending_approval` and posts no stock and no supplier balance; the manager can't approve it again (`APPROVAL_OWNER_ONLY`); it can't be paid (`ALLOCATION_INVALID`); the owner's approval posts it. The full rules: `u06_purchase_approval_test.sql` and `purchaseInvoices.integration.test.ts`. |

## How to run locally

```text
npm run db:smoke -- supabase/tests/test3_reconciliation_test.sql
npm run db:stock-cash
npm run db:reconcile
```