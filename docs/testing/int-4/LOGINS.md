# INT-4 local logins (dev seed only)

Seeded by `supabase/seeds/02_dev_data.sql` on `supabase db reset`. **Local dev only**: the password is
the public dev password of every seeded login, `LocalDev-Only-2026!`. Never use these on a real project.

| Shop (slug) | Login (email = username@int4.test) | Role | Branch |
| --- | --- | --- | --- |
| INT4 Shop A (`int4-shop-a`), ETA on (pre-production, fake credentials) | `owner.a@int4.test` | OWNER | INT4 A Main |
| | `manager.a@int4.test` | BRANCH_MANAGER (discount cap 15 %) | INT4 A Main |
| | `cashier.a1@int4.test` | CASHIER (discount cap 5 %) | INT4 A Main |
| | `cashier.a2@int4.test` | CASHIER (check m, second till) | INT4 A Main |
| INT4 Shop B (`int4-shop-b`), ETA off | `owner.b@int4.test` | OWNER | INT4 B Main |
| | `cashier.b@int4.test` | CASHIER | INT4 B Main |

Shop A data: a safe with 5,000.00, the bank account "INT4 Bank", RIN 674859545, activity code 4753,
branch ETA code `0` and building number 14. Products: `INT4-CHAIR` (barcode 6221000000011, ETA code,
20 in stock), `INT4-PHONE` (serialized, 12 months warranty, serials `INT4-SN-001..003`),
`INT4-LAMP` (no ETA code, 10 in stock), `INT4-LAST` (ETA code, 1 in stock). Shop B: a safe with
5,000.00 and `INT4-TABLE` (10 in stock). No POS devices: pairing is part of the flow.

The ETA client ID and secret in the seed (`int4-fake-client` / `int4-fake-secret`) and the POS values
the spec registers (`INT4-POS-1`, `INT4-POS-2`) only work against the local fake ETA
(`npm run fake-eta`, see `docs/testing/ENVIRONMENT.md`).
