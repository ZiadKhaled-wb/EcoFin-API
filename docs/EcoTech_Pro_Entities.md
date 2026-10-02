# EcoTech Pro: Entity Diagram (Conceptual, V1)

*Draft 1, 2 Oct 2026. Built from EcoTech_Pro_Slices.md. It shows the business objects and how they relate, not tables or columns: the physical ERD comes after the audit and will match the new repos.*

**How to read the lines:** `||` = exactly one, `o|` = zero or one, `|{` = one or more, `o{` = zero or more.

---

## Design decisions in this model

Each one fixes a problem from the old system.

1. **One stock ledger.** Every stock change is a `STOCK_MOVEMENT` pointing to the document that caused it. Stock on hand = sum of movements. (Fixes stock counted twice.)
2. **One cash ledger for every place money sits.** Safe, bank, cashier drawer and collector wallet are all a `CASH_ACCOUNT`, so all money moves as `CASH_MOVEMENT`. (Fixes collections credited twice, vault/wallet confusion.)
3. **Payments are separate from what they pay.** A `PAYMENT` splits into `PAYMENT_ALLOCATION`s, so one payment can cover a sale, a deposit, several installments or a late fee. Refunds are payments going out.
4. **A product is not a unit.** `PRODUCT` is the definition. `UNIT` is one physical serialized item (IMEI) with its own history and warranty.
5. **Selling now vs delivering later.** POS sells directly as a `SALE`. Furniture goes `QUOTATION → SALES_ORDER → DELIVERY`, and each delivery issues the `SALE` (invoice) for the delivered lines only.
6. **Documents are never edited.** A `RETURN` points to its `SALE`. A `CONTRACT_CHANGE` (settlement, reschedule, write-off) points to its `CONTRACT` and keeps the old schedule.
7. **Every receipt goes to the ETA once.** `SALE` and `RETURN` each have one `FISCAL_SUBMISSION`, sent from a registered `DEVICE`.

Every entity below belongs to one `ORGANIZATION` (shop). Those lines are left out of the diagrams to keep them readable.

---

## 0. Overview: how the areas connect

```mermaid
flowchart LR
  ORG["Organization & access<br/>shop, branches, users, roles, devices, audit"]
  CAT["Catalog & inventory<br/>products, units, stock ledger, transfers, counts"]
  PUR["Purchasing<br/>suppliers, orders, invoices, returns"]
  SAL["Sales<br/>quotes, orders, deliveries, sales, returns, warranty"]
  INS["Installments & legal<br/>contracts, schedules, fees, changes, cases"]
  MON["Money & tax<br/>cash accounts, cash ledger, payments, shifts, ETA"]
  CUS["Customers<br/>customers, guarantors, surveys"]

  ORG --> CAT & PUR & SAL & MON
  PUR -->|stock in| CAT
  SAL -->|stock out| CAT
  CUS --> SAL & INS
  SAL -->|financed by| INS
  SAL & INS & PUR -->|money in/out| MON
```

---

## 1. Organization & access

```mermaid
erDiagram
  ORGANIZATION ||--|| SUBSCRIPTION : "is on"
  ORGANIZATION ||--|| SETTINGS : "has policy"
  ORGANIZATION ||--|| LEGAL_PROFILE : "has"
  ORGANIZATION ||--|{ BRANCH : "has"
  ORGANIZATION ||--o{ USER : "employs"
  USER }o--|| ROLE : "has"
  ROLE }o--o{ PERMISSION : "grants"
  USER }o--o{ PERMISSION : "extra grants"
  USER }o--o{ BRANCH : "works in"
  BRANCH ||--o{ DEVICE : "has POS devices"
  ORGANIZATION ||--o{ DOCUMENT_SEQUENCE : "numbers documents"
  USER ||--o{ AUDIT_ENTRY : "performs"
  ORGANIZATION ||--o{ FILE : "stores"
```

- `LEGAL_PROFILE` holds the legal seller and creditor model (in-house in V1).
- `DEVICE` is a registered POS terminal. The ETA needs it, and shifts and offline sales are tied to it.
- `SUPER_ADMIN` lives at platform level, outside any organization.

---

## 2. Catalog & inventory

