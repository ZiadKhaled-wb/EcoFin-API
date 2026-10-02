# EcoTech Pro: Slices (Final, v1.0)

*Decided by the team on 2 Oct 2026. Based on the Architecture Review and the code audit. Slice IDs are permanent: never renumber, only add.*

---

## How to read this

**A slice** is one feature from end to end: database, API, screen and tests. Each slice becomes 1–3 agent tasks later (backend, frontend, tests), all built against the same shared contract.

| Field | Meaning |
|---|---|
| **Plan** | **V1** = launch version · **V2** = after launch · **Drop** = not planned |
| **Agent** | **Smart**: a smart agent designs and builds it. **Spec→Free**: a smart agent writes the spec, a free agent builds it, a smart agent reviews it. **Free**: a free agent builds from a ready spec. **Manual**: done by a person. |
| **Reuse** | **Port**: adapt the old code to the new spec. **Rewrite**: old code exists but is wrong. **New**: nothing to reuse. |
| **Depends on** | Slices that must be done first |
| **Done when** | The checks that prove the slice is finished. The audit and the reviewer use these. |

**Rules that apply to every slice:**
- Every table has `organization_id`. The org comes from the login token, never from the request.
- Money uses the shared decimal type (F12). Never JavaScript floats.
- Stock and cash change **only** by writing ledger entries (F10). Nothing edits a balance directly.
- Issued documents (receipts, invoices, contracts, returns) are never edited. Corrections are linked reversals.
- Every request and response shape lives in the shared contracts (F03).
- Every write that matters goes to the audit log (F07).
- Every screen works in Arabic (RTL) and English.

**V1 decisions in short:**
- **Financing:** in-house installments only. Third-party financing and card payments move to V2.
- **Verticals:** furniture **and** electronics, so serial/IMEI units, quotes, orders, delivery and warranty are all in V1.
- **Installment rules:** built new on the server. Nothing is reused from the old X-Core engine.

---

## Summary

| Area | V1 | V2 | Drop |
|---|---|---|---|
| 0. Foundation | F01–F14 | | |
| 1. Platform | P01–P05 | P06 | |
| 2. Organization | O01–O02 | | |
| 3. Catalog | C01–C03 | C05 | C04 |
| 4. Inventory | I01–I06 | | |
| 5. Purchasing | U01–U06 | | |
| 6. Cash management | K01–K04 | | |
| 7. Customers | R01–R05 | | |
| 8. Sales / POS | S01–S12 | | |
| 9. In-house installments | N01–N07 | N08–N09 | |
| 10. Third-party financing | | X01–X04 | |
| 11. Card payments | | Y01–Y02 | |
| 12. Tax and ETA | T01–T04 | | |
| 13. Reports | D01–D05 | D06–D07 | |
| 14. Data in and out | M01–M03 | | |
| 15. Operations | Q01–Q05 | | |
| 16. Legal | L01 | | |
| 17. Notifications | ❓ Z01 (undecided) | | |
| 18. Later / out | | H01, H02, W01, B01–B05, B06–B07 | A01 |

---

# 0. Foundation

Built first. Everything else depends on it. Mostly smart agents.

### F01 · Repo setup and CI
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** none
**What it does:** sets up the two repos (server and client) with the same standards, so every agent works the same way.
**Includes:**
- TypeScript in strict mode in both repos, ESLint, Prettier, the same Node version pinned
- npm scripts: `dev`, `build`, `typecheck`, `lint`, `test`
- CI on every pull request: type-check, lint, tests, build. A failing check blocks the merge.
- A `CONTRIBUTING.md` with the rules above and how to run the project
- `.env.example` files with every variable documented

**Done when:** a fresh clone runs with the documented steps; CI fails on a type error, lint error or failing test.

### F02 · Database migrations and conventions
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F01
**What it does:** makes the database rebuildable from the repo, and makes every schema change a reviewed file.
**Includes:**
- Supabase CLI migrations (plain SQL files in `supabase/migrations/`); a fresh empty database builds from zero with one command (`supabase db reset`). Drizzle is used only for typed queries, not migrations. Table and column spec: `docs/EcoTech_Pro_Data_Model.md`
- Separate seed script for dev data and for the first super admin
- Table conventions: `id` (uuid), `organization_id`, `created_at`, `updated_at`, `created_by`; money as `numeric(18,2)`; status fields as real enums; soft delete (`archived_at`) instead of hard delete for business records
- Foreign keys use `(id, organization_id)` so a row can't point to another shop's row
- No `ON DELETE CASCADE` on money or stock records

**Done when:** `migrate` on an empty database succeeds; running it twice changes nothing; the seed creates a working super admin.

### F03 · Shared contracts
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F01
**What it does:** one place that defines every request and response, so the server and client can't disagree about names or shapes.
**Includes:**
- A shared package (npm package or git submodule, since the repos are separate) with zod schemas and exported TypeScript types
- One schema per endpoint: request body, query, params, response
- The standard error shape and the list of error codes
- The shared list of permission keys and roles (used by F06)
- Version number, bumped on every change

**Done when:** both repos import the same package version; changing a field breaks the build on the side that wasn't updated.

### F04 · Auth and sessions
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite (the partner may have started this; the audit will tell) · **Depends on:** F02, F03
**What it does:** logs users in and out safely, and never mixes one user's session with another's.
**Includes:**
- Login with email or username + password (Supabase Auth)
- Access token + refresh token; the client refreshes silently before expiry
- Real logout that revokes the session on the server
- Forgot-password email and a working reset-password page
- Per-request database access: no shared client that keeps a user session
- Login blocked for inactive users, inactive shops and expired subscriptions (P05)
- Failed-login tracking and rate limiting

**Done when:** two users from two shops log in one after the other and each request still runs as its own user; a token works after refresh; logout makes the old token fail; the reset email leads to a page that changes the password.

