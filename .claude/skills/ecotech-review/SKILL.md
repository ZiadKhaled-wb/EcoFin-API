---
name: ecotech-review
description: Use when reviewing an EcoTech Pro task or pull request built by another agent, before it is merged. Checks it against its slice, the project rules and the tests.
---

# EcoTech Pro — reviewing a task

You are the gate before merge. Be strict, short and evidence-based. Don't rewrite the work; report what must change.

## Steps

0. If you haven't done it this session, run `AGENT_SETUP.md`. Stop if a mandatory item is missing.
1. Read the task file and its slice in `docs/EcoTech_Pro_Slices.md` (only that slice + "Rules that apply to every slice").
2. Read the diff only. Check callers and impact with `graphify-out/GRAPH_REPORT.md` / the graphify CLI / search, not by reading whole folders. Verify library usage with Context7 when unsure.
3. Check the builder's setup report. If they worked without `STATUS: READY`, the verdict is REJECT.
4. Run `typecheck`, `lint`, `test` yourself. Don't trust the builder's summary. Client tasks: walk the flow with Playwright.
5. Check every item below. Each failure needs file + line.

## Checklist

**Scope**
- [ ] Only the files the task allowed were changed
- [ ] Every "Done when" item has a test, and the test really checks it (not a placeholder)

**Rules** (the 13 rules in the `ecotech-build` skill), focus on:
- [ ] `organization_id` never taken from the request; foreign ids checked for same org
- [ ] Money uses decimal helpers; no float maths
- [ ] Stock/cash only through ledger inserts; one DB transaction; idempotency key respected
- [ ] No editing/deleting issued documents
- [ ] Types come from the shared contracts; no local duplicates
- [ ] Permission check on every new endpoint; audit entry on every write
- [ ] New migration file only; old migrations untouched
- [ ] No hard-coded UI text; works RTL and LTR

**Quality**
- [ ] No `any`, `@ts-ignore`, disabled lint rules, skipped tests
- [ ] No new dependency unless allowed
- [ ] Errors return contract error codes, not raw DB messages
- [ ] Cross-tenant test exists for every new endpoint

## Verdict format

```
Task: <task id> (<slice id>)
Verdict: APPROVE | CHANGES REQUIRED | REJECT
Checks run: typecheck ✅/❌  lint ✅/❌  test ✅/❌
Blocking issues:
  1. <issue> — <file:line> — <what to change>
Non-blocking notes: <list or "none">
Slice status after merge: DONE | NEEDS EDITS (<what's left>)
```

REJECT only when the approach is wrong (e.g. updates balances directly, wrong architecture). Otherwise CHANGES REQUIRED with a precise list, so the builder can fix it in one pass.
