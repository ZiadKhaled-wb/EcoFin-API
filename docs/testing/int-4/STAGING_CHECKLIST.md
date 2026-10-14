# INT-4 → INT-6: repeat the cash sale on staging (for the person doing INT-6)

INT-4 proved checks a–k locally against a **fake** ETA, with a browser standing in for the POS computer,
a typed code standing in for the scanner and a print preview standing in for the printer. INT-6 repeats
them on **staging** with the client's **real ETA pre-production credentials**, a **real paired POS
computer**, the **real receipt printer** and the **real barcode scanner**. The steps below follow the
local run (`EcoFin-Web/e2e/int4-cash-sale.spec.ts`); the expected results are what passed locally.

Never use production ETA credentials here. Never write a credential, a pairing code or a device token
into a file, a ticket or a chat. Never point staging at a production ETA host.

## 0. Before you start

1. Read `docs/eta/SETUP.md` end to end.
2. **Pre-production smoke test** (SETUP.md §5) from a machine that can reach the ETA, with the shop's
   pre-production values in the shell only:
   ```bash
   export NODE_EXTRA_CA_CERTS=/path/to/preprod-root-ca.crt
   export ETA_TEST_CLIENT_ID=... ETA_TEST_CLIENT_SECRET=... ETA_TEST_POS_SERIAL=... \
          ETA_TEST_POS_OS_VERSION=... ETA_TEST_POS_MODEL_FRAMEWORK=... ETA_TEST_PRESHARED_KEY=... \
          ETA_TEST_RIN=... ETA_TEST_ACTIVITY_CODE=... ETA_TEST_BRANCH_CODE=... ETA_TEST_ITEM_CODE=...
   npm run eta:preprod-smoke
   ```
   **Expected:** `VALID <uuid>` twice, `RESULT: accepted`, then `duplicate check: refused as
   DuplicateSubmission`. Anything else: stop and follow the table in SETUP.md §5.3.
3. Settle the **four open ETA points** of `docs/eta/ERECEIPT_SPEC.md` (each marked *unverified* or
   *to verify in pre-production*). Write the answer in ERECEIPT_SPEC.md and in the INT-6 report:
   1. **Unsigned submissions** (§3, row 3 of §15): does pre-production accept `"signatures": []`? The smoke
      test answers it. If refused, CAdES-BES signing is needed before go-live (a story, not a fix).
   2. **QR text format** (§14, row 8): does the ETA's own app read our QR (date-time without
      milliseconds, total as on the receipt)? Scan a printed receipt's QR with the ETA's mobile app in
      step g.
   3. **Receipt type** (row 14): is the General receipt (`s`) allowed for the shop's activity code, or
      does it need a sector receipt (Retail `SR`)? An accepted smoke run answers it for that code.
   4. **Corrections and the POS chain** (§13a item 6): the ETA accepts a correction that takes the
      chain head's place (step h, the rejected receipt is the newest), **and** one sent after later
      receipts of the same POS (repeat h, but make one more sale before Correct and resend).
4. Staging data: the client's shop with the B2C tag, RIN, activity code, branch ETA code and building
   number (SETUP.md §3.1–3.2, §3.5 with **Pre-production**), an owner, a branch manager and two cashiers,
   discount caps CASHIER 5 % / BRANCH_MANAGER 15 %, a cash drawer (safe with cash for the float) and a bank
   account. Products: one with a registered item code, one serialized with 12 months warranty and at
   least 3 serials, one **without** an item code, and one with exactly 1 in stock. A second shop with ETA
   **off** for step j.
5. A real item code can't be "fixed" by typing any value: for step h you need a product whose code the ETA
   **rejects** (an unregistered EGS code) and a registered code to switch it to; for step i a product
   with no code and a registered one to set.

## The steps