```mermaid
erDiagram
  CATEGORY ||--o{ PRODUCT : "groups"
  TAX_CLASS ||--o{ PRODUCT : "taxes"
  PRODUCT ||--o{ UNIT : "has serialized units"
  BRANCH ||--o{ UNIT : "holds"
  PRODUCT ||--o{ STOCK_MOVEMENT : "moves"
  BRANCH ||--o{ STOCK_MOVEMENT : "at"
  UNIT |o--o{ STOCK_MOVEMENT : "moves"
  STOCK_TRANSFER ||--|{ TRANSFER_LINE : "has"
  TRANSFER_LINE }o--|| PRODUCT : "of"
  STOCK_TRANSFER ||--o{ STOCK_MOVEMENT : "causes"
  STOCK_COUNT ||--|{ COUNT_LINE : "has"
  STOCK_COUNT ||--o{ STOCK_MOVEMENT : "posts adjustments"
  ORDER_LINE ||--o| STOCK_RESERVATION : "reserves"
  STOCK_RESERVATION }o--|| PRODUCT : "of"
```

- Only products with the "serialized" flag have `UNIT`s.
- Available stock = on hand (movements) − reserved (`STOCK_RESERVATION`).
- A transfer creates two movements: out of the source when sent, into the destination when received.

---

## 3. Purchasing

```mermaid
erDiagram
  SUPPLIER ||--o{ PURCHASE_ORDER : "receives"
  PURCHASE_ORDER ||--|{ PO_LINE : "has"
  SUPPLIER ||--o{ PURCHASE_INVOICE : "bills"
  PURCHASE_INVOICE }o--o| PURCHASE_ORDER : "receives against"
  PURCHASE_INVOICE ||--|{ PI_LINE : "has"
  PI_LINE }o--|| PRODUCT : "of"
  PI_LINE ||--o{ UNIT : "creates"
  PURCHASE_INVOICE ||--o{ STOCK_MOVEMENT : "stock in on approval"
  PURCHASE_INVOICE ||--o{ APPROVAL : "needs"
  SUPPLIER ||--o{ SUPPLIER_PAYMENT : "is paid by"
  SUPPLIER_PAYMENT }o--|{ PURCHASE_INVOICE : "settles"
  SUPPLIER_PAYMENT ||--|| CASH_MOVEMENT : "cash out"
  PURCHASE_INVOICE ||--o{ PURCHASE_RETURN : "returned by"
  PURCHASE_RETURN ||--|{ PR_LINE : "has"
  PURCHASE_RETURN ||--o{ STOCK_MOVEMENT : "stock out"
  ORDER_LINE }o--o| PO_LINE : "special order"
```

- `APPROVAL` is generic: it's used here for amount thresholds, and later for price overrides and credit exceptions.
- A special furniture order line (`ORDER_LINE`) can point to the purchase order line that brings it in.

---

## 4. Sales

```mermaid
erDiagram
  CUSTOMER ||--o{ QUOTATION : "asks for"
  QUOTATION ||--|{ QUOTE_LINE : "has"
  SALES_ORDER |o--o| QUOTATION : "accepted from"
  CUSTOMER ||--o{ SALES_ORDER : "places"
  SALES_ORDER ||--|{ ORDER_LINE : "has"
  SALES_ORDER ||--o{ DELIVERY : "delivered by"
  DELIVERY ||--|{ DELIVERY_LINE : "has"
  DELIVERY_LINE }o--|| ORDER_LINE : "delivers"
  DELIVERY ||--|| SALE : "issues invoice"
  CUSTOMER |o--o{ SALE : "buys"
  SHIFT ||--o{ SALE : "made in"
  SALE ||--|{ SALE_LINE : "has"
  SALE_LINE }o--|| PRODUCT : "of"
  SALE_LINE }o--o| UNIT : "exact unit"
  SALE ||--o{ STOCK_MOVEMENT : "stock out"
  SALE ||--o{ RETURN : "returned by"
  RETURN ||--|{ RETURN_LINE : "has"
  RETURN_LINE }o--|| SALE_LINE : "reverses"
  SALE_LINE ||--o| WARRANTY : "covered by"
  WARRANTY ||--o{ WARRANTY_CLAIM : "has"
```

