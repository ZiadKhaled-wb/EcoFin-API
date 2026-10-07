# Old code map

Old project: `FinTech-Pro-Deployed` (read-only reference). Generated 2026-10-07.

## Overview of the old project

- **Stack:** React 19 + Vite + Tailwind 4 + react-router (client); Express 4 + TypeScript + zod (server); Supabase Postgres. Excel/CSV via `xlsx` + `multer`; charts via `recharts`.
- **How it talks to the DB:** the browser calls the Express API only (`axios`, token in `localStorage`). The server talks to Supabase with **one service-role client** (`supabaseAdmin`), so RLS is bypassed and every tenant check is hand-written. The README claims "offline-first / IndexedDB"; that code is gone (see the stubs in `client/src/lib/notifications.ts`).
- **Folder layout (paths relative to `FinTech-Pro-Deployed/`):**
  - `client/src/pages/` one big page per module (no feature folders); `client/src/components/` only 7 shared components; `client/src/layouts/MainLayout.tsx`.
  - `client/src/services/api.ts` is the single API client (one `xxxAPI` object per module, with the payload types).
  - `client/src/lib/` has `validation.ts`, `xcore.ts` (browser credit engine), `utils.ts`.
  - `server/src/` is `routes/` → `controllers/` → `services/` (one trio per module); `middleware/auth.ts`; `utils/` (`supabase.ts`, `transaction.ts`, `validation.ts`).
  - SQL is one file: `database_schema` (no extension, 1791 lines). It is a **destructive reset** (`DROP SCHEMA public CASCADE`, L17) holding tables (L36-733), helpers + RLS (L739-1115) and triggers/functions (L1118-1732).
- **Routing file:** `client/src/App.tsx#L96-170`. Four route sets: no license key → `/activate`; no session → `/login`; super admin → `/sa`; normal user → `MainLayout` with the pages (`/pos`, `/crm`, `/inventory`, `/purchases`, `/suppliers`, `/vaults`, `/shifts`, `/collection`, `/surveys`, `/legal`, `/golden`, `/data-bridge`, `/settings`, `/users`, `/hr`, `/partners`, `/audit`, `/reports`, `/notifications`, `/attendance`). `Sidebar.tsx` also links `/expenses`, which has no route.
- **Server entry:** `server/src/index.ts` (route mounts L80+).
- **Old schema vs new baseline:** the old model has a `persons` supertype under customers, suppliers, guarantors, employees and partners; the new baseline has none. Old money is `numeric(10,2)`/`(12,2)`; new is `numeric(18,2)`. Stock and balances are plain columns changed by triggers; new ones are ledger-driven (`stock_movements`, `cash_movements`).
- **No i18n files:** Arabic strings are hard-coded in the components. There are **no print/receipt templates** and no shared money/date formatter (`toLocaleString` is called inline in 18 files).
- **Known gap in the old SQL:** `system_settings` (used by `server/src/services/settings.ts`) is not defined in `database_schema`.

---

## P03 · Shop settings (Rewrite)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/SettingsPage.tsx — settings screen: tabs `TABS` #L50-57, credit/sales/legal/inventory fields #L187-260
- FinTech-Pro-Deployed/server/src/services/settings.ts#L17-52 — `DEFAULT_SETTINGS` (the list of old settings and their defaults)
- FinTech-Pro-Deployed/server/src/services/settings.ts#L54-140 — get/update/reset of a JSON blob
- FinTech-Pro-Deployed/server/src/controllers/settings.ts — controller
- FinTech-Pro-Deployed/client/src/services/api.ts#L126-146 — `settingsAPI`
- FinTech-Pro-Deployed/database_schema#L36-63 — `organizations` (receipt footer, down-payment %, max months, discount cap, commission %)

Reference only (Rewrite):
- Tab names and Arabic labels: هوية المؤسسة، شروط الائتمان، ضوابط البيع، الشؤون القانونية، المخازن والتنبيهات.
- The setting names/defaults: min credit score 50, score weights 40/30/20/10, min invoice 2500, legal thresholds daily 35 / monthly 63, ban 180 days, warning every 10 days, global min stock 3.