### F05 · Tenant isolation
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F02, F04
**What it does:** guarantees that one shop can never see or change another shop's data.
**Includes:**
- Middleware that loads the user and their `organization_id` once per request; every query is scoped by it
- Every foreign id in a request (product, vault, customer, invoice…) is checked to belong to the same shop
- Request bodies are whitelisted by the contract (F03); fields like `organization_id` can never be set by the client
- Database grants removed from the `anon` and `authenticated` roles; the frontend never talks to the database directly
- Private file storage paths include the org id
- An automated test suite that creates two shops and tries to read and write across them through **every** endpoint, file and export

**Done when:** the cross-shop test suite runs in CI and passes; adding a new endpoint without a cross-shop test fails a CI check.

### F06 · Roles and permissions
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F03, F05
**What it does:** controls what each employee can see and do, per action and per branch.
**Includes:**
- Roles: Owner, Branch Manager, Cashier, Warehouse, Collector, Accountant, Lawyer (plus Super Admin at platform level)
- Each role has a default set of permissions; the owner can add or remove permissions per employee
- Action permissions, not just pages: e.g. `sale.create`, `sale.void`, `price.override`, `discount.above_cap`, `refund.create`, `credit.approve`, `schedule.change`, `cash.adjust`, `stock.adjust`, `export.data`, `customer.view_pii`
- Branch scope: an employee works in their assigned branches only; the owner sees all
- The server checks every endpoint; the client hides what the user can't do

**Done when:** each permission has a test proving a user without it gets 403; the client and server use the same permission keys from F03.

### F07 · Audit log
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F02, F05
**What it does:** records who did what, so the owner can trust and investigate everything.
**Includes:**
- Written in the same database transaction as the change (if the change fails, no log; if the log fails, no change)
- Stores: user, branch, device, IP, time, action, record, reason (required for sensitive actions), values before and after
- Append-only: no update or delete, even for the owner
- Covers login, logout, failed login, every money and stock action, permission changes, settings changes, exports
- A screen for the owner to search and filter the log

**Done when:** every write endpoint produces an audit entry (checked by a test); the database rejects update/delete on the audit table.

### F08 · Server basics
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** F01
**What it does:** the shared plumbing every endpoint uses.
**Includes:**
- Standard error handler: returns the F03 error shape, never raw database messages
- Business errors return 4xx with a code, not 500
- Structured logger with request id and redaction of passwords, tokens and national IDs
- Environment validation on startup (zod)
- Health endpoint that checks the database
- Rate limiting that works behind a proxy (`trust proxy`)
- Security headers (helmet), strict CORS allow-list

**Done when:** a bad request returns a clean 4xx with a code; starting without a required env var fails with a clear message.

### F09 · UI shell
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port · **Depends on:** F03, F04
**What it does:** the frame and shared building blocks every page uses.
**Includes:**
- App layout, responsive sidebar (collapses to a menu on small screens), top bar with branch switcher
- Route guards by login and permission (not only hiding links)
- Arabic/English switch with full RTL/LTR, Arabic font, consistent number and date formats
- Shared components: data table (sort, filter, search, pagination), form fields with validation from the F03 schemas, dialogs, toasts, loading states, empty states, error boundary
- One API client per feature, generated from or typed by F03
- No `alert()` / `confirm()`

**Done when:** a sample page built from the shared components passes in both languages; a user without permission can't open a guarded route by typing the URL.

### F10 · Ledger core
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F02, F12
**What it does:** the single way stock and cash ever change, so balances always match their history.
**Includes:**
- **Stock ledger:** one row per movement (product, branch, quantity ±, reason, source document). On-hand per branch = sum of the ledger.
- **Cash ledger:** one row per movement (vault/drawer, amount ±, reason, source document). Balance = sum of the ledger.
- Cached balances may exist for speed, but only the ledger insert updates them, in the same transaction
- Stock can't go below zero (database constraint + row lock)
- Idempotency keys on every money/stock action: the same request twice changes things once
- Reversal entries that point to the original entry; no editing or deleting entries
- A reconciliation check: cached balance = ledger sum, for every product and vault

**Done when:** 100 parallel sales of the last 10 units sell exactly 10; a repeated request with the same key changes nothing; the reconciliation check passes after the full test suite.

### F11 · Document numbering
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F02
**What it does:** gives every document a human-readable sequential number.
**Includes:**
- Separate sequences per shop, branch and document type: receipt, invoice, return, quote, order, contract, purchase invoice, payment receipt, transfer
- Format with a prefix, e.g. `BR1-RC-000123`
- No duplicates under concurrency; no gaps after a rolled-back transaction where the law requires it

**Done when:** 1,000 concurrent document creations produce 1,000 unique, ordered numbers.

### F12 · Money and tax utilities
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F01
**What it does:** one shared set of rules for money maths, used by every slice.
**Includes:**
- Decimal library (no floats), one rounding rule (half-up to 2 decimals), line-level vs total-level rounding defined once
- Helpers: sum, split an amount into N parts that add back exactly, percentage, tax-inclusive ↔ exclusive
- Currency formatting for EGP in Arabic and English

**Done when:** unit tests cover splits that must sum exactly (e.g. 1000 / 3) and tax-inclusive conversions.

### F13 · Background jobs
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F02
**What it does:** runs scheduled and retryable work outside user requests.
**Includes:**
- Job runner (e.g. pg-boss on Postgres, or pg_cron) with retries and a dead-letter list
- Jobs run per shop in the shop's timezone (Africa/Cairo by default)
- Used by: overdue marking (N04), ETA submission retries (T02), daily reconciliation (K04), backups check (Q03)
- A screen or log showing job runs and failures

**Done when:** a failing job retries and then lands in the failed list; a daily job runs once per day even with two server instances.

### F14 · File storage
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F05
**What it does:** stores uploaded files (customer ID photos, survey photos, receipts, contracts) safely.
**Includes:**
- Private bucket; files are shown through short-lived signed URLs only
- File type and size checks on the server; generated safe file names
- Path includes the shop id; access checked by the shop and permission
- Deleting a record doesn't leave orphan files

**Done when:** a file URL expires; a user from another shop gets 403 for the file.

---

# 1. Platform (SaaS level)

