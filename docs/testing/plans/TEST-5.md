# TEST-5 Installment money tests

**Ticket:** TEST-5 (EC-136). **Done when:** all pass in CI.

Each requirement of the ticket and the test that proves it. The SQL files run in the CI `db` job (found by a glob), the
`*.integration.test.ts` files in the `integration` job, the contracts tests in `check`. The new file is
`supabase/tests/test5_installment_money_test.sql` (30 checks); the rest was already there and is listed so the ticket has
one place that shows the whole proof.

| Requirement | Proved by |
|---|---|
| Schedule lines always sum exactly to the total payable (many price / duration / rounding combinations) | **test5 part 1:** 108 real installment sales: 3 prices (12 000.00, 999.99, 7 777.77) × 3 down payments (10 %, 25 %, a third, rounded up to the piastre) × 6 counts (1, 5, 6, 7, 13, 24) across three markup tiers, on a whole-pound policy and again on a piastre policy. For every contract: as many lines as installments, every line > 0, lines = `total_payable`, principals = financed, profits = markup, total = cash price − down payment + markup, the tier follows the count, whole pounds on all but the last line. Also: the engine sweep in `packages/contracts/src/installments.test.ts` (3 rounding steps × 7 counts × 3 prices, and the golden cases), the same golden cases in `n01_installment_terms_test.sql`, and N05's rule 5 safety net (`n05_contract_changes_test.sql`: a later version must match its change row) for reschedules and settlements. |
| Payments are allocated in a fixed order: late fees → oldest installment (profit, then principal) → next | There are **no late fees** (`docs/ISLAMIC_FINANCE_RULES.md` rule 4, D79), so the order is: oldest open installment, its profit then its principal, then the next. **test5 part 2:** at the counter (two lines in full, the third's profit then 5.00 of principal; the rows add up to the payment and touch lines 1-3 only); with a later line overdue (the oldest open line is still finished first, then the late line's profit, nothing in between); after a reschedule (version 2's first line, then 1.00 of the next line's profit; nothing on superseded lines); in the field (part 6: the field collection pays the overdue first line). Also `n03_collections_test.sql` (preview and post, determinism) and `n06_collector_wallets_test.sql`. |
| Late fees respect the policy cap and grace days; the job running twice doesn't charge twice | Read with rule 4: **nothing is ever charged**. **test5 part 3:** inside the 3 grace days the line is not overdue and has no warning; one day after, it is overdue with one warning; a second run that day adds nothing; no `charges` row, no policy with a fee, what is owed did not grow; a policy row with a fee can't be stored (`installment_policies_no_late_fee`). Also `n04_overdue_tracking_test.sql` (grace, warning interval, ban, legal days, run twice), the policy API refusing any fee (N04 e2e), and INT-5 (check v2/v3 after a real overdue run). |
| Credit limit is enforced on the server, even when the client sends the request directly | **test5 part 4:** limit 15 000: the first TV (10 000 financed) passes, the second is `CREDIT_LIMIT_EXCEEDED` from the database function, for the manager and for the owner; the refused sale changed nothing (contracts, sales, schedule lines, stock, cash, document numbers, audit rows); 5 000 is still available; a contract row can't be inserted around the functions. **`contracts.integration.test.ts`** (new case): the same refusal through `POST /api/installments/sales` with nothing written. Also `r03_credit_profile_test.sql` (the commit trigger catches an over-limit contract from any path; exceptions), `n02_installment_sale_test.sql`, and INT-5 (a direct API call from the browser's session). |
| Changing the policy affects only new contracts | **test5 part 5:** after version 2 is published, all 54 version 1 contracts and every one of their lines are exactly as before; they still point at version 1, the new ones at version 2; a sale on the old version's terms is `POLICY_CHANGED`. Also `n02_installment_sale_test.sql` and `contracts.integration.test.ts` (old version → `POLICY_CHANGED`). |
| Collector wallet totals equal the cash ledger | **test5 part 6:** a mixed day: two field collections, a reversal while the cash is in the wallet, a partial settlement with a shortage, another collection, a full settlement; after every step the wallet's cached balance = its ledger = the expected amount; the safe got exactly what was handed in; net collections = handed in + shortage + left. Then `app.ledger_mismatches()` is empty for the shop (every stock and cash cache). Also `n06_collector_wallets_test.sql` and `scripts/db-reconcile.mjs` (whole database, after the SQL tests and after the integration tests). |

## How to run locally

```text
npm run db:smoke -- supabase/tests/test5_installment_money_test.sql
RUN_INTEGRATION=1 npx vitest run src/routes/contracts.integration.test.ts
npm run db:reconcile
```

The integration run needs the env of [ENVIRONMENT.md](../ENVIRONMENT.md) (local stack keys, `SMTP_URL` to Mailpit).
