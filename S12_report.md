# S12: warranty (EC-79)

Status: done. Parent S07 commit: 15fa2bd.

## Result

Implemented warranty dates/backfill, independent branch-scoped lookup, claims, validated transitions, out-of-warranty manager decisions, replacement chains, ledger postings, audited notes, scoped claim photos and shared contracts 0.36.0. Serialized repairs change customer-owned unit status without changing shop stock; replacements use F10 ledger rows and a warranty-specific unit-status trigger.

Approved overrides: normalize dates supplied by S03 for new sales; use warranty.manage for warranty_claim photos only, preserving other file permissions.

## Changed files

- DECISIONS.md
- S12_report.md
- docs/testing/TEST_PLAN.md
- docs/testing/plans/S12.md
- package-lock.json
- package.json
- packages/contracts/CHANGELOG.md
- packages/contracts/package.json
- packages/contracts/src/errors.ts
- packages/contracts/src/index.ts
- packages/contracts/src/warranty.test.ts
- packages/contracts/src/warranty.ts
- src/app.ts
- src/controllers/warranty.controller.ts
- src/routes/audit.integration.test.ts
- src/routes/warranty.integration.test.ts
- src/routes/warranty.ts
- src/services/files.rules.ts
- src/services/files.service.test.ts
- src/services/files.service.ts
- src/services/warranty.service.test.ts
- src/services/warranty.service.ts
- src/test/audit-registry/registry.ts
- src/test/cross-shop/cases.ts
- src/test/cross-shop/check.test.ts
- src/types/database.types.ts
- supabase/migrations/20261013010000_s12_warranty.sql
- supabase/tests/ledger_invariants_test.sql
- supabase/tests/s01_sale_core_test.sql
- supabase/tests/s12_warranty_test.sql
- supabase/tests/tenant_and_permission_test.sql

## Verification

- API typecheck, lint and formatting: passed.
- API unit: 703 passed; contracts: 294 passed.
- Full API run with RUN_INTEGRATION=1: 1,093 passed, including 390 integration tests; contracts: 294 passed.
- Clean isolated database reset and every SQL test: 2,700 passed, zero failures; S12: 71.
- Web typecheck, lint and formatting: passed; existing DataTable compiler warning only.
- Full Web suite: 568 passed across 72 files, run sequentially on exFAT.
- Real Chrome: EN/LTR and AR/RTL lookup, claim photo upload, A-B-C replacements, lookup of replacement serials, original warranty retention, receipt fields and corrected print portal; Arabic 390px overflow check passed. Print receipt width verified at 80 mm. Screenshots are ignored local artifacts under Web/test-results/s12.

## Scope and preservation

S12 adds to S07 on feat/s07-s12-history-warranty. Sale-create functions/routes and existing non-NULL warranty dates remain unchanged. The S01 date assertion was updated to the approved inclusive end for newly created sales, retaining an exact date check. R01 customer-photo uploads retain customer.create; the copied register_file body was compared with the current R01 implementation, with only warranty additions removed for that comparison.

Only local Supabase was used. The isolated ecofin-api-s07-s12 stack stayed running between tasks and was stopped after all final checks; the other development stack was untouched. No dependencies were added beyond the required contracts minor bump. CLAUDE.md was preserved. Nothing was pushed.

## Anything not done

No required S12 work remains. Refund is the specified 409 placeholder until S05 and is hidden in the UI; delivery-date integration waits for S10, as instructed.
