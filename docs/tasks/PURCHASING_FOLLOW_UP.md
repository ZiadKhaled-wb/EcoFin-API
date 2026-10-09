# Following the free agent on U01–U06 (owner's guide)

This guide is for **you**, not the agent. It covers:
- which ticket to give the agent, and when;
- what to say to it;
- how to check its work yourself in a few minutes;
- the release steps only you do.

The agent gets two files per ticket: `PURCHASING_RULES.md` and its `U0x.md`.

---

## 1. Order and dependencies

| # | Ticket | Spec | Needs merged first | Contracts | Decision | Routes after |
|---|---|---|---|---|---|---|
| 1 | EC-53 U01 Suppliers | `U01.md` | I06 (done) | 0.21.0 | D53 | 104 |
| 2 | EC-54 U02 Purchase invoices | `U02.md` | U01 | 0.22.0 | D54 | 110 |
| 3 | EC-58 U06 Approval by amount | `U06.md` | U02 | 0.23.0 | D55 | 111 |
| 4 | EC-57 U05 Purchase orders | `U05.md` | U02, U06 | 0.24.0 | D56 | 118 |
| 5 | EC-56 U04 Purchase returns | `U04.md` | U02 (U05/U06 for the numbers) | 0.25.0 | D57 | 123 |
| 6 | EC-55 U03 Supplier payments | `U03.md` | U02, U04 | 0.26.0 | D58 | 128 |

- **One ticket at a time.** Each spec says "starts after X is merged". Don't run two in parallel: they edit the same files (contracts, registries, `approve_purchase_invoice`).
- **K01 (vaults, EC-59)** isn't in this pack. U03 works without it, but a shop can't really pay suppliers until money can enter a vault. Do K01 before you release U03 to real users; ask me for a K01 spec.
- If the agent's numbers differ from the table (for example a hotfix took 0.21.0), that's fine, as long as it says so in its summary.

### Decisions already in the specs
**Yours (8 Oct):**
- Purchase prices are entered before VAT; the average cost excludes VAT.
- Above the approval threshold, the owner only.
- No over-receipt on purchase orders.
- Returns recompute the average cost.
- Per-branch min levels and the PO button from low stock (I06, D52, carried into U05).

**My defaults, written into the specs** (read them; if you disagree, edit the spec **before** you hand it over):

| Spec | Default | Where |
|---|---|---|
| U01 | Supplier names and phones are unique among active suppliers | Decision 1 |
| U01 | A supplier can't be deactivated with a balance or open documents | Decision 2 |
| U01 | Warehouse and accountant can read suppliers and statements; a cashier can't | Decision 3 |
| U01 | The statement is shop-wide (all branches) | Decision 4 |
| U02 | Only drafts can be edited; supplier and branch are fixed after creation | Decision 4 |
| U02 | The creator may approve their own invoice (if they hold `purchase.invoice_approve`) | Decisions 4 and 6 |
| U04 | Credit returns may push the supplier balance below 0 (supplier owes the shop) | Decision 2 |
| U04 | Returns go out of the invoice's branch only | Decision 3 |
| U03 | Every payment is fully allocated to invoices; nothing paid "on account" | Decision 1 |
| U03 | Only the owner reverses a payment | Decision 6 |

---

## 2. Before each ticket (5 minutes, you)
1. In Jira, move the ticket to **In Progress**.
2. Make sure the previous ticket is **merged, tagged and deployed** (section 7).
3. In VS Code, open a terminal in each repo and bring it up to date:
   ```powershell
   git checkout main
   git pull
   git status
   ```
   `git status` must be clean. If not, stop and find out whose files they are; never let the agent sweep them in.
4. Start Docker Desktop. Then, in the API folder:
   ```powershell
   npx -y supabase@2.119.0 start
   ```
   It should end listing the API URL (`http://127.0.0.1:54321`).
5. In the agent, check that the **context7** tools are connected. If not, use `/mcp` → Reconnect.

---

## 3. What to say to the agent

### Run 1: Part A (API and contracts)
```
You are building <U0x> for EcoFin. Work in "D:\EcoFin Version 1\EcoFin API" (and only read EcoFin Web).
Read, in order: AGENT_SETUP.md, AGENTS.md, .claude/skills/ecotech-build/SKILL.md,
docs/tasks/PURCHASING_RULES.md, docs/tasks/<U0x>.md, and the DECISIONS.md entries the task names.
Do Part A only (migration, SQL test, guard suites, contracts, API, registries, docs).
First print the setup report and your plan (every function, route, schema and test file with its path), then wait for my "go".
Rules: stage named files only; never git add a folder; never push, merge, tag or publish; never touch a remote database.
When done, return the summary with the evidence block from PURCHASING_RULES.md section 6 — real command output, not a description.
```

### Run 2: Part B (Web), after you have checked Part A (section 4)
```
Part A of <U0x> is done on branch feat/<...> in EcoFin API. Now do Part B only, in "D:\EcoFin Version 1\EcoFin Web",
following docs/tasks/<U0x>.md in the API repo and PURCHASING_RULES.md. Use the contracts by copying
EcoFin API/packages/contracts/dist and package.json into node_modules/@ziadkhaled-wb/contracts (local only).
Print your plan first and wait for "go". Return the summary with the Web part of the evidence block.
```

### What to look for in its plan (before you say "go")
- [ ] The migration name has a timestamp **later** than the newest file in `supabase/migrations`.
- [ ] Every function in the spec's Part A appears, with the same name.
- [ ] The test file name `supabase/tests/u0x_..._test.sql` is listed.
- [ ] The plan names the **guard suites** (`tenant_and_permission`, `security_guards`, and `ledger_invariants` when there's an idempotency key) and the **registries** (cross-shop, audit).
- [ ] The contracts version is bumped in **two** places: `package.json` and `CONTRACTS_VERSION`.
- [ ] Only files from "Files you may touch".
- If something is missing, reply: *"Your plan misses X from section Y of the spec. Add it and show the plan again."*

---

## 4. Checking its work yourself (don't trust the summary; run these)
Open a PowerShell terminal in **EcoFin API** on the agent's branch:
```powershell
git checkout feat/<u0x-name>
```

### 4.1 What changed (2 minutes)
```powershell
git diff --stat main...HEAD
```
- Every file must be in the spec's "Files you may touch".
- **Red flags:**
  - a change to `20261002000000_v1_baseline.sql` or any **old** migration;
  - `.env`;
  - `package-lock.json` with hundreds of lines changed (it should be 2–4 lines);
  - files of another ticket.

Next, look for shortcuts the agent took:
```powershell
git diff main...HEAD | Select-String -Pattern '\.skip\(|\.only\(|@ts-ignore|eslint-disable|: any\b|as any|TODO|FIXME|xit\(|it\.todo'
```
This should print nothing, or only things the agent explained.

Then check it didn't weaken old tests:
```powershell
git diff main...HEAD -- supabase/tests src packages/contracts/src | Select-String -Pattern '^-.*expect\(|^-.*t\.expect|^-.*t\.error'
```
Removed assertions must be explained (the spec allows only signature renames in U06/U05).

### 4.2 The database tests (5 minutes)
Apply the new migration locally:
```powershell
npx -y supabase@2.119.0 db reset
```
- This is local only. It erases your **local** test data and re-seeds the demo users.
- It must finish without `ERROR`. An error means the migration is broken: send the error text to the agent.

Run the ticket's own test:
```powershell
npm run -s db:smoke -- supabase/tests/u0x_<name>_test.sql
```
- The last line must be `passed N, failed 0`.
- Compare N with the agent's claim. Open the file and check that the "Done when" bullets of the spec each have a `t.expect` or `t.error` whose name says so. A lazy agent writes 10 easy checks and skips the hard ones (double approval, over-receipt, idempotency, another shop).

Run every SQL file:
```powershell
Get-ChildItem supabase/tests/*.sql | ForEach-Object { "$($_.Name): " + (npm run -s db:smoke -- $_.FullName 2>&1 | Select-Object -Last 1) }
```
Every line must say `failed 0`. The one allowed exception is `smoke_test.sql` with "stale job reclaimed" on your machine: CI is fine there.

### 4.3 The code checks (5 minutes)
```powershell
npm run typecheck; npm run lint; npm run format:check
npm run check:cross-shop; npm run check:permissions; npm run check:audit
node scripts/check-migration-order.mjs
npx vitest run
npm run test:contracts
```
- The `check:cross-shop` line must show the route count from the table in section 1 (e.g. "104 routes, all covered").
- `check:audit` must say "all registered".
- The contracts version must match in both places:
  ```powershell
  Select-String '"version"' packages/contracts/package.json
  Select-String 'CONTRACTS_VERSION' packages/contracts/src/index.ts
  ```

### 4.4 The Web (after Part B), in EcoFin Web on its branch
```powershell
npm run typecheck; npm run lint; npx prettier --check src
npx vitest run --maxWorkers=2
git diff --stat main...HEAD
```
- **Arabic and English parity:** `src/i18n/i18n.test.ts` fails if a key is missing in one language. Make sure it ran and passed.
- **Menu snapshot:**
  ```powershell
  git diff main...HEAD -- src/config/__snapshots__
  ```
  It should only **add** the new page's path, for the roles the spec names.

### 4.5 Click through it yourself (10 minutes)
Start the local stack from the Claude app's preview (configs `ecofin-api-local` and `ecofin-web-local`), or in two terminals:
```powershell
npm run dev    # in EcoFin API (port 3001)
npm run dev    # in EcoFin Web (port 5173)
```
Then open http://localhost:5173 and log in with the seed owner (owner.one@ecotech.test, with the seed password you use for local tests). Do the ticket's checklist in section 6, **once in Arabic and once in English** (language switch in the top bar).

---

## 5. Lazy-agent red flags and what to reply

| You see | Reply |
|---|---|
| "All tests pass", without the evidence block | "Paste the evidence block from PURCHASING_RULES.md §6 with the real command output." |
| A SQL test with only "happy path" checks | "Your SQL test misses these Done-when items from the spec: <list>. Add a t.expect/t.error for each and paste the passed/failed line." |
| `failed 0` claimed, but you see failures | "<file> fails on my machine: <paste>. Fix it; don't change the assertion." |
| A route without a cross-shop case, or a changed route count | "check:cross-shop must list <N> routes; add the missing cases for <routes>." |
| Contracts bumped in one place only | "Bump CONTRACTS_VERSION in packages/contracts/src/index.ts too, and the root package.json pin." |
| Hard-coded text in a `.tsx` | "Move every string into ar and en purchases/suppliers JSON; no text in components." |
| Inputs in a table lose focus while typing | "Use a plain <table> with a row component as in MinLevelsDialog.tsx; DataTable cells remount." |
| An id from the URL used without a check | "Validate it with Uuid.safeParse before calling the API (PURCHASING_RULES §3)." |
| It edited an old migration or the baseline | "Revert that file. Every change goes in your new migration." |
| It asks to "simplify" a rule from the spec | Only you decide. Say yes or no; never let it choose. |
| It stops with "blocked" | Good: it found a real gap. Read it, decide, and answer in one line. |

When Part A or B looks done, you can also ask **me** (Claude Code, smart) to review the branch:
> "Review feat/u0x-... in EcoFin API (and Web) with the ecotech-review skill against docs/tasks/U0x.md; run the checks and the SQL tests."

---

## 6. Click-through checklists (Arabic **and** English)

**U01 Suppliers** (`/suppliers`)
1. Add a supplier with phone `0100 123 4567` → it saves as `01001234567`.
2. Add a second one with the same name in other letter case → error on the name field.
3. Edit the payment terms → saved; the list shows "30 days".
4. Deactivate it (balance 0) → it disappears from Active and shows under Archived; restore it.
5. Open its statement → opening 0, no rows, closing 0.
6. Log in as a cashier (or an employee without purchasing keys) → no Suppliers menu, and the page is refused.

**U02 Purchase invoices** (`/purchasing/invoices`)
1. New invoice: supplier, branch, two products (one at 14% VAT, one exempt), costs → live totals match the line math.
2. Save the draft, edit a quantity, save again.
3. Approve → confirm → status Approved.
4. Check the results:
   - **Stock** page: both quantities went up **once**.
   - **Movement history** shows a PI number with a link back to the invoice.
   - The **Supplier statement** shows the invoice and the new balance (incl. VAT).
5. For a serialized product: approve without serials → it names the line; add the serials → approved; **Serial numbers** shows them with the supplier.
6. As a warehouse user: you can create, but there's no Approve button.

**U06 Approval by amount**
1. In Settings, set the purchase approval threshold to 10 000.
2. As a branch manager, approve a 12 000 invoice → message "sent to the owner"; stock unchanged.
3. Purchasing → Approvals shows it as waiting.
4. As the owner, approve it with a note → stock in; the note shows on the invoice.
5. Repeat with Reject → reason required → Rejected.

**U05 Purchase orders** (`/purchasing/orders`)
1. Order 10 + 5 → Send.
2. Receive 6 + 5 → a draft invoice opens; approve it → the order shows "Partially received", remaining 4.
3. Receive 5 → error naming 4 remaining.
4. Receive 4 → approve → Received.
5. Stock page → Low stock only, pick one branch → "Create purchase order" → the form is pre-filled.

**U04 Purchase returns** (from an approved invoice → Return goods)
1. Return 2 at supplier credit → the stock goes down by 2; the statement balance goes down.
2. Try to return more than is left → the error shows the returnable quantity.
3. Return 1 serial with a cash refund to the main safe → the unit shows "returned"; the safe balance (accounts list) goes up.

**U03 Supplier payments** (`/purchasing/payments`)
1. Put money in the safe first: until K01 exists, ask me to insert a local opening balance.
2. Pay part of an invoice → its outstanding drops; the statement shows the payment.
3. **Double-click Pay quickly** → one payment only (the list shows one number).
4. Pay more than the amount owed → error.
5. As the owner, reverse it with a reason → the balances come back.

---

## 7. The release steps only you do (every ticket)
1. **Push and open the PRs:** tell the agent "push your branch and open the PR", or do it yourself:
   ```powershell
   git push -u origin feat/<u0x-name>
   ```
   Then create the PR on GitHub. **API first.**
2. **Security review:** ask me: "run /security-review on feat/<u0x-name> in EcoFin API". Fix every finding before merging.
3. **API CI:** wait for **check, db, integration** to be green on the PR. Then **merge** (merge commit).
4. **Dev deploy:** in GitHub → EcoFin-API → Actions, "Deploy (development)" must be green for the merge commit. It runs the migration on the dev database. Check that https://20.56.139.170.sslip.io/health shows `"status":"ok"`.
5. **Publish the contracts** (API folder, on `main`):
   ```powershell
   git checkout main
   git pull
   Select-String '"version"' packages/contracts/package.json     # e.g. 0.21.0
   git tag contracts-v0.21.0
   git push origin contracts-v0.21.0
   ```
   The tag must equal that version. Wait for the "Publish contracts" action to go green.
6. **Web:** on the Web branch, in EcoFin Web:
   ```powershell
   npm install --save-exact @ziadkhaled-wb/contracts@0.21.0
   ```
   (`NPM_TOKEN` must be set in your user environment.) Commit `package.json` and `package-lock.json`, push, open the Web PR, wait for **CI** to go green, then merge.
7. **Web deploy:** in GitHub → EcoFin-Web → Actions, "Deploy (Vercel)" must be green. Then open https://eco-fin-web.vercel.app, log in, and see the new menu item.
8. **Jira:** add a comment (what shipped, PR numbers, contracts version, D-number, tests) and move the ticket to **Done**. I can write the comment for you if you paste the PR links.
9. **Clean up locally:**
   ```powershell
   git checkout main
   git pull
   ```
   Run this in both repos before the next ticket.

### If something goes wrong
- **CI red on a migration-order check:** the migration timestamp isn't the newest. Ask the agent to rename it to a later timestamp; never edit an older migration.
- **"Publish contracts" failed:** the tag doesn't match `packages/contracts/package.json`. Delete the tag on GitHub, fix the version through a PR, then tag again.
- **Vercel didn't deploy:** the commit was made by someone other than you (Hobby plan). Merge it yourself.
- **Docker Desktop won't start** (stale socket): quit Docker, rename `%LOCALAPPDATA%\Docker\run` to `run-stale-<date>`, and start it again. Never "Reset to factory defaults".
- **Anything you aren't sure about:** paste it to me with the ticket name.