### P01 · Shop provisioning
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (UI) · **Depends on:** F04, F05
**What it does:** lets the super admin create a new shop and invite its owner.
**Includes:**
- Super admin screen: create shop (name, plan, contact), which creates the org, main branch, main vault and default settings in one transaction
- Owner invite by email with a one-time token that expires; the owner sets their own password
- No license key that reveals the owner's email; no endpoint lets someone claim a shop without the token
- Super admin can list shops, deactivate/reactivate a shop, resend an invite

**Done when:** a new shop is fully usable after the owner accepts the invite; an expired or reused token fails.

### P02 · Onboarding wizard
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** P01, O01, K01, P03
**What it does:** guides the owner through the first setup after the invite.
**Includes:**
- Steps: shop details and logo, tax registration number, branches, vaults, receipt settings, installment policy, first employees
- Can be skipped and resumed; shows progress

**Done when:** an owner can go from invite to first sale using only the wizard.

### P03 · Shop settings
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Rewrite · **Depends on:** F03, F06
**What it does:** the shop's own rules, stored once and actually read by the code.
**Includes:**
- General: name, logo, address, phone, timezone, language
- Receipts: header, footer, which fields appear, paper width
- Tax: VAT registration number, default tax class, prices include VAT or not
- Installment policy (read by N01): minimum down payment %, max months, markup %, allowed frequencies, late-fee rule, grace days
- Discount cap % per role
- Changes are audited (F07)

**Done when:** changing a setting changes the behaviour it controls (tested for the installment policy and discount cap).

### P04 · Legal and financing profile
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** P03
**What it does:** records the shop's legal identity and what kind of financing it is allowed to run.
**Includes:**
- Legal seller name, commercial register, tax number
- Financing model: in-house only in V1; records who the creditor is on each installment contract
- A field for the shop's legal status under the consumer-finance rules (FRA 18/2020), filled by the owner
- Turns the installment features on or off for the shop
- Ready to hold third-party provider agreements in V2

**Done when:** a shop with installments turned off can't create an installment sale; every contract stores the creditor.

### P05 · Subscription plans and limits
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Rewrite · **Depends on:** P01
**What it does:** controls what each shop's plan allows and when it ends.
**Includes:**
- Plans with limits: branches, users, devices, modules
- Subscription start and end date per shop; warning before expiry; read-only mode after expiry (data stays visible and exportable)
- Super admin can change a plan, extend a date, record a manual payment
- Limits enforced on the server (e.g. creating one more branch than allowed fails)

**Done when:** creating over the limit fails with a clear message; an expired shop can log in, read and export, but not sell.

### P06 · Self-serve signup and online billing
**Plan:** V2 · **Agent:** Smart · **Reuse:** New
**What it does:** shops sign up and pay online without the super admin.

---

# 2. Organization

### O01 · Branches
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F05, F06, P05
**What it does:** manages the shop's branches.
**Includes:**
- Create, edit, deactivate a branch: name, code (unique per shop), address, phone, default vault, ETA branch code (T02)
- Can't deactivate a branch with open shifts or stock without a warning
- Respects the plan's branch limit (P05)

**Done when:** a new branch appears in the branch switcher, stock views and reports.

### O02 · Employees
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port · **Depends on:** F04, F06, O01
**What it does:** manages the shop's staff accounts.
**Includes:**
- Create employee: name, phone, email/username (unique per shop), role, extra permissions, branches
- Edit role, permissions and branches; deactivate (blocks login at once); owner resets a password
- No temporary passwords shown on screen; the employee gets an invite to set their own
- Respects the plan's user limit (P05)

**Done when:** a deactivated employee's existing session stops working; permission changes apply on the next request.

---

# 3. Catalog

### C01 · Categories
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F05
**What it does:** groups products.
**Includes:** create, edit, archive; name unique per shop; optional parent category (one level); can't archive a category that still has active products without moving them.
**Done when:** products can be filtered by category in the catalog, POS and reports.

### C02 · Products
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port · **Depends on:** C01, F12, T01
**What it does:** the list of what the shop sells.
**Includes:**
- Fields: name (Arabic/English), SKU (unique per shop), barcode (unique per shop, auto-generated if empty), category, unit, cash price, installment price, cost (read-only, set by purchases), tax class, warranty months, "serialized" flag (each unit has a serial/IMEI), min stock level, image
- Supplier is **not** required (it belongs on the purchase)
- Archive instead of delete; archived products can't be sold but stay in history
- Price changes are audited

**Done when:** a product can be created, found by barcode in the POS, archived, and still shows in old sales.

### C03 · Barcode labels
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** C02
**What it does:** prints price/barcode labels for products and serialized units.
**Includes:** choose products and quantities (or units by serial), label size templates, print to a label printer or PDF; label shows name, price, barcode (and serial for units).
**Done when:** a printed label scans correctly in the POS.

### C04 · Configurable products
**Plan:** Drop
**What it does:** furniture options (fabric, finish, size) as product variants. Custom details are written as free notes on the order line instead (S10).

### C05 · Branch price lists
**Plan:** V2
**What it does:** different prices for the same product per branch.

---

# 4. Inventory

### I01 · Stock view
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F10, C02, O01
**What it does:** shows how much of each product the shop has and where.
**Includes:** per product and branch: on hand, reserved (by orders, S10), in transit (I03), available = on hand − reserved; filters by branch, category, low stock; drill-down to movements (I05).
**Done when:** the numbers equal the ledger sums for every product and branch.

### I02 · Stock adjustments and counts
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** F10, F06
**What it does:** corrects stock when the real count differs from the system.
**Includes:**
- Adjustment: product, branch, quantity ±, required reason (damage, loss, found, correction), needs `stock.adjust`
- Stock count: create a count sheet for a branch/category, enter counted quantities, review the differences, post them as adjustments in one go
- For serialized products, count by scanning serials

**Done when:** a posted count makes the stock equal the counted numbers and leaves ledger entries with the reason.

### I03 · Branch transfers
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** F10, O01, I04
**What it does:** moves stock between branches with a clear trail.
**Includes:**
- Transfer document: from branch, to branch, lines (with serials for serialized products)
- States: draft → sent (stock leaves the source, shows as in transit) → received (stock enters the destination)
- Receiving can record a shortage or damage, which becomes an adjustment with a reason
- Numbered (F11)

