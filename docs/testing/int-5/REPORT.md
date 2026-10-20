# INT-5 · Merge installment lifecycle end to end (EC-135): report

Run on 20 Oct 2026, on the local stack only: Supabase through `npx supabase@2.119.0` (own project
`ecofin-api-int5`, default ports), the API from `main` + this branch (`npm start`, job worker on,
SMTP to the local Mailpit), the Web dev server, T02's fake ETA. No remote database and no staging:
GitHub Actions is still blocked by billing, so nothing new is deployed to dev (see
[local CI](../ENVIRONMENT.md)). Branch `int/int-5-installment-lifecycle` in both repos.

How to repeat: fresh `db reset`, API on :3001, then in EcoFin-Web
`RUN_E2E=1 E2E_API_DIR=<this repo> npx playwright test e2e/int5-installment-lifecycle.spec.ts`
(the CI env of the Web `e2e` job). The spec provisions its own shop, so it shares nothing with the
other specs, and runs `scripts/int5-db.mjs` for the two things only the database can do: move a
contract's due dates into the past (`backdate`) and the checks below (`verify`). Results land in
`EcoFin-Web/test-results/int-5/` (`run.json`: ids and amounts only; `int5-db-verify.txt`).

## Result

**Every step passes; all 6 database checks pass.** No bug was found in the application code: every
route, screen, permission and job the flow uses was already wired. The glue is test tooling only
(the spec, `scripts/int5-db.mjs`, this report).

| # | Step (ticket line) | Stories | Result | How it is checked |
|---|---|---|---|---|
| 1 | New customer on the customers screen | R01 | **PASS** | UI: Add customer (name, national ID, phone, address, city, income) → row in the list → customer page |
| 2 | Guarantor | R04 | **PASS** | UI: Add guarantor, new person, relation Father → shown on the card |
| 3 | Field survey | R05 | **PASS** | UI: owner assigns a home visit to the collector; the collector fills six ratings, six checklist answers, the location (browser geolocation, 15 m) and a photo, submits; the owner approves → `approved` |
| 4 | Credit limit checked | R03 | **PASS** | UI: Set limit 30,000.00 with a reason. Server: a second sale above the available credit sent straight to `POST /api/installments/sales` → `409 CREDIT_LIMIT_EXCEEDED` |
| 5 | Installment sale: terms preview, contract | N01, N02 | **PASS** | UI at the till: Installments → terms (Credit: OK, total) → down payment → done card with the contract; the schedule sums to `total_payable` |
| 6 | Printed contract and promissory notes | N07 | **PASS** | From the done card: the contract paper with its number, an original (no COPY mark), print counted; the notes, one per installment, print counted; no "interest" anywhere |
| 7 | Collector takes a payment into the wallet | N06 | **PASS** | UI: the owner assigns the customer to the collector; the collector collects the first installment in the field (no shift) → receipt "Collected in the field", wallet = that installment, safe unchanged |
| 8 | Hand-over to the vault | N06 | **PASS** | UI: a branch manager settles the wallet into the safe, all but 100.00 (partial) → wallet 100.00, safe + the handed amount |
| 9 | Another contract settled early | N05 | **PASS** | UI: Settle early with the policy's suggestion (50 % of future profit), reason, payment → receipt; contract `completed`, 0.00 left |
| 10 | An overdue installment (see the note on late fees) | N04 | **PASS** | `int5-db.mjs backdate`: the next installment of contract 1 is 10 days late. UI: Run the check now → "1 new warnings, 0 customers blocked, 0 legal referrals"; the contract is listed; a second run the same day → 0 new; the Warnings tab lists it. What the contract owes is unchanged |
| 11 | The customer account shows everything | R02 | **PASS** | API: open balance = what is left on contract 1; both contracts with their status. UI: Account tab shows both numbers, the open balance, the overdue amount, "Completed"; Arabic is right to left with no "فائدة" |

### Database checks (`scripts/int5-db.mjs verify`)

| # | Check | Result |
|---|---|---|
| v1 | Every contract adds up to the piastre: current lines + paid on superseded lines = `total_payable − profit waived` (D74, N05) | **PASS** (2 contracts) |
| v2 | No late fee anywhere: no `charges` row, every policy version `late_fee_type = none` | **PASS** |
| v3 | The late contract has one warning; its overdue amount is the late installment and what it owes did not grow | **PASS** (1,080.00 overdue, 10 days, 11,880.00 left) |
| v4 | The early-settled contract is `completed` with 0.00 left | **PASS** |
| v5 | The collector's wallet balance equals its cash ledger and the flow's arithmetic | **PASS** (100.00 = 100.00) |
| v6 | Every cached balance in the shop matches its ledger (`app.ledger_mismatches()`, F10) | **PASS** |

## Differences from the ticket text

- **"An overdue installment gets a late fee" is replaced by "an overdue installment gets a
  warning, never a fee".** Late fees are forbidden (`docs/ISLAMIC_FINANCE_RULES.md` rule 4, D79):
  the policy refuses any fee and the overdue check only warns, blocks or refers. The flow proves
  the forbidden part instead (v2, v3, step 10).
- **Staging → the local stack.** Deploys are blocked with Actions. The same spec runs in the Web
  CI `e2e` job once Actions works again (it needs only what that job already starts, plus `docker`
  for the database container, which the job has).
- **Collector commission:** none (N06 owner decision); nothing in the flow shows one.
- **Credit score:** the shop's minimum score is set to 0 so the limit is the gate here; the score
  rules have their own tests (R03).

## Wrap-up

- Docs: no product doc changed. graphify is not installed (no `graphify-out/`), so nothing to rebuild.
- Merge: two PRs (API: script + report; Web: the spec). They don't depend on each other's code, but
  the Web spec runs the API script, so merge the API one first.