Don't reuse:
- One untyped JSON blob (`config_data`) with no validation: the new settings are typed columns.
- Settings are mixed between `organizations` columns and the blob; the code reading them is split the same way.
- Reading settings is open to every logged-in employee (`FinTech-Pro-Deployed/server/src/routes/settings.ts#L14-19`); the owner-only tab is hidden in the UI only (`ownerOnly`, #L56). Only the write is role-checked (#L21-23).

Old tables → new tables:
- system_settings.config_data (not in the old SQL) → org_settings typed columns (see migration `20261007090100_p03_shop_settings.sql`: credit_min_score, credit_score_weights, legal_referral_days, customer_ban_days, global_min_stock…)
- organizations.receipt_footer_text → org_settings.receipt_footer
- organizations.discount_cap_pct / discount_requires_approval → org_settings.discount_caps (per role)
- organizations.min_down_payment_pct, max_installment_months → installment_policies.min_down_payment_pct, max_months
- organizations.collector_commission_pct → org_settings.collector_commission_pct

Gaps vs the slice goal:
- No tax defaults, no receipt width/fields, no return-policy days, no versioning of the installment policy.

## C02 · Products (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/InventoryPage.tsx — product list (read-only), search + stock/price columns
- FinTech-Pro-Deployed/client/src/pages/POSPage.tsx#L94-140 — product grid, barcode/name search, category filter
- FinTech-Pro-Deployed/server/src/services/inventory.ts#L1-60 — list products/categories, update details (cost/stock excluded)
- FinTech-Pro-Deployed/server/src/services/dataBridge.ts#L63-88 — product duplicate check by sku/barcode
- FinTech-Pro-Deployed/client/src/services/api.ts#L348-376 — `ProductRecord`, `CategoryRecord`, `inventoryAPI`
- FinTech-Pro-Deployed/database_schema#L235-276 — `categories`, `products`
- FinTech-Pro-Deployed/database_schema#L1531-1568 — governance trigger and barcode generator

Keep (Port):
- Table columns and Arabic labels of `InventoryPage` (المنتج، الكود SKU، التصنيف، سعر التكلفة، السعر كاش، الكمية); search on name + sku + barcode; category filter.
- The rule "price fields editable, cost and stock not" (`UpdateProductDetailsPayload`, inventory.ts): same intent as new `avg_cost` being set only by purchase approval.

Don't reuse:
- `generate_barcode()` (#L1549-1554): timestamp + 3 random digits, can collide.
- Stock and cost as columns changed under a session flag `app.allow_inventory_write` (#L1163, #L1531-1542): new design is `stock_levels` via ledger.
- `unit` as free text, `product_type` STANDARD/SERVICE, wholesale price, expiry: not in the new spec. No paging on the list.

Old tables → new tables:
- products.name → products.name_ar; sku/barcode/cash_price/installment_price/category_id → same names
- products.unit → products.unit_of_measure
- products.cost_price → products.avg_cost (read-only)
- products.stock_quantity → stock_levels (no column on products)
- products.product_type, wholesale_price, expiring_date, description → no match; categories → categories

Gaps vs the slice goal:
- No create/edit form (products are created only from a purchase), no tax class, no serial tracking (`units`), no min stock per product, no warranty months, no image, no archive.

## U01 · Suppliers (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/SuppliersPage.tsx — list, search, add/edit modal #L258-320, supplier statement
- FinTech-Pro-Deployed/server/src/services/suppliers.ts#L81-98 — list with search
- FinTech-Pro-Deployed/server/src/services/suppliers.ts#L100-150 — update, deactivate
- FinTech-Pro-Deployed/server/src/services/suppliers.ts#L152-164 — outstanding balance of a supplier
- FinTech-Pro-Deployed/server/src/controllers/suppliers.ts — controller
- FinTech-Pro-Deployed/client/src/services/api.ts#L758-806 — `SupplierRecord`, `SupplierStatement`, `suppliersAPI`
- FinTech-Pro-Deployed/database_schema#L244-254 — `suppliers`

Keep (Port):
- Page layout: search bar, table, add/edit modal with name / phone / address / category.
- Statement view (invoices, paid, outstanding) as the screen model.
- Deactivate instead of delete.

Don't reuse:
- `createSupplier` (#L25-79) makes a `persons` row first and undoes it by hand with `TransactionTracker`: the new schema has no `persons` and no undo code.
- Outstanding is summed in JS from `purchase_invoices.outstanding_amount` (#L152-164): new balance comes from invoices minus allocations.
- `category` free text defaulting to 'عام'.

Old tables → new tables:
- suppliers.name/phone/address → suppliers.name/phone/address
- suppliers.is_active → suppliers.archived_at (null = active)
- suppliers.id → persons.id (supertype) → no match, `suppliers.id` stands alone
- suppliers.category → no match

Gaps vs the slice goal:
- No payment terms, tax registration no, notes, or duplicate check (name/phone).

## U02 · Purchase invoices (Port: UI and moving-average cost SQL)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/PurchasesPage.tsx — invoice form with lines table, list, approve/reject, pay and return modals
- FinTech-Pro-Deployed/server/src/services/purchases.ts#L25-157 — create invoice (resolves lines, supplier quick-create)
- FinTech-Pro-Deployed/server/src/services/purchases.ts#L158-177 — approve; #L201-233 list/reject
- FinTech-Pro-Deployed/database_schema#L471-497 — `purchase_invoices`, `purchase_items`
- FinTech-Pro-Deployed/database_schema#L1280-1330 — **moving-average cost SQL** (`apply_purchase_approval`; the formula is #L1293-1310)
- FinTech-Pro-Deployed/client/src/services/api.ts#L510-557 — payloads and `purchasesAPI`

Keep (Port):
- Moving average: `new_cost = (old_qty × old_cost + qty × unit_cost) / (old_qty + qty)`, with the "stock is 0 → take the new cost" branch (#L1300-1305). Use it inside the new SECURITY DEFINER approve function, writing `products.avg_cost` and a `stock_movements` row per line.
- UI: supplier picker, lines table (product, qty, cost), totals, PENDING → APPROVED/REJECTED flow and its Arabic labels.

Don't reuse:
- It is a `BEFORE UPDATE` trigger with direct `UPDATE products` (#L1307-1310): no lock order by product, no document number, no idempotency.
- Cost rounded to 2 places (#L1309): new `avg_cost` is `numeric(18,4)`.
- Negative on-hand stock would distort the average (no guard).
- Creating products and categories from the purchase form (#L47-120): new rule is products come from C02.
- Money is JS `number`; the invoice has no tax.

Old tables → new tables:
- purchase_invoices.total_amount → purchase_invoices.total (+ subtotal, tax_total)
- purchase_invoices.status (PENDING/APPROVED/REJECTED/VOID) → purchase_invoices.status (`purchase_invoice_status`; starts at `draft`)
- purchase_items.unit_cost/quantity → purchase_invoice_lines.unit_cost/quantity
- purchase_invoices.amount_paid, outstanding_amount → no match (derived from supplier_payment_allocations)

Gaps vs the slice goal:
- No VAT per line, no serials for serialized products, no branch, no supplier invoice number, no purchase order link, no approval threshold.

## U03 · Supplier payments (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/server/src/services/purchases.ts#L178-200 — `settlePurchaseDebt`
- FinTech-Pro-Deployed/database_schema#L499-507 — `purchase_settlements`
- FinTech-Pro-Deployed/database_schema#L1333-1352 — settlement trigger (vault − amount, outstanding − amount)
- FinTech-Pro-Deployed/client/src/pages/PurchasesPage.tsx#L199-225 — open/submit payment; modal #L743-
- FinTech-Pro-Deployed/client/src/services/api.ts#L545-557 — `purchasesAPI` (settle)

Keep (Port):
- Payment modal: pick vault, amount, remaining on the invoice, confirm. Arabic message for "vault balance is not enough".

Don't reuse:
- Balance pre-check in JS (#L181-182): race-prone; the new check is the `INSUFFICIENT_FUNDS` trigger error.
- Direct `UPDATE vaults SET balance` in the trigger (#L1336).
- One payment is tied to one invoice: new is one payment allocated across invoices.
- No overpayment guard against the invoice total, no idempotency.

Old tables → new tables:
- purchase_settlements → supplier_payments + supplier_payment_allocations
- purchase_settlements.vault_id → supplier_payments.cash_account_id
- purchase_settlements.purchase_invoice_id → supplier_payment_allocations.purchase_invoice_id

Gaps vs the slice goal:
- No payment against the supplier as a whole (auto-allocation), no reversal, no branch/business date, no payment number.

## U04 · Purchase returns (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/server/src/services/purchaseReturns.ts#L9-58 — create return
- FinTech-Pro-Deployed/server/src/controllers/purchaseReturns.ts — controller
- FinTech-Pro-Deployed/client/src/pages/PurchasesPage.tsx#L227-260 — return modal logic
- FinTech-Pro-Deployed/database_schema#L509-528 — `purchase_returns`, `purchase_return_items`
- FinTech-Pro-Deployed/database_schema#L1355-1376 — return trigger
- FinTech-Pro-Deployed/client/src/services/api.ts#L558-562 — `purchaseReturnsAPI`

Reference only (Rewrite):
- Return modal fields: invoice, product, quantity, reason; the Arabic labels on the button and modal.

Don't reuse:
- `unit_cost` and `quantity` come from the client (#L29, #L47-52): no cap by purchased or already returned quantity.
- Header and lines are two separate inserts, not one transaction (#L33-55).
- The trigger only lowers the supplier payable (#L1365-1368): no refund mode (cash back or credit), no cash movement.
- Stock is reduced with no check that the goods are sellable/on hand.

Old tables → new tables:
- purchase_returns.total_amount → purchase_returns.total (+ subtotal, tax_total)
- purchase_return_items → purchase_return_lines
- purchase_returns (no refund info) → purchase_returns.refund_mode, cash_account_id

Gaps vs the slice goal:
- No refund mode, no reason field, no serial returns, no document number, no idempotency.

## K01 · Vaults (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/VaultsPage.tsx — vault cards, create/edit modal #L150, transfer modal #L161, ledger modal #L181
- FinTech-Pro-Deployed/server/src/services/vaults.ts#L5-119 — list, create, update, transfer, ledger
- FinTech-Pro-Deployed/server/src/routes/vaultsManage.ts — manage routes
- FinTech-Pro-Deployed/database_schema#L279-289 — `vaults`
- FinTech-Pro-Deployed/database_schema#L423-435 — `vault_transactions`
- FinTech-Pro-Deployed/database_schema#L1175-1199 — `transfer_between_vaults`
- FinTech-Pro-Deployed/client/src/services/api.ts#L671-686 and #L807-819 — `vaultsAPI`, `vaultsManageAPI`

Keep (Port):
- Page: vault cards with balance, total, create/edit, transfer between two vaults, ledger list per vault.
- Transfer rule: lock the source, reject if balance is too low (#L1186-1189), one ledger row.

Don't reuse:
- `balance` column updated directly by triggers (#L1128, #L1146, #L1191-1192): new balances come from `cash_movements`.
- `is_main_vault` flag: new model has account kinds and branches.
- Transfer takes no idempotency key and writes one row, not two linked movements.

Old tables → new tables:
- vaults.name/is_active → cash_accounts.name/is_active (archived_at)
- vaults.is_main_vault → cash_accounts.kind = 'safe' | 'bank' | 'drawer' (no flag)
- vaults.balance → cash_balances (never written directly)
- vault_transactions → cash_movements
- transfer_between_vaults → cash_transfers

Gaps vs the slice goal:
- No branch link, no bank vs safe kind, no opening balance entry, no permission checks per vault.

## K02 · Shifts / cash drawer (Port: UI)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/ShiftsPage.tsx — two tabs: "my shift" (open / close with counted cash) and "history" for managers
- FinTech-Pro-Deployed/server/src/services/shifts.ts#L4-118 — active shift, open, close, history
- FinTech-Pro-Deployed/database_schema#L451-468 — `shift_sessions`
- FinTech-Pro-Deployed/database_schema#L1379-1436 — concurrency and close-transfer triggers
- FinTech-Pro-Deployed/client/src/services/api.ts#L645-670 — `shiftsAPI`

Keep (Port):
- Screens: open (opening float), close (counted cash, notes), expected vs actual vs difference, history tab for managers (`activeTab` "my_shift" / "history", #L25).
- Arabic labels incl. 'عجز' for a shortage.

Don't reuse:
- `expected_closing_balance` = whole vault balance (shifts.ts#L79): wrong, it must be this shift's cash only.
- Trigger moves the full counted amount to the main vault on close (#L1420-1426).
- Hard-coded "max 2 open shifts per branch" (#L1388).
- Shortage stored as Arabic text in the DB (#L1410).

Old tables → new tables:
- shift_sessions.starting_balance → shifts.opening_float
- actual_closing_balance → shifts.counted_cash; expected_closing_balance → shifts.expected_cash
- vault_id → shifts.drawer_account_id; notes → shifts.difference_reason
- status 'OPEN'/'CLOSED' → shifts.status (`shift_status`)
- difference_amount, shortage_status, transferred_to_vault → no match

Gaps vs the slice goal:
- No denomination count (`count_breakdown`), no device, no shift number, no idempotency, no float-in/out movements.

## R01 · Customers (Port: national ID parser, CRM UI)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/CRMPage.tsx#L25-58 — **national ID parser** (`govMap` #L25-33, `parseNationalId` #L35-58)
- FinTech-Pro-Deployed/server/src/services/customers.ts#L10-63 — Egyptian phone normalizer (#L10-27) and the same parser on the server (`govMap` #L30-38, `parseNationalId` #L40-63)
- FinTech-Pro-Deployed/client/src/lib/validation.ts#L27-67 — name, phone and national-ID validators; `validateCustomerForm` #L94-128
- FinTech-Pro-Deployed/client/src/pages/CRMPage.tsx#L452-750 — customer form modal; list + filters (`STATUS_FILTER_OPTIONS` #L63-68)
- FinTech-Pro-Deployed/client/src/services/api.ts#L264-346 — `CustomerRecord`, `customersAPI`
- FinTech-Pro-Deployed/database_schema#L182-213 — `customers`

Keep (Port):
- Parser: digit 1 = century (2 → 19xx, 3 → 20xx), digits 2-7 = YYMMDD, digits 8-9 = governorate code, digit 13 odd = male / even = female. The `govMap` has all 27 governorates + 88 (outside Egypt). Port it as a pure server function returning `{ birth_date, gender: 'male'|'female', governorate_code }`.
- Phone normalizer `01[0125]xxxxxxxx` ↔ `+20`; CRM screen: search, status filter (نشط / غير نشط / محظور), sortable table, form sections (job, housing, bank, notes), Arabic error messages.

Don't reuse:
- The parser does not check the date is real (month 13, Feb 30) and accepts only centuries 2 and 3 while `validation.ts#L47` accepts 4: pick one rule and test it.
- The check-digit in `validation.ts#L59-66` is not an official, verifiable algorithm: do not use it to reject IDs without confirming it first.
- `deriveCreditLimit` = income × 3 (customers.ts#L8): R03.
- Customer + `persons` row created in two steps; national ID returned to every role (new PII rule is `customer.view_pii`).

Old tables → new tables:
- customers.full_name/national_id/monthly_income/credit_limit/status/address/city/job → same names in customers (status → `customer_status`)
- customers.phone → customers.phones[]
- parsed birth date / gender → customers.birth_date / gender
- customers.employer_address → customers.employer
- customers.credit_score, housing_type, marital_status, job_type, bank_*, iban, internal_code, latitude/longitude, area, branch_id → no match

Gaps vs the slice goal:
- No duplicate check on national ID/phone, no ID image upload, no archive, no business customer (tax no.), no PII gating.

## R03 · Credit profile and limit (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/client/src/lib/xcore.ts#L7-29 — `XConfig` (the rule names and defaults)
- FinTech-Pro-Deployed/client/src/lib/xcore.ts#L59-117 — `evaluateCustomer` (browser score)
- FinTech-Pro-Deployed/server/src/services/customers.ts#L8 — `deriveCreditLimit`
- FinTech-Pro-Deployed/server/src/services/surveys.ts#L199-241 — survey approval overwrites the score
- FinTech-Pro-Deployed/client/src/pages/SettingsPage.tsx#L195-215 — credit-policy fields

Reference only (Rewrite):
- Field names: job type (GOV_EMPLOYEE / PRIVATE / SELF_EMPLOYED / NONE), housing (OWNED / RENTED / TEMPORARY), guarantor strength, late days, active contracts, legal cases.
- Score weight names: guarantors 40, income 30, residence 20, identity 10, and the Arabic labels on the settings screen.

Don't reuse:
- All of `xcore.ts`: it runs in the browser (only `POSPage.tsx` imports it) and is never enforced by the server.
- `income × 3` limit; a "multiplier of 5" in `XConfig`: the two disagree.
- Survey approval sets `customers.credit_score = weighted × 10` (surveys.ts#L223-232): a visit score replaces the whole profile.
- Exposure (what the customer already owes) is never subtracted.

Old tables → new tables:
- customers.credit_limit → customers.credit_limit (+ org_settings.credit_limit_income_multiple)
- customers.credit_score → no match
- system_settings.creditPolicy → org_settings.credit_min_score, credit_score_weights

Gaps vs the slice goal:
- No server-side exposure (remaining credit), no blacklisting rule, no limit history.

## R04 · Guarantors (Port)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/server/src/services/customers.ts#L345-413 — `processGuarantors` (upsert person, guarantor, link)
- FinTech-Pro-Deployed/client/src/pages/CRMPage.tsx#L187-190 — add-guarantor rows in the customer form (fields full name, phone, national ID, relation)
- FinTech-Pro-Deployed/client/src/services/api.ts#L293-302 — `GuarantorInput`
- FinTech-Pro-Deployed/database_schema#L215-232 — `guarantors`, `client_guarantors`

Keep (Port):
- Form rows: name, phone, national ID, relation, job, monthly income; "add another" button; show the guarantor next to the customer (customers.ts#L330-341).

Don't reuse:
- Every edit deletes all links and re-inserts (#L301-306): not atomic.
- Min 1 / max 3 guarantors and "score ≥ 50" live only in `xcore.ts#L15-19` (browser).
- `persons` row per guarantor.

Old tables → new tables:
- guarantors.full_name/national_id/phone/address → guarantors (same names)
- client_guarantors → customer_guarantors (adds `relation`)
- guarantors.id → persons.id → no match

Gaps vs the slice goal:
- No guarantor job/income screen, no link to a contract (new: `contract_guarantors`), no ID file.

## R05 · Field surveys (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/SurveyPage.tsx — field form + review list; `CRITERIA_LABELS` #L10-17
- FinTech-Pro-Deployed/server/src/services/surveys.ts#L5-22 — haversine distance, `SCORE_WEIGHTS`
- FinTech-Pro-Deployed/server/src/services/surveys.ts#L43-264 — create (GPS check #L96-97, photo/signature upload #L133-165), list, approve, reject
- FinTech-Pro-Deployed/server/src/controllers/surveys.ts — multipart controller (multer); FinTech-Pro-Deployed/client/src/services/api.ts#L563-644 — `SurveyRecord`, `surveysAPI`
- FinTech-Pro-Deployed/database_schema#L616-649 — `field_surveys`, `survey_attachments`

Keep (Port):
- Six 1-10 criteria and labels: جودة السكن، جودة الحي، استقرار الدخل، الحالة الوظيفية، ملكية العقار، الانطباع العام.
- Capture GPS + accuracy; flag "suspicious" when the visit is more than 500 m from the customer's address (#L96-97), as a field to show the reviewer, not a block.
- Photos + signature attachments; approve / reject with reason.

Don't reuse:
- Approval writes a credit score on the customer (#L223-232): R03.
- Files go to a **public** bucket path (`/storage/v1/object/public/survey_files/…`, #L143, #L159): homes and signatures must be private.
- The visiting employee creates the survey from scratch (new flow: assigned → submitted → decided); a guarantor is created inline.

Old tables → new tables:
- field_surveys.employee_id → field_surveys.assigned_to
- latitude/longitude/gps_accuracy → lat/lng/gps_accuracy_m
- the six score columns → field_surveys.scores (jsonb)
- status PENDING/APPROVED/REJECTED → field_surveys.status (`survey_status`, starts at `assigned`)
- reviewed_by/reviewed_at → decided_by/decided_at; recommendation, rejection_reason → notes; survey_attachments → files (F14)
- is_suspicious_location, guarantor_id → no match

Gaps vs the slice goal:
- No assignment by a manager, no offline capture, no re-visit, no link from a survey to a contract decision.

## S01 · Sale core (Rewrite)
Confidence: high

Old files:
- FinTech-Pro-Deployed/database_schema#L1571-1732 — `create_pos_sale` (the whole sale in one SQL function)
- FinTech-Pro-Deployed/server/src/services/pos.ts#L66-102 — `createSale` (calls the function)
- FinTech-Pro-Deployed/server/src/controllers/pos.ts — controller
- FinTech-Pro-Deployed/client/src/services/api.ts#L199-262 — `CreateSalePayload`, `SaleResult`, `posAPI`
- FinTech-Pro-Deployed/database_schema#L292-326 — `contracts`, `contract_items`

Reference only (Rewrite):
- Payload fields: items (product, qty), sale type (CASH / SHIPPING / INSTALLMENT), customer, shipping fee, down payment, installment count, notes.
- Result shown to the cashier: contract id, total, remaining, short receipt reference (first 8 chars of the id).

Don't reuse:
- Subtotal always uses `cash_price` (#L1631) while the stored line uses `installment_price` (#L1669-1672): totals and lines disagree on installment sales.
- Stock checked without a lock (#L1627): two cashiers can sell the last unit.
- No tax, no discount (columns exist but are never used), no serials, no document number, no idempotency key.
- Cash and installment sales share one `contracts` table; payment goes to the shift's vault with no payment method split.
- `SECURITY DEFINER` with org and employee passed as parameters instead of taken from the session.

Old tables → new tables:
- contracts (sale_type CASH/SHIPPING) → sales (+ sale_lines)
- contract_items → sale_lines; inventory_transactions → stock_movements
- payments → payments + payment_allocations; shift_sessions → shifts

Gaps vs the slice goal:
- No tax/VAT snapshot, discount caps, serial units, store credit, split payments, or reservations.

## S06 · POS screen (Port)
Confidence: high

Old files:
- FinTech-Pro-Deployed/client/src/pages/POSPage.tsx — the cashier screen (product grid, cart, customer picker, sale type, checkout)
- FinTech-Pro-Deployed/client/src/components/SearchFilterBar.tsx — search + filter bar
- FinTech-Pro-Deployed/client/src/components/SubmitButton.tsx — submit button with loading state
- FinTech-Pro-Deployed/client/src/services/api.ts#L226-262 — `POSProduct`, `POSCategory`, `posAPI`

Keep (Port):
- Layout: product grid + category chips on one side, cart on the other; barcode/name search; qty +/- with stock clamp (#L209) as a hint.
- Cart kept in `sessionStorage` (`POS_CART_STORAGE_KEY`, #L32, #L112-125) so a refresh doesn't lose it.
- Sale-type toggle (نقدي / شحن / تقسيط) and the Arabic notifications on checkout (#L325-353).

Don't reuse:
- Totals and price per sale type computed in the browser (`getPrice` #L94, total #L228): show only; the server is the source of truth.
- `XCore.calculateSaleTerms` and `xCoreValidation` (#L286-299): browser credit logic.
- Months/down payment rules (#L341).

Old tables → new tables:
- UI only; reads products, categories, vaults and customers through `posAPI` (see C02, K01, R01).

Gaps vs the slice goal:
- No discount entry, no tax line, no serial picker, no split payment, no held sales, no receipt print.

## N02 · Installment sale and contract (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/client/src/lib/xcore.ts#L119-182 — `calculateSaleTerms` (down payment, months, documents)
- FinTech-Pro-Deployed/client/src/pages/POSPage.tsx#L286-345 — installment panel in the POS
- FinTech-Pro-Deployed/database_schema#L1686-1705 — installment schedule inside `create_pos_sale`
- FinTech-Pro-Deployed/database_schema#L292-342 — `contracts`, `installments`

Reference only (Rewrite):
- Fields to show: down payment, number of installments, installment amount, due dates, "documents required" (RECEIPTS / CHECKS, xcore.ts#L176-180 with Arabic text).
- Schedule table layout (due date, amount, status PENDING / PARTIALLY_PAID / PAID).

Don't reuse:
- Hard-coded tiers (≤100,000 → 10 months, ≤1,000,000 → 15 months), "one month prepaid" down payment (xcore.ts#L20-28): new rules come from `installment_policies`.
- Remaining ÷ N with no markup; `profit_portion` always 0 (#L1699-1702).
- Due dates from the 1st of next month, no frequency options.
- Rule check in the browser only; the server accepts any count and down payment.

Old tables → new tables:
- contracts.total_amount → contracts.total_payable (+ cash_price, financed_amount, markup_pct)
- contracts.down_payment → contracts.down_payment
- installments.amount/principal_portion/profit_portion → schedule_lines.amount (generated)/principal/profit
- installments.paid_amount/status → derived from payment_allocations
- contracts.remaining_amount → no match

Gaps vs the slice goal:
- No policy version snapshot, no markup tiers, no guarantor requirement, no contract number, no reschedule.

## N03 · Collections (Port: oldest-first allocation SQL)
Confidence: high

Old files:
- FinTech-Pro-Deployed/database_schema#L1439-1474 — **oldest-first allocation SQL** (`cascade_installment_payment`; the loop is #L1447-1462)
- FinTech-Pro-Deployed/client/src/pages/CollectionPage.tsx — pending installments with an overdue label by days late (#L13), payment modal #L372-, expense modal
- FinTech-Pro-Deployed/server/src/services/collections.ts#L4-78 — `recordCollection`
- FinTech-Pro-Deployed/server/src/services/collections.ts#L79-105 — `getPendingInstallments`
- FinTech-Pro-Deployed/client/src/services/api.ts#L742-757 — `collectionsAPI`
- FinTech-Pro-Deployed/database_schema#L328-342 and #L393-409 — `installments`, `payments`

Keep (Port):
- Allocation rule: take unpaid installments in due-date order, apply `LEAST(remaining, amount − paid)` to each, mark PAID or PARTIALLY_PAID, stop when the payment is used up (#L1447-1462).
- Screen: pending installments list with customer, due date, remaining; "collect" opens a modal with amount; Arabic status labels.

Don't reuse:
- Ordered by `due_date` only (#L1450): ties are not stable; new order is `schedule_lines.seq` (charges such as late fees first, per the slice).
- Overpayment is only a `RAISE NOTICE` (#L1464-1466): the money is accepted and lost; new rule must refuse or credit it.
- No principal/profit split, no allocation rows: `paid_amount` is edited in place.
- Runs as an `AFTER INSERT` trigger on `payments` for any payment, no idempotency key.
- `recordCollection` forces the main vault as `vault_id` (#L40-50).

Old tables → new tables:
- installments → schedule_lines (+ payment_allocations.schedule_line_id)
- payments (is_collection) → payments (direction 'in') + payment_allocations
- installments.paid_amount/status → derived from payment_allocations
- payments.applies_to_installment_id → payment_allocations.schedule_line_id

Gaps vs the slice goal:
- No late fees (`charges`), no receipt number, no allocation across several contracts of a customer, no reversal.

## N06 · Collector wallets (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/server/src/services/wallets.ts#L14-207 — my wallet, settle, field expense
- FinTech-Pro-Deployed/server/src/controllers/wallets.ts — controller
- FinTech-Pro-Deployed/database_schema#L363-388 — `wallets`, `wallet_transactions`
- FinTech-Pro-Deployed/database_schema#L1477-1503 — commission trigger
- FinTech-Pro-Deployed/client/src/pages/CollectionPage.tsx — wallet summary and field-expense modal
- FinTech-Pro-Deployed/client/src/services/api.ts#L687-741 — `WalletSummary`, `walletsAPI`

Reference only (Rewrite):
- Screens: wallet balance card, today's collections, settlement form (actual cash vs expected), field expense form.
- Labels: عجز / زيادة for shortage / surplus (wallets.ts#L102).

Don't reuse:
- The commission is **added to the wallet balance** (#L1492): commission is owed to the collector, it is not cash they hold.
- `settleWallet` sets `balance = 0` and moves cash to the main vault in several separate calls (#L112-150): not atomic.
- Wallet has an OPEN/CLOSED state with `starting_balance`; direct `UPDATE wallets` everywhere.
- Collections must have a wallet and are booked to the main vault.

Old tables → new tables:
- wallets → cash_accounts (kind 'collector_wallet', `employee_id`)
- wallet_transactions → cash_movements
- commission rows (wallet_transactions 'COMMISSION') → collector_commissions
- wallets.shortage_status / expected / actual → no match (settlement is a transfer + adjustment)

Gaps vs the slice goal:
- No commission payout flow, no approval of the settlement by a second person, no per-day wallet report.

## D01 · Owner dashboard (Port: UI)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/client/src/pages/GoldenDashboard.tsx — owner screen: KPI cards #L53-, 7-day revenue/expense bar chart #L103-114 (recharts)
- FinTech-Pro-Deployed/client/src/pages/HomePage.tsx — daily home: welcome header and summary sections
- FinTech-Pro-Deployed/server/src/services/dashboard.ts#L4-147 — data for both pages
- FinTech-Pro-Deployed/client/src/services/api.ts#L820-850 — `HomeDashboardData`, `GoldenDashboardData`, `dashboardAPI`

Keep (Port):
- Layout: top KPI row (cash in vaults, receivables, payables, today's revenue/expenses) and the bar chart.
- Arabic KPI labels; the owner-only route.

Don't reuse:
- Totals computed in JS from full table selects (dashboard.ts#L104-108): unbounded and slow.
- Chart loop runs queries per day (#L111-125).
- "Cash" adds vaults and collector wallets together (#L104-105).
- Receivables computed as `amount − paid_amount` over installments.

Old tables → new tables:
- vaults.balance → cash_balances; installments → schedule_lines (+ allocations)
- purchase_invoices.outstanding_amount → derived from invoices − supplier_payment_allocations

Gaps vs the slice goal:
- No branch filter, no overdue ageing, no top products, no profit figure.

## M01 · Import (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/client/src/pages/DataBridgePage.tsx — upload, column mapping screen (#L39, #L240)
- FinTech-Pro-Deployed/server/src/services/dataBridge.ts#L5-232 — parse, map, duplicate check, insert
- FinTech-Pro-Deployed/server/src/controllers/dataBridge.ts — multipart controller
- FinTech-Pro-Deployed/client/src/services/api.ts#L377-385 — `dataBridgeAPI`
- FinTech-Pro-Deployed/database_schema#L652-657 — `data_imports`

Reference only (Rewrite):
- Screen idea: upload → map each field to a file column → import; list of target fields per table (customers, products, suppliers).
- Duplicate keys: customer by phone/national ID, supplier by name/phone, product by sku/barcode (#L28-88).

Don't reuse:
- CSV headers read in the browser by splitting on `,` (DataBridgePage.tsx#L68): breaks on quoted commas.
- No dry run and no row-level error report: it inserts, then returns counts.
- `data_imports` is a one-time lock per table, so a shop can't re-import.
- `persons` + customer inserts are separate calls (#L179-222); service-role writes.
- Only 3 tables: no opening stock, no opening balances.

Old tables → new tables:
- data_imports → import_jobs (kind, status, dry_run, rows_ok/rows_failed, report)

Gaps vs the slice goal:
- No opening stock, no Excel sheet choice, no template download, no error file, no background job.

## M03 · Full export (Rewrite)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/server/src/services/dataBridge.ts#L234-254 — `exportData` (one table to CSV)
- FinTech-Pro-Deployed/server/src/controllers/dataBridge.ts — export endpoint
- FinTech-Pro-Deployed/client/src/pages/DataBridgePage.tsx — export buttons

Reference only (Rewrite):
- Screen: pick a table, download. Allowed list is customers / products / suppliers.

Don't reuse:
- `select('*')` of a whole table into memory, then string-joined CSV (#L238-252).
- No guard against spreadsheet formulas (cells that start with `=`, `+`, `-`, `@`).
- Exports raw national IDs with no permission check; no UTF-8 BOM, so Arabic opens broken in Excel.
- Returns an error when a table is empty.

Old tables → new tables:
- customers/products/suppliers → customers/products/suppliers (the new export covers every entity; see the new data model)

Gaps vs the slice goal:
- Not "all data": no sales, contracts, payments, stock or ledgers; no zip, no background job, no download log.

## L01 · Legal module (Port: UI shell)
Confidence: medium

Old files:
- FinTech-Pro-Deployed/client/src/pages/LegalPage.tsx — cases list, add/edit/view modal (#L99-215), hearings and documents forms (#L60-98)
- FinTech-Pro-Deployed/database_schema#L531-558 — `legal_documents`, `legal_cases`, `legal_attachments`

Keep (Port):
- Page shell: cases table with status badges, filters, add/edit/view modal, hearings list, documents list.
- Case statuses and colors (#L82-98): مفتوحة، منظورة، محكوم فيها، منتهية، مطعون فيها.
- Hearing form fields: date, number, result, next date, notes; document form: name, type, file.

Don't reuse:
- The page has **no API calls and no server routes**: `useEffect` is imported but never used and state starts empty, so nothing loads or saves. Treat it as a mock.
- `invoice_id` as the link (#L60) and a `synced` flag (#L65): new link is `contract_id`.
- The 3 old tables hold only a title/url, case number and status.

Old tables → new tables:
- legal_cases → legal_cases (adds contract_id, court, lawyer_employee_id, claim_amount, status `legal_status`)
- hearing form → legal_hearings; notes → legal_case_notes
- legal_documents / legal_attachments → files

Gaps vs the slice goal:
- No backend at all, no referral rule (days overdue), no customer ban, no lawyer role screen.

---

## Shared assets

- **Translation files / string tables:** none. Arabic strings are inline in the components, so only the labels listed per slice can be copied by hand into the new Arabic/English files. Sidebar menu labels: `FinTech-Pro-Deployed/client/src/components/Sidebar.tsx#L50-100`.
- **Shared UI components:** `FinTech-Pro-Deployed/client/src/components/SearchFilterBar.tsx`, `SortableHeader.tsx`, `SubmitButton.tsx`, `LoadingScreen.tsx`, `AuthLayout.tsx`, `Sidebar.tsx`; layout `FinTech-Pro-Deployed/client/src/layouts/MainLayout.tsx`; class helper `FinTech-Pro-Deployed/client/src/lib/utils.ts`. There are no date-picker, money-input or table/dialog components: each page builds its own modal.
- **Receipt and print templates:** none found (searched for print, receipt, إيصال, فاتورة).
- **Egyptian lists:** governorates (code → Arabic name, 27 + 88): `FinTech-Pro-Deployed/client/src/pages/CRMPage.tsx#L25-33` and `FinTech-Pro-Deployed/server/src/services/customers.ts#L30-38`. No cities list.
- **Formatting helpers:** none shared. Money and dates use inline `toLocaleString` / `toLocaleDateString` (e.g. `FinTech-Pro-Deployed/client/src/pages/PartnersPage.tsx`, `CollectionPage.tsx`, `GoldenDashboard.tsx`); no Arabic-numeral helper.
- **Validators worth reading:** `FinTech-Pro-Deployed/client/src/lib/validation.ts#L25-92` (name, Egyptian phone, email, password), with the caveats under R01.

## Do not reuse anywhere

- FinTech-Pro-Deployed/client/src/lib/xcore.ts — X-Core credit engine: runs in the browser, only `POSPage.tsx` imports it, the server never enforces it.
- FinTech-Pro-Deployed/client/src/pages/POSPage.tsx#L228 and #L286-299 — money, credit and installment math in the browser.
- FinTech-Pro-Deployed/client/src/pages/ActivationPage.tsx and FinTech-Pro-Deployed/client/src/pages/ClaimPage.tsx — old license-key flow.
- FinTech-Pro-Deployed/client/src/App.tsx#L43-77 and #L103-109 — license-key gate (routes depend on a key in `localStorage`).
- FinTech-Pro-Deployed/client/src/lib/validation.ts#L88-92 and #L131-136 — license-key validation.
- FinTech-Pro-Deployed/database_schema#L65-80 — `saaslicenses` table.
- FinTech-Pro-Deployed/server/src/utils/supabase.ts — `supabaseAdmin`, a service-role client used by every service (26 files): bypasses RLS. No service-role or Supabase client was found in `client/src`.
- FinTech-Pro-Deployed/server/src/utils/transaction.ts — `TransactionTracker`, manual undo instead of a DB transaction.
- FinTech-Pro-Deployed/database_schema#L17 — `DROP SCHEMA public CASCADE` at the top of the schema file.
- FinTech-Pro-Deployed/database_schema#L1122-1155 and #L1280-1503 — balance/stock triggers that update columns directly (new rule: ledger only).
- FinTech-Pro-Deployed/client/src/lib/validation.ts#L179-193 — `ALL_STORES`, leftover offline-store names.
- FinTech-Pro-Deployed/client/src/lib/notifications.ts — empty stubs left after removing offline sync.

## Secrets found

Paths and lines only. No value is recorded here.
- FinTech-Pro-Deployed/client/.env: file exists (not opened).
- FinTech-Pro-Deployed/server/.env: file exists (not opened).
- FinTech-Pro-Deployed/client/.env.example and FinTech-Pro-Deployed/server/.env.example: templates; they list the variable names for Supabase URL/keys, the service-role key and the frontend URL.
- FinTech-Pro-Deployed/database_schema#L1739: seed admin email.
- FinTech-Pro-Deployed/database_schema#L1741: hard-coded master license key in the seed block.
- No hard-coded API key, token or connection string found in `client/src` or `server/src`.

## Already-built slices: UI reference only

- P01 (super-admin shop screens): FinTech-Pro-Deployed/client/src/pages/SuperAdminPage.tsx (license list with search by key/plan, and a shop list with search by name/owner/phone).
- O01 (branches): no dedicated old screen. Branch data appears only inside `FinTech-Pro-Deployed/client/src/pages/SuperAdminPage.tsx` (plan limits) and the branch field on `FinTech-Pro-Deployed/client/src/pages/CRMPage.tsx`.
- O02 (employees): FinTech-Pro-Deployed/client/src/pages/UserManagementPage.tsx (employee list, create/edit, roles); HR extras in FinTech-Pro-Deployed/client/src/pages/HRPage.tsx.