**Done when:** stock is never counted in both branches or in neither; in-transit stock shows in I01.

### I04 · Serial/IMEI units
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F10, C02
**What it does:** tracks every physical unit of a serialized product (phones, laptops, TVs) individually.
**Includes:**
- Each unit: serial/IMEI (unique per shop), product, branch, status (in stock, reserved, sold, returned, in repair, written off), cost, supplier, purchase invoice
- Units are created on purchase receipt (U02) by scanning or typing serials
- Sale, return, transfer, warranty claim all require picking a specific serial
- Full history per unit: received → transferred → sold to whom → returned → claimed
- Search by serial from anywhere

**Done when:** a duplicate serial is rejected; you can't sell a unit that's not in stock in that branch; a unit's history shows every step.

### I05 · Movement history
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F10
**What it does:** shows every stock movement for a product, branch or serial.
**Includes:** date, type (sale, purchase, return, transfer, adjustment), quantity, running balance, who, link to the source document; filters and export.
**Done when:** every movement links to the document that caused it.

### I06 · Low-stock alerts
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** I01, C02
**What it does:** shows products that are running out.
**Includes:** min level per product (and optional per branch); a "low stock" list per branch; shown on the dashboard (D01); one click to start a purchase order (U05).
**Done when:** a product below its min level appears in the list and on the dashboard.

---

# 5. Purchasing

### U01 · Suppliers
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** F05
**What it does:** manages who the shop buys from.
**Includes:** create, edit, deactivate; name, phone, tax number, address, payment terms; supplier statement: invoices, payments, returns, balance owed.
**Done when:** the statement balance equals invoices − payments − returns.

### U02 · Purchase invoices
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (UI and moving-average cost SQL) · **Depends on:** U01, C02, F10, I04, T01
**What it does:** records goods bought from a supplier and puts them into stock.
**Includes:**
- Invoice: supplier, branch, supplier's invoice number, date, lines (product, quantity, unit cost, tax), totals; optional link to a purchase order (U05)
- States: draft → approved (stock in via the ledger, once; product cost updated by moving average) or rejected
- Serialized products require entering one serial per unit on approval
- Can be "pay later"; payment is a separate step (U03)
- Approval needs the right permission and follows the amount thresholds (U06)

**Done when:** approving a multi-line invoice adds each quantity exactly once; cost updates correctly; the supplier balance increases by the total.

### U03 · Supplier payments
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port · **Depends on:** U02, K01
**What it does:** pays suppliers from a vault.
**Includes:** pay one or several invoices, full or partial, from a vault (cash ledger out); can't pay more than owed; payment receipt numbered; idempotent.
**Done when:** a double-click pays once; invoice and supplier balances update.

### U04 · Purchase returns
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Rewrite · **Depends on:** U02
**What it does:** returns goods to a supplier.
**Includes:** pick the original invoice and lines (serials for serialized), quantity ≤ what was bought minus already returned, real unit cost from the invoice; stock out once; supplier balance reduced or refund recorded to a vault; numbered.
**Done when:** stock and supplier balance each change exactly once; you can't return more than you bought.

### U05 · Purchase orders
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** U01, C02
**What it does:** orders goods from a supplier before they arrive.
**Includes:** order lines and expected prices; states: draft → sent → partly received → received / cancelled; create a purchase invoice from an order (U02) and track what's still to come; furniture special orders (S10) can create a purchase order.
**Done when:** receiving part of an order leaves the rest open; a special customer order shows its purchase order status.

### U06 · Purchase approval by amount
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** U02, F06, P03
**What it does:** requires higher approval for bigger purchases.
**Includes:** thresholds in settings (e.g. above X needs the owner); invoices above the threshold wait in an approval list; approvals and rejections are audited with a reason.
**Done when:** a user below the threshold can't approve a large invoice; the approval list shows waiting invoices.

---

# 6. Cash management

### K01 · Vaults
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** F10, O01
**What it does:** manages the places where the shop keeps money (main safe, branch safe, bank account).
**Includes:** create, rename, deactivate; type (cash, bank); branch; balance from the cash ledger; transfer between vaults (out of one, into the other, in one transaction, both vaults in the same shop, amount > 0); vault ledger view.
**Done when:** a transfer changes both balances once; the ledger view adds up to the balance.

### K02 · Shifts / cash drawer
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (UI) · **Depends on:** K01, F10
**What it does:** tracks the cash each cashier handles during their shift.
**Includes:**
- Open a shift on a POS device with a starting float taken from a vault
- Every cash in/out during the shift goes to that shift's drawer ledger (sales, refunds, pay-ins, pay-outs, installment collections)
- Close: count the cash by denomination, show expected vs counted and the difference; a difference needs a reason; the cash goes back to a vault
- One open shift per cashier per device; selling requires an open shift

**Done when:** expected cash = float + drawer ledger sum (not the whole vault); a closed shift can't take sales.

### K03 · Expenses
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** K01, F14
**What it does:** records money spent (rent, transport, salaries paid in cash).
**Includes:** amount, category, vault or current shift, note, receipt photo; numbered; reversal instead of delete; expense report by category.
**Done when:** an expense lowers the vault/drawer balance and appears in the day close (K04).

### K04 · Day close and reconciliation
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** K02, K03, S01, N03
**What it does:** ends each business day with numbers the owner can trust.
**Includes:**
- Per branch per day: sales by payment method, returns, collections, expenses, opening and closing cash, shift differences
- Checks: ledger sums = cached balances; every shift closed; every ETA receipt submitted (T03)
- Lists any difference with a link to the cause
- The manager closes the day; a closed day can't take new back-dated entries without permission
- Nightly job (F13) runs the checks automatically

**Done when:** the day-close numbers equal the sum of the day's documents; a broken balance is flagged.

---

# 7. Customers

