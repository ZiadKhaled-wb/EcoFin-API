# O02 task report

Task: O02 — employees (EC-41, EC-143 part 2)
Status: done; verified before committing.
Branch: feat/shop in both repos. No push.

## Changes

- Migration adds atomic staff creation/editing/activation/invite/reset functions, role/override escalation checks, owner/self protections, identifier locking, pending-invite revocation, active branch validation, user-limit enforcement through P05, and scoped staff listing. Password reset hashes live in a service-only RLS table with 24 h expiry and single use. P01 acceptance rejects inactive/archived employees; lookup adds the display login.
- Six staff endpoints use the caller JWT and employee.manage. Two rate-limited pre-session reset endpoints use a fresh service-role client. Reset consumption happens before auth password update; update failure spends the token and returns RESET_FAILED. Real email receives bilingual mail with Cairo expiry; username-only staff receive a one-time fragment link. Tokens/provider errors are never logged.
- Contracts 0.8.0 add staff/reset schemas and codes. BRANCH_REQUIRED is 400 as requested. Audit registry, cross-shop cases, generated types and generic SQL denial/security coverage include O02. The reset table's no-policy catalog exception is explicit and tested; ordinary app table access is denied.
- Web adds a permission-gated Settings → Employees screen, role/status/search filters, server pagination, role defaults and grouped permission choices, edit drawer using the existing F06 setters, activation reasons, invite/reset delivery and a transient copy/WhatsApp dialog. Public password/set and invite acceptance display the login, clear fragments before requests, and prefill username plus shop context after success. Arabic and English strings cover every new label.

## Decisions

Decision 1: **Case A**. F04 resolves the linked auth account's email for username login. Username-only invites use `<username>@<organization UUID>.ecofin.invalid`, while employees.email remains NULL. No F04 change is required.

Existing F06 grant-limits functions already prevent both permission and branch escalation, so neither needed replacement. Their existing FORBIDDEN responses remain; new staff role/override checks return PERMISSION_ESCALATION.

## Verification

| Check | Result |
|---|---|
| API typecheck / lint | Passed |
| API unit suite without integration | 535 passed; integration cases skipped as designed |
| Full API with local integration | 663 passed + 1 existing expected failure; 664 cases in 55 files |
| Integration subset of full API | 128 passed + 1 existing expected failure |
| Shared contracts | 126 passed |
| Every SQL file after fresh db reset | 649 passed, 0 failed; O02 55 passed |
| Web typecheck / lint | Passed; existing DataTable TanStack compiler warning only |
| Web full suite | 183 passed in 30 files |
| Playwright | Real AR/EN create, edit, resend, deactivate/reactivate, permission grant, invite accept, reset and username login passed; AR mobile staff view has no document overflow |
| Security diff review | Passed: authenticated tenant context, foreign-id refusals, permission/audit checks, locked token consumption, empty SQL search paths, explicit grants, no app access to reset tokens, no raw token persistence/logging, no baseline migration edits or new dependencies |

EC-143 part 2 is proven: PUT /api/employees/:employeeId/active makes the employee's same live token return ACCOUNT_DISABLED immediately. Grant/revoke through F06 changes the same token's permission result on the next request.

Full integration ran sequentially to avoid the previously observed F13 fixture-count race. No assertion was weakened. The existing F14 direct-RPC linked-entity ownership defect remains recorded by its existing expected-failure test; no O02 work is outstanding.

Browser screenshots were inspected without capturing token/link dialogs. Verification also corrected duplicate pagination and the pending badge for an unlinked employee whose invitation was revoked. Local API/Web task processes and Supabase were stopped after verification. NTFS worktrees were used for npm; original feat/shop branches are fast-forwarded to the commits. CLAUDE.md was not changed; the original preexisting local edit is preserved. No remote database, deployment or push.

## Changed files in this repo
- DECISIONS.md
- docs/testing/TEST_PLAN.md
- package-lock.json
- package.json
- packages/contracts/CHANGELOG.md
- packages/contracts/package.json
- packages/contracts/src/errors.ts
- packages/contracts/src/index.ts
- packages/contracts/src/shops.ts
- scripts/db-types.mjs
- src/lib/mailer.ts
- src/routes/audit.integration.test.ts
- src/routes/auth.ts
- src/routes/employees.ts
- src/services/invites.service.test.ts
- src/test/audit-registry/registry.ts
- src/test/cross-shop/cases.ts
- src/test/cross-shop/check.test.ts
- src/test/cross-shop/harness.ts
- src/types/database.types.ts
- src/utils/supabase.ts
- supabase/tests/security_guards_test.sql
- supabase/tests/tenant_and_permission_test.sql
- docs/testing/plans/O02.md
- docs/testing/reports/O02_report.md
- packages/contracts/src/employees.test.ts
- packages/contracts/src/employees.ts
- src/controllers/staff.controller.ts
- src/routes/staff.integration.test.ts
- src/services/passwordResets.service.ts
- src/services/staff.service.test.ts
- src/services/staff.service.ts
- supabase/migrations/20261006110400_o02_employees.sql
- supabase/tests/o02_employees_test.sql
