# INT-1 local test logins (LOCAL DEV ONLY)

From `supabase/seeds/01_super_admin.sql` and `02_dev_data.sql`, loaded by `supabase db reset`.
Every password below is the public local-dev password **`LocalDev-Only-2026!`**. Never use these on a real project.

| Login (email / username) | Shop (tenant_slug) | Role | Branch |
|---|---|---|---|
| owner.one@ecotech.test / owner.one | Shop A `dev-shop-one` | OWNER | all (BR1 main, BR2) |
| cashier.one@ecotech.test / cashier.one | Shop A `dev-shop-one` | CASHIER | BR1 |
| owner.two@ecotech.test / owner.two | Shop B `dev-shop-two` | OWNER | all (BR1 main) |
| cashier.two@ecotech.test / cashier.two | Shop B `dev-shop-two` | CASHIER | BR1 |
| multi.shop@ecotech.test / multi.shop | both: Shop A and Shop B | CASHIER in A, ACCOUNTANT in B | BR1 in each |
| superadmin@ecotech.test | platform | super admin | n.a. |

Fixed ids: shops `d1000000-0000-0000-0000-00000000000{1,2}`, branches `d2000000-...-0000000000{11,12,21}`,
employees `d3000000-...-0000000000{11,12,21,22}` and `...{19,29}` (two-shop login).

Local URLs: API `http://localhost:3001`, Web `http://localhost:5173`, Supabase `http://127.0.0.1:54321`, Mailpit `http://127.0.0.1:54324`.
