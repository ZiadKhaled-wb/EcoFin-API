# INT-3 Stock and cash end to end

**Ticket:** INT-3 (EC-131). **Done when:** the flow works and the stock view, movement history and low-stock alerts (I01, I05, I06) show the right numbers.

## The flow (`src/routes/int3.integration.test.ts`, local stack, runs in the CI integration job)

A fresh shop on the `retail_pro` plan (serials, two branches), the main safe holding 20 000.00, a supplier, a serialized phone and a chair with a minimum of 5 in the main branch.

| Step | Slices | What is checked |
|---|---|---|
| Before stock arrives | I06 | the chair is low in main: 0 of 5, shortage 5 |
| Order 3 phones and 10 chairs, send, receive into a draft invoice, add the three IMEIs, approve | U05, U02, I04 | the order is `received`; three units exist; main holds 3 phones and 10 chairs; the supplier is owed the invoice total; the chair alert is gone |
| Pay the supplier 4 000.00 from the safe | U03, K01 | the balance drops by 4 000.00; the safe holds 16 000.00 |
| Return 2 chairs and one phone for credit | U04 | the balance drops by the return total; main holds 8 chairs and 2 phones; the safe is unchanged |
| Transfer 3 chairs and one phone to North, send, receive | I03 | in transit while on the way; then main 5 chairs / 1 phone, North 3 chairs / 1 phone; the unit is in stock in North |
| Lose one chair (adjustment) | I02, I06 | main holds 4 chairs, the row is low again, shortage 1 |
| A manager opens a shift with a float of 500.00, pays 120.00 of transport from it, closes with 380.00 counted | K02, K03 | the expense carries the shift; expected cash 380.00; no difference; the safe holds 15 880.00 |
| At the end | I01, I05 | the chair's history in main is +10, −2, −3, −1 and adds up to the stock view's 4; the transferred IMEI's history is purchase → transfer out → transfer in; the stock view has exactly four rows, none negative; for every product and branch the stock ledger sum equals `on_hand`, and for every cash account (the safe and the drawer) the cash ledger sum equals the balance |

## Client

- Browser walkthrough of the same shop on the local stack (owner): dashboard, stock, movements, units, transfers, adjustments, purchase orders, invoices, returns, payments, suppliers, vaults, shifts and expenses each load and show the flow's documents and numbers (the safe at 15 880, the shift at 380, the expense of 120), with no console errors.
- Onboarding (P02): `e2e/shop-setup.spec.ts` in EcoFin Web goes through the wizard in Arabic and English against the Sprint 3 server; both pass.

## Not done here

- The same flow on **staging**: it needs the Sprint 3 pull requests merged and deployed first.
- Sales from the shift (S01) are Sprint 4; the shift's cash here is the float and the expense.