---
name: ecotech-build
description: Use when implementing, porting or fixing any EcoTech Pro task or slice (server or client). Gives the project rules, how to find code cheaply, the task workflow and the definition of done.
---

# EcoTech Pro — building a task

EcoTech Pro is a multi-tenant SaaS POS with in-house installments for Egyptian furniture and electronics shops. Two repos: **server** (Express + TypeScript + Postgres on Supabase) and **client** (React + TypeScript). One shared contracts package.

## 0. Setup

If you haven't done it this session, run `AGENT_SETUP.md` (repo root). If a mandatory item is missing, stop and report it.

## 1. Before you write anything

**First:** if the slice is Port or Rewrite, read its section in `docs/OLD_CODE_MAP.md` and only the old files it lists.

1. Read **only** your task file. It names the slice ID, the files you may touch, and the "Done when" checks.
2. Open the slice in `docs/EcoTech_Pro_Slices.md` (search for its ID, e.g. `### S01`). Read only that slice plus the "Rules that apply to every slice" section.
   If the task touches the database: read only the tables it names in `docs/EcoTech_Pro_Data_Model.md`, plus §1 (conventions), §2 (access model) and §12 (baseline refinements). The real schema is `supabase/migrations/20261002000000_v1_baseline.sql` (server repo): search it for the table, don't read it all. If the doc and the SQL differ, the SQL wins. Never add or rename a table, column or enum that isn't there. If you need one, stop and ask.
3. Find code cheaply: read `graphify-out/GRAPH_REPORT.md` first; use `graphify query/explain/path` if you have the CLI; then search for the exact symbol. Open only the files you need.
4. Before using any library API, look it up with **Context7**. Don't code library APIs from memory.
5. If the task is unclear or conflicts with the slices doc: **stop and ask**. Never guess a business rule.

## 2. Rules you must never break

1. **Tenant:** `organization_id` comes from the authenticated request only. Never read it from the body, query or params. Every query is scoped by it. Every foreign id in a request is checked to belong to the same organization.
2. **Money:** use the shared decimal helpers. Never use JS `number` arithmetic for money. DB money columns are `numeric(18,2)`.
3. **Stock and cash** change only by inserting ledger entries (stock movement / cash movement). Never `UPDATE` a balance directly.
4. **Transactions:** a write that touches more than one table runs in one DB transaction. No "undo" code.
5. **Idempotency:** every money or stock write accepts an idempotency key. The same key twice changes things once.
6. **Issued documents are never edited or deleted.** Corrections are linked reversals.
7. **Contracts:** request and response shapes come from the shared contracts package. Don't define API types locally. Don't change a contract unless your task says so.
8. **Permissions:** every endpoint checks a permission key from the shared list. The client hides what the user can't do, but the server is the real check.
9. **Audit:** every write that matters writes an audit entry in the same transaction.
10. **Schema** changes only through a new migration file in `supabase/migrations/`. Never edit an old migration (the baseline included). Never touch a real database.
11. **Database writes** go through a `SECURITY DEFINER` function in a new migration (`SET search_path = ''`), called with the user's JWT. The API never writes tables directly. Each function:
    - starts with `v_emp := app.require_permission('<key>')`; org and employee come from the session (`app.current_org_id()`), never from parameters; checks `app.require_branch_access(branch)` for branch data;
    - takes the document number from `app.next_document_number(org, branch, '<doc_type>')` and stores the caller's `idempotency_key` (on a repeat key, return the existing document);
    - locks the rows it changes; posts multi-line documents in `product_id` order; releases or fulfils a reservation **before** posting its stock movement;
    - never writes `stock_levels`, `cash_balances`, `store_credit_balances` or a unit's status/branch (triggers own them);
    - calls `app.write_audit(...)` once; ends with `GRANT EXECUTE ON FUNCTION ... TO authenticated` (nothing is granted by default);
    - maps trigger errors (`OUT_OF_STOCK`, `INSUFFICIENT_FUNDS`, `DAY_CLOSED`, `PERMISSION_DENIED`, …) to contract error codes in the API.
    Its test must cover: no permission, other shop's ids, repeat idempotency key, and the "Done when" cases.
12. **i18n:** no hard-coded UI text. Every string goes in the Arabic and English files. Layout must work RTL and LTR.
13. **Errors:** business errors return 4xx with an error code from the contracts. Never return raw DB messages.
14. Stay inside the files your task lists. Need another file? Say so in your summary; don't edit it.

## 3. Workflow

1. Write or update the tests from the task's "Done when" list **first**.
2. Implement the smallest change that makes them pass.
3. Run, in this order: `typecheck`, `lint`, `test`. All must pass. (Exact commands: see the repo's AGENTS.md.)
4. UI changes: check the page with **Playwright** in Arabic (RTL) and English.
5. Security check of your diff: **security-guidance** (Codex) or the security checklist in `ecotech-review` (other agents).
6. Write the summary below. Don't rebuild or commit `graphify-out/`.

## 4. Summary you must return

```
Task: <task id> (<slice id>)
Status: done | blocked
Changed files: <list>
Tests added: <list>
Checks: typecheck ✅/❌  lint ✅/❌  test ✅/❌  security ✅/❌  UI check ✅/❌/n.a.
Done-when checklist: <each item ✅/❌>
Assumptions or questions: <list or "none">
```

## 5. Forbidden

- Adding a dependency without the task allowing it
- Disabling a lint rule, `@ts-ignore`, `any`, or skipping a test to make checks pass
- Changing files outside the task scope "while you're there"
- Inventing endpoints, fields or business rules not in the task or slice