| # | Do | Look at | Expected |
|---|---|---|---|
| a | Owner: **Settings → POS devices → Add device** (name, branch) → **Pair**. On the **real POS computer**, signed in as the cashier: **Pair this computer**, type the code. Owner: register the device's ETA values (serial, OS version, model framework, pre-shared key, Active; SETUP.md §2, §3.4) and **Test connection**. Cashier: **Accounting → Shifts**, opening float from the safe, **Open shift**. | the header shows the device name; Test connection; the shift screen | Code valid 15 min; header shows the device; "Connected"; the shift opens on that device with the float (DB: `shifts.device_id` set). |
| b | **Sales → POS**. Scan the normal product's barcode with the **real scanner** (it types the code and Enter). Scan the serialized product's SKU (or a serial). Add a 5 % line discount with a reason. | the cart | One scan adds one line; the serialized product asks for its serial (or the scanned serial adds that unit); 5 % is accepted without a manager. |
| c | Second line or new sale: 8 % discount. Cashier: **Ask a manager**. Manager, on **another computer**: **Sales → Discount approvals → Approve**. Cashier: pay. | cashier panel; manager list | "Waiting for a manager…" → "Approved by …"; the sale goes through. Sending the same approval again (API) → `APPROVAL_INVALID`. |
| d | Pay part cash (type the amount handed over), part **bank transfer** (account + reference). Double-click **Pay**. | payment dialog; completed screen | Change = handed over − cash part. Exactly one sale (the double click makes one). |
| e | After d | stock, unit, drawer, bank, sale | Stock −qty; the unit is `sold`; drawer + cash part; bank + transfer part; VAT per T01 (14 % inside the price); the next sale number in sequence; an audit row. |
| f | Wait for the job worker (`JOBS_ENABLED=true`). Make a second sale in the same shift. | **Tax → ETA receipts**; the ETA portal (pre-production) | Both `Accepted`; on the portal both receipts exist; the second one's `previousUUID` is the first one's UUID; no duplicate on the portal. |
| g | Sale page → **Print receipt** on the **real printer** (80 mm roll), Arabic. Print again. | the paper | Arabic, right to left; totals equal the sale; the discount; both payments and the change; the serial and the warranty end date; a QR (scan it with the ETA app: open point 2). The second print says **COPY**. |
| h | Sell the product with the **unregistered** code. | ETA receipts → the receipt's **Details** | `Rejected`, with the ETA's reason and the property (`itemData[0].itemCode`). Set a registered code on the product, open Details again → **Correct and resend** → `Accepted`; on the portal the new receipt's `referenceOldUUID` is the rejected one (open point 4). |
| i | Sell the product with **no** code. | ETA receipts → Details | `Blocked` (`BLOCKED:ITEM_CODE`); the diagnosis names the product; **Retry** is disabled until the code is set. Set it → open Details again → **Retry** → `Accepted`. |
| j | **Sales → Sales history**: search by the sold serial, then by the sale number. Open a shop-A sale whose receipt has a UUID. Then, in the ETA-off shop, sell and **Void sale** with a reason. | sale page; shop B stock and drawer | Found both ways. Shop A: no Void button, "The ETA receipt has been issued. Use a return." (API void refused). Shop B: "Sale voided", status Voided, stock and cash back. |
| k | **Sales → Warranty → Lookup** the sold serial → **Open claim** (issue, condition) → **Replace** with another in-stock serial → Confirm. Look up both serials. | claim page; lookup; stock | Claim `Replaced`; both serials show the serial history (the chain); stock: damaged +1, sellable −1. |

## After the run

- **Tax → ETA receipts → Accepted today** counts every receipt; nothing Blocked, Rejected or Send failed
  is left; the day summary (`GET /api/fiscal/day-summary`) says `all_accepted: true`.
- Run `node scripts/db-reconcile.mjs` against the **staging** database only if it is a local copy;
  otherwise use the scheduled `ledger.reconcile` job's log (it must say every cached balance matches).
- Turn the test devices off (**Settings → POS devices → Turn off**) if the client won't keep them.
- Record each step PASS/FAIL with a photo of the paper receipt (g) and the portal screenshots (f, h).