### R01 · Customers
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (national ID parser, CRM UI) · **Depends on:** F05, F06, F14
**What it does:** keeps the shop's customer records.
**Includes:**
- Fields: name, phone(s), national ID (parsed for birth date and gender), address, job, monthly income, notes, ID photos
- National ID unique per shop; editing it needs a permission (no hard-coded password)
- National ID and photos only visible with `customer.view_pii`; masked otherwise
- Status: active, blocked (can't buy on installments)
- Search by name, phone, national ID

**Done when:** a user without the PII permission sees masked IDs; duplicate national IDs are rejected.

### R02 · Customer account
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** R01, S01, N02, N03
**What it does:** one page showing everything about a customer's money.
**Includes:** purchases, returns, contracts, schedules, payments, overdue amounts, open balance, documents, guarantors; printable statement for a date range.
**Done when:** the open balance equals contract totals − payments − returns.

### R03 · Credit profile and limit
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** R01, N01
**What it does:** decides how much more credit a customer can get.
**Includes:**
- Credit limit per customer (set by a user with `credit.approve`, with a default from settings, e.g. a multiple of income)
- Current exposure = unpaid principal of all active contracts
- Payment behaviour summary: on-time %, days late, current overdue
- Used on the server by the installment sale (N02): a sale above the available limit is blocked unless someone with permission approves the exception

**Done when:** the server blocks an installment sale over the limit even if the client sends it directly.

### R04 · Guarantors
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** R01
**What it does:** records the people who guarantee a customer's debt.
**Includes:** guarantor details (same ID rules and masking as customers), relation to the customer, ID photos; link guarantors to a customer and to specific contracts; settings define how many guarantors a contract needs above an amount.
**Done when:** editing a customer never deletes their guarantors; a contract that needs a guarantor can't be created without one.

### R05 · Field surveys
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** R01, F14
**What it does:** records a home/work visit to check a customer before giving credit.
**Includes:** assign a survey to an employee; the employee fills a checklist, scores, notes, GPS location and photos from a phone; manager approves or rejects; the result shows on the credit profile (R03); settings can require an approved survey above an amount.
**Done when:** photos are private (F14); a required survey blocks the installment sale until approved.

---

# 8. Sales / POS

### S01 · Sale core
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F10, F11, F12, T01, K02, I04
**What it does:** the one transaction that turns a cart into a completed sale. Every other sale type builds on it.
**Includes:**
- One database transaction: lock stock rows, check availability, write stock ledger entries, create the sale document with lines, tax snapshot, payments (S02), drawer ledger entries, document number, audit
- Prices come from the server, never from the client; overrides need `price.override` and are audited
- Serialized lines must name the exact serial; the unit is marked sold
- Idempotency key: a retried request returns the same sale
- Sale types: cash sale now; installment sale (N02) and order (S10) reuse this
- Clear error codes (out of stock, price changed, shift closed) instead of 500

**Done when:** the four ledger/reconciliation checks pass; double-submit creates one sale; the last unit can't be sold twice.

### S02 · Split payments
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** S01
**What it does:** lets one sale be paid with more than one method.
**Includes:**
- Payment lines on a sale: cash, bank transfer, store credit; down payment + installment contract (N02)
- Card payments are V2 (Y01); bank transfer is recorded with a reference
- Totals must equal the sale total exactly; change given for cash is calculated
- Each payment line posts to the right ledger (drawer, vault, customer balance)

**Done when:** a sale paid half cash, half bank transfer posts each amount to the right place and the day close (K04) shows both.

### S03 · Discounts
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** S01, P03, F06
**What it does:** lowers prices in a controlled way.
**Includes:** line discount and whole-sale discount, as amount or %; cap per role from settings; above the cap needs `discount.above_cap` or a manager's approval on the spot; reason required; discounts are spread across lines for tax (T01).
**Done when:** a cashier can't exceed their cap through the API; the tax on a discounted sale is correct.

### S04 · Receipt printing
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** S01, T02, P03
**What it does:** prints and reprints receipts and invoices.
**Includes:** 80mm thermal and A4 layouts; Arabic/English; shop info, number, date, cashier, lines, discounts, VAT, payments, change; ETA UUID and QR code; serials and warranty dates on lines; reprint marked "copy"; also for returns, payment receipts and contracts.
**Done when:** the client's printer prints a readable Arabic receipt with a scannable QR code.

### S05 · Returns and exchanges
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** S01, S02, I04, T02, N02
**What it does:** takes goods back and gives the right money or credit back.
**Includes:**
- Start from the original sale; pick lines and quantities (exact serial for serialized items; a different serial is rejected)
- Can't return more than sold minus already returned
- Stock back in (or to "damaged"), refund by the original method or store credit, tax reversed with an ETA return receipt linked to the original
- For installment sales: reduce the contract balance and recalculate the remaining schedule, or refund what was overpaid
- Exchange = a return + a new sale linked together, settling the difference
- Needs `refund.create`; reason required; return policy days from settings

**Done when:** returning one item of an installment sale after two payments gives the right remaining debt; stock, cash and tax each change once.

### S06 · POS screen
**Plan:** V1 · **Agent:** Free · **Reuse:** Port · **Depends on:** S01, S02, S03, F09
**What it does:** the cashier's main screen.
**Includes:** product search by name/SKU/barcode, barcode scanner (bundled locally, not from a CDN), cart, quantities, serial picker, customer picker, discounts, payment dialog, hold and resume carts, keyboard shortcuts, fast on cheap hardware.
**Done when:** a cashier completes a cash sale with a scanner and keyboard only, in under 2 seconds after confirming.

### S07 · Sales history
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** S01
**What it does:** lists and finds past sales.
**Includes:** search by number, customer, date, cashier, serial; view details; reprint; void a sale on the same day with `sale.void` and a reason (a void is a full reversal, not a delete); start a return (S05).
**Done when:** a voided sale reverses stock, cash and tax and stays visible as voided.

### S08 · Offline cash sales
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** S01, S06, T02
**What it does:** lets the cashier keep selling for cash when the internet drops.
**Includes:**
- Local cache of products, prices and stock snapshot on the device
- Offline sales saved in a durable local queue (survive closing the app or a restart) with a local id and idempotency key
- Clear "offline" banner and count of unsynced sales
- When back online: sync each sale exactly once; conflicts (stock ran out, serial already sold) go to a resolution list for a manager
- Not allowed offline: installment sales, returns, credit, anything needing approval
- ETA receipts for offline sales are submitted after sync, within the allowed time

**Done when:** the "network failure" release test (Q04) passes.

### S09 · Quotations
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** C02, R01, F11
**What it does:** gives a customer a price offer before they decide.
**Includes:** lines with prices and notes (e.g. fabric, size), validity date, print/share as PDF; states: draft → sent → accepted (converts to an order, S10) / expired / rejected; no stock or money effect.
**Done when:** accepting a quote creates an order with the same lines and prices.

### S10 · Sales orders, deposits, reservations
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** S01, S02, S09, U05, I01
**What it does:** sells now, delivers later (mainly furniture and out-of-stock items).
**Includes:**
- Order lines with custom notes; each line is either reserved from stock or marked "to order" (creates or links a purchase order, U05)
- Deposit payments at order time; balance at delivery or by installment contract (N02)
- Reserved stock shows as reserved (I01) and can't be sold to someone else
- States: open → partly delivered → delivered / cancelled (cancellation releases reservations and handles the deposit refund)
- Revenue and tax are recorded when goods are delivered, not when the deposit is paid (confirm with a tax advisor)

**Done when:** a deposit doesn't count as a sale; reserved stock can't be sold at the POS; cancelling refunds the deposit once.

### S11 · Delivery
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** S10, F14
**What it does:** tracks delivering ordered goods to the customer.
**Includes:**
- Delivery note per delivery, per line (partial deliveries allowed), promised date and time window, address, driver
- States: scheduled → out for delivery → delivered / failed (reason, reschedule)
- Proof: customer signature or photo; serials confirmed on handover
- Delivery and assembly fees as order lines
- Delivering posts the stock out and completes the sale for those lines
- Delivery schedule list per day

**Done when:** delivering 2 of 3 lines leaves 1 open; stock leaves only on delivery.

### S12 · Warranty
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** I04, S01, C02
**What it does:** tracks warranties and handles warranty claims.
**Includes:**
- Warranty start and end per sold unit (from product warranty months and sale/delivery date); also for non-serialized lines by sale
- Lookup by serial, phone or receipt
- Claim: issue, condition, photos; states: open → sent to supplier/repair → returned to customer / replaced / refunded
- Replacement swaps the serial and keeps the history; refund goes through S05
- Printed claim receipt

**Done when:** a claim on an expired warranty is flagged; a replacement keeps both serials' history.

---

# 9. In-house installments

The shop lends its own money. Rules are built new on the server; nothing is reused from the old X-Core engine.

### N01 · Installment rules engine
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** P03, P04, F12, R03
**What it does:** calculates and enforces the terms of every installment sale on the server.
**Includes:**
- Reads the shop's policy (P03): min down payment %, max months, markup % (flat or by duration tiers), allowed frequencies (monthly, weekly), minimum installment amount, rounding
- Input: price, down payment, number of installments, frequency, start date → output: financed amount, markup, total payable, schedule lines (each split into principal and profit), all adding up exactly
- Validates against the customer's limit (R03), status, guarantor and survey requirements (R04, R05)
- A preview endpoint for the POS to show the terms before confirming; the confirm step recalculates on the server

**Done when:** schedule lines always sum to the total payable; changing the policy changes new contracts only; the server rejects terms that break the policy.

### N02 · Installment sale and contract
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** N01, S01, S02, P04
**What it does:** creates the installment contract as part of a sale.
**Includes:**
- Uses the sale core (S01): goods, tax and down payment in the same transaction
- Contract: number, customer, guarantors, creditor (from P04), cash price, down payment, financed amount, markup, total payable, schedule, policy version used
- Schedule dates in the shop timezone; month-end dates handled correctly
- The contract is never edited; changes go through N05
- Contract statuses: active → completed / rescheduled / written off / returned

**Done when:** the contract total = cash price − down payment + markup; the down payment is in the drawer; the contract shows on the customer account (R02).

### N03 · Collections (installment payments)
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (oldest-first allocation SQL) · **Depends on:** N02, K02
**What it does:** records customers paying their installments.
**Includes:**
- Find a customer or contract; see what's due and overdue
- Take a payment (full, partial or several installments); allocated in a fixed order: late fees → oldest installment (profit, then principal) → next
- Overpayment becomes customer credit, never lost
- Payment receipt (numbered, printed); cash goes to the current shift's drawer (or collector wallet, N06)
- Contract balance and status update; fully paid → completed
- A collection is **not** a new sale (no new revenue or VAT on the goods)
- Idempotent

**Done when:** allocation is the same every time for the same inputs; a double-click records one payment; the last payment closes the contract.

### N04 · Overdue and late fees
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** N02, F13, P03
**What it does:** marks late installments and applies the shop's late-fee rule.
**Includes:**
- Daily job (shop timezone): installments past due + grace days become overdue
- Late fee per the policy (fixed amount or %, once or per period, with a cap); recorded as a separate charge, not added into principal
- Waive a fee with permission and reason
- Overdue list with days late and amounts; feeds the aging report (D03)

**Done when:** running the job twice in a day doesn't double the fees; a waived fee is audited.

### N05 · Early settlement, rescheduling, write-off
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** N02, N03, N04
**What it does:** changes a contract in a controlled way.
**Includes:**
- **Early settlement:** calculate the payoff amount (remaining principal + any rule on remaining markup from the policy), take payment, close the contract
- **Rescheduling:** new schedule for the remaining balance; needs `schedule.change` and a reason; the old schedule is kept and linked
- **Write-off:** mark a remaining balance as lost; needs the owner; reason required; shows in reports
- All changes create new linked records; nothing is overwritten

**Done when:** the old schedule is still visible after a reschedule; the customer balance after each action is correct.

### N06 · Collector wallets
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Rewrite · **Depends on:** N03, K01, F10
**What it does:** tracks cash collected in the field by collectors before it reaches the shop.
**Includes:**
- Each collector has a wallet (its own cash ledger)
- Field collections go into the wallet, **not** the main vault
- Settlement: the collector hands cash to a vault; the wallet goes down and the vault goes up in one transaction; shortages recorded with a reason
- Collector commission calculated separately (a payable to the collector), never mixed into the cash
- Collector's list of assigned customers and a daily route list

**Done when:** a field collection is counted once (wallet) until settled (vault); the wallet balance equals its ledger.

### N07 · Printed contract and promissory notes
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** N02, R04
**What it does:** prints the documents the customer and guarantors sign.
**Includes:** contract template (Arabic) with all terms, schedule and guarantor details; promissory notes (one per installment or one total, from settings); shop logo; template text editable by the owner; reprint marked "copy".
**Done when:** the printed totals and dates match the contract exactly.

### N08 · Reminders (SMS/WhatsApp)
**Plan:** V2
**What it does:** sends messages before and after due dates.

### N09 · Legal escalation status
**Plan:** V2
**What it does:** marks a defaulted contract as "sent to legal". See L01 for the V1 legal module and the open question.

---

# 10. Third-party financing — all V2

| ID | Slice | What it does |
|---|---|---|
| X01 | Finance payment lifecycle | Provider-independent states (requested, approved, captured, cancelled, refunded, settled); duplicate callbacks are safe. |
| X02 | First provider integration | Valu, Aman, Souhoola or an aggregator (Paymob/Geidea), chosen by the client. |
| X03 | Provider settlement reconciliation | Match provider payouts and fees to sales. |
| X04 | Second provider and fee comparison | |

# 11. Card payments — all V2

| ID | Slice | What it does |
|---|---|---|
| Y01 | Card tender (manual) | Record card payments with a reference; reconcile at day close. |
| Y02 | Card terminal integration | The terminal sends the amount and result automatically. |

---

# 12. Tax and ETA

### T01 · VAT engine
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** F12, P03
**What it does:** calculates tax correctly on every document.
**Includes:**
- Tax classes (standard 14%, zero-rated, exempt), assigned per product
- Prices with or without VAT included (shop setting)
- Line-level calculation; discounts spread across lines before tax
- A tax snapshot stored on every issued document (rate, base, amount), so old documents never change when rates change
- Returns reverse the exact tax of the original line
- Installment collections are not taxed again; how markup, delivery fees and deposits are taxed is a setting, confirmed with the client's accountant

**Done when:** totals match the ETA rounding rules in test cases; a rate change doesn't alter old documents.

### T02 · ETA e-receipts (B2C)
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** T01, S01, O01, F13
**What it does:** sends every consumer receipt to the Egyptian Tax Authority as the law requires.
**Includes:**
- Shop and branch ETA credentials; registration of each POS device with the ETA
- Build the receipt in the ETA format, generate the UUID, sign/submit through the ETA API
- QR code on the printed receipt linking to the ETA record
- Return receipts linked to the original receipt
- Queue and retry (F13) when the ETA or the internet is down; never submitted twice; respects the submission deadline from the SDK
- Test mode against the ETA pre-production environment
- **First task:** read the official ETA e-receipt SDK and write the exact format and deadline into this slice's spec

**Done when:** test receipts are accepted by the ETA pre-production system; a retried submission doesn't create a duplicate.

### T03 · ETA submission monitor
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** New · **Depends on:** T02
**What it does:** shows the state of every ETA submission and lets staff fix failures.
**Includes:** list with status (pending, submitted, accepted, rejected, failed) and the ETA error message; retry button; filters by branch and date; dashboard alert when anything is failing or close to the deadline; feeds the day close (K04).
**Done when:** a rejected receipt shows the ETA's reason and can be retried after the fix.

### T04 · ETA e-invoices (B2B)
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** T01, T02, R01
**What it does:** issues tax invoices to business customers through the ETA e-invoice system.
**Includes:** business customer fields (tax registration number, type); sale marked B2B produces an e-invoice in the ETA invoice format; signing as required by the ETA; credit/debit notes for returns and corrections; shares the queue, retry and monitor (T02, T03).
**Done when:** a test B2B invoice and a credit note are accepted by the ETA pre-production system.

---

# 13. Reports

All reports use SQL aggregates (never summing in JavaScript), have date/branch filters, and export to Excel/PDF.

### D01 · Owner dashboard
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (UI) · **Depends on:** S01, N03, I06, T03, K04
**What it does:** the owner's first screen: how the business is doing today.
**Includes:** today's sales and collections, cash in vaults and drawers, open shifts, overdue total, low stock count, ETA failures, unclosed days, pending approvals; per branch or all; each number clicks through to its details.
**Done when:** every number equals its detailed report for the same filters.

### D02 · Sales and margin report
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** S01, S05
**What it does:** shows what sold and how much profit it made.
**Includes:** by period, branch, employee, category, product, payment type; quantity, revenue, cost, margin; returns shown separately; cash vs installment sales.
**Done when:** totals match the sales documents for the period.

### D03 · Receivables aging
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** N02, N04
**What it does:** shows who owes the shop money and how late they are.
**Includes:** by customer, branch and collector; buckets (not due, 1–30, 31–60, 61–90, 90+ days); totals of principal, markup and fees; drill-down to contracts.
**Done when:** the total equals the sum of open contract balances.

### D04 · Inventory valuation
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F10, U02
**What it does:** shows how much the stock is worth.
**Includes:** quantity × moving-average cost per product and branch, by category; value at a chosen past date from the ledger.
**Done when:** the value at a past date matches the ledger at that date.

### D05 · Tax report
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** T01, U02
**What it does:** gives the accountant the VAT numbers for the tax return.
**Includes:** VAT on sales, VAT on returns, VAT on purchases, net VAT, per period; list of documents behind each number.
**Done when:** the totals equal the tax snapshots of the documents in the period.

### D06 · Provider receivables report
**Plan:** V2 (comes with third-party financing)

### D07 · Advanced analytics / BI export
**Plan:** V2

---

# 14. Data in and out

### M01 · Import
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Rewrite · **Depends on:** C02, R01, U01, F10
**What it does:** loads the shop's existing products, customers, suppliers and opening stock from Excel/CSV.
**Includes:** downloadable templates; a safe parser (not the old xlsx library); validation with a row-by-row error report before anything is saved; "dry run" then "import"; opening stock goes through the ledger as an "opening balance" entry with serials for serialized products; can be run again (updates instead of duplicating).
**Done when:** a file with errors saves nothing and shows every error; a clean file imports and stock equals the file.

### M02 · Opening balances migration
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** M01, N02, R01
**What it does:** brings in the customers' existing installment debts from the shop's old system or paper records.
**Includes:** import open contracts with their remaining schedules, paid amounts, overdue amounts and guarantors; marked as "migrated" with the source; opening cash balances per vault; a reconciliation report (totals per customer and overall) that the owner signs before going live.
**Done when:** the system's total open debt equals the signed total from the old records.

### M03 · Full export
**Plan:** V1 · **Agent:** Free · **Reuse:** Rewrite · **Depends on:** F06
**What it does:** lets the owner download all their data at any time.
**Includes:** every table as CSV and JSON in one zip (products, units, stock movements, customers, sales, contracts, schedules, payments, tax documents, audit log) with ids and links between them; needs `export.data`; protected against spreadsheet formula injection; audited.
**Done when:** the export restores into a clean environment with matching totals (release test Q04).

---

# 15. Operations

### Q01 · Deployment
**Plan:** V1 · **Agent:** Smart · **Reuse:** Rewrite · **Depends on:** F01, F02
**What it does:** gets both repos to staging and production safely.
**Includes:** staging and production environments with separate databases; deploy pipeline per repo (server and client); migrations run automatically on deploy; secrets in the host's secret store; SPA routing works on deep links; rollback steps documented.
**Done when:** merging to main deploys to staging; production deploy is one documented step.

### Q02 · Monitoring
**Plan:** V1 · **Agent:** Free · **Reuse:** New · **Depends on:** F08, Q01
**What it does:** tells you something broke before the client does.
**Includes:** error tracking (e.g. Sentry) on server and client, uptime check, alerts for failed jobs and ETA failures, request ids in logs.
**Done when:** a test error appears in the tracker with its request id.

### Q03 · Backup and restore
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** Q01
**What it does:** makes sure data can be recovered.
**Includes:** paid database plan with daily backups and point-in-time recovery; a written restore procedure; a restore drill into a clean environment that checks control totals; repeated before launch and then regularly.
**Done when:** a restore drill succeeds and the totals match.

### Q04 · Release tests
**Plan:** V1 · **Agent:** Smart · **Reuse:** New · **Depends on:** most V1 slices
**What it does:** four end-to-end scenarios that prove the system is ready. Adapted to V1 (in-house installments, no third-party financing).
**Includes:**
1. **Installment sofa:** quote → order with deposit → installment contract → deliver one part, cancel another → return → customer statement and cash all agree
2. **Serialized device:** receive two identical models with different serials, sell one on installments, try to return the other (rejected), do a real exchange keeping the warranty and contract history
3. **Network failure:** offline cash sale, restart the app, reconnect, duplicate requests → exactly one sale, one stock movement per line, one ETA receipt
4. **Month end and exit:** day closes, aging, tax report and stock valuation all reconcile; full export restores with matching totals

**Done when:** all four run automatically in CI against staging.

### Q05 · Hardware certification
**Plan:** V1 · **Agent:** Manual · **Reuse:** New · **Depends on:** S04, S06, C03
**What it does:** confirms the client's real devices work.
**Includes:** test the client's receipt printer, label printer, barcode scanner and cash drawer with the system; write the supported device list; note browser and OS versions.
**Done when:** each device passes a printed checklist at the client's shop.

---

# 16. Legal

### L01 · Legal module
**Plan:** V1 · **Agent:** Spec→Free · **Reuse:** Port (UI shell) · **Depends on:** N02, N04, F14, F06
**What it does:** manages legal action on customers who stop paying.
**Includes:**
- Open a legal case from a defaulted contract (links customer, guarantors, contract, amounts owed)
- Case details: case number, court, lawyer, type, status (preparing → filed → in court → judgment → closed), next hearing date
- Documents: upload signed contract, promissory notes, court papers (private storage, F14)
- Case notes and hearing history
- Payments received through the legal process are recorded as collections (N03)
- `Lawyer` role sees only legal cases
- Contract shows a "legal" flag while a case is open

**Done when:** a case links to its contract and amounts; a lawyer can't see sales or cash.

> ⚠️ **Open point:** you put L01 (full legal module) in V1 but N09 (legal escalation status) in V2. Opening a case from a defaulted contract *is* the escalation, so this spec includes it in L01. Confirm, or tell me what L01 should cover instead.

---

# 17. Notifications

### Z01 · In-app notifications
**Plan:** ❓ not decided
**What it does:** a bell with alerts: overdue installments, low stock, ETA failures, approvals waiting, shift differences.
**Suggestion:** V2. The dashboard (D01) already shows these in V1.

---

# 18. Later or out

| ID | Item | Plan |
|---|---|---|
| H01 | HR: contracts, payroll, points, reviews | V2 |
| H02 | Attendance | V2 |
| W01 | Partners / Mudarabah profit sharing | V2 |
| A01 | AI credit scoring | Drop |
| B01 | Loyalty program | V2 |
| B02 | E-commerce sync | V2 |
| B03 | Accounting software integration | V2 |
| B04 | Customer mobile app / portal | V2 |
| B05 | Power BI, demand forecasting | V2 |
| B06 | Multi-country (KSA/UAE), multi-currency | V2+ |
| B07 | On-prem deployment | V2+ |

---

# Build order

1. **Foundation:** F01–F14
2. **Setup:** P01, P03–P05, O01–O02, C01–C03, U01, K01, R01, P02
3. **Stock and purchasing:** I01–I06, U02–U06
4. **Selling core:** S01–S03, S06, S07, K02, K03, T01, S04
5. **Compliance and trust:** T02–T04, S05, K04, S08
6. **Furniture and electronics:** S09–S12
7. **Installments:** R03–R05, N01–N07, L01
8. **Data, reports, launch:** M01–M03, D01–D05, Q01–Q05