- A walk-in cash sale has no customer (`CUSTOMER |o`).
- A POS sale has no order. An order's sale is created by its delivery.
- An exchange = a `RETURN` + a new `SALE`, linked.

---

## 5. Customers, installments & legal

```mermaid
erDiagram
  CUSTOMER ||--o{ CONTRACT : "owes"
  CONTRACT |o--o| SALE : "finances"
  CONTRACT |o--o| SALES_ORDER : "finances"
  CUSTOMER }o--o{ GUARANTOR : "backed by"
  CONTRACT }o--o{ GUARANTOR : "guaranteed by"
  CONTRACT ||--|{ SCHEDULE_LINE : "due as"
  SCHEDULE_LINE ||--o{ CHARGE : "late fees"
  CONTRACT ||--o{ CONTRACT_CHANGE : "settled, rescheduled, written off"
  CONTRACT_CHANGE ||--o{ SCHEDULE_LINE : "new schedule"
  CUSTOMER ||--o{ FIELD_SURVEY : "visited in"
  USER ||--o{ FIELD_SURVEY : "performs"
  CONTRACT ||--o| LEGAL_CASE : "escalated to"
  USER ||--o{ LEGAL_CASE : "lawyer on"
  LEGAL_CASE ||--o{ HEARING : "has"
  LEGAL_CASE ||--o{ CASE_NOTE : "has"
  LEGAL_CASE ||--o{ FILE : "documents"
```

- The credit limit and status are fields on `CUSTOMER`. Exposure is calculated from open contracts, not stored.
- A contract finances either a direct sale or a sales order. **Open point:** confirm furniture installments start at order time, not at delivery.
- Rescheduling never edits old schedule lines. It closes them and the `CONTRACT_CHANGE` creates new ones.

---

## 6. Money, payments & tax

```mermaid
erDiagram
  BRANCH ||--o{ CASH_ACCOUNT : "has"
  USER |o--o| CASH_ACCOUNT : "collector wallet"
  CASH_ACCOUNT ||--o{ CASH_MOVEMENT : "moves"
  USER ||--o{ SHIFT : "works"
  DEVICE ||--o{ SHIFT : "on"
  SHIFT }o--|| CASH_ACCOUNT : "uses drawer"
  SHIFT ||--o{ CASH_MOVEMENT : "records"
  CUSTOMER |o--o{ PAYMENT : "pays or is refunded"
  PAYMENT ||--o| CASH_MOVEMENT : "moves cash"
  PAYMENT ||--|{ PAYMENT_ALLOCATION : "split into"
  PAYMENT_ALLOCATION }o--o| SALE : "pays"
  PAYMENT_ALLOCATION }o--o| SALES_ORDER : "deposit for"
  PAYMENT_ALLOCATION }o--o| SCHEDULE_LINE : "pays installment"
  PAYMENT_ALLOCATION }o--o| CHARGE : "pays fee"
  CUSTOMER ||--o{ STORE_CREDIT_MOVEMENT : "has credit"
  EXPENSE ||--|| CASH_MOVEMENT : "cash out"
  CASH_TRANSFER ||--|{ CASH_MOVEMENT : "out and in"
  BRANCH ||--o{ DAY_CLOSE : "closes"
  SALE ||--o| FISCAL_SUBMISSION : "sent to ETA"
  RETURN ||--o| FISCAL_SUBMISSION : "sent to ETA"
  DEVICE ||--o{ FISCAL_SUBMISSION : "submits"
```

- `CASH_ACCOUNT` types: safe, bank, drawer, collector wallet.
- Shift expected cash = opening float + that shift's `CASH_MOVEMENT`s, not the whole account balance.
- A payment by store credit moves `STORE_CREDIT_MOVEMENT` instead of cash. Overpayments land there too.
- A collection is a `PAYMENT` allocated to `SCHEDULE_LINE`s. It is not a new `SALE`, so there's no new revenue or VAT.

---

## Open points for you

1. **Furniture on installments:** does the contract start when the order is placed, or when the goods are delivered?
2. **Customers vs guarantors:** can the same person be a customer in one contract and a guarantor in another? If yes, they should share one `PERSON` record.
3. **Collector wallets:** one wallet per collector, or per collector per day?
