# P01 task report

Task: P01 (shop provisioning, EC-34)
Status: done
Branch: feat/shop; one commit per task, no push.

## Changes

Atomic provisioning and platform shop list/status/resend functions; hash-only generic invitation lookup/accept; caller-JWT super-admin middleware; bilingual SMTP mail; pre-session account creation or existing-password verification; suspended-shop auth guard; shared contracts 0.5.0; admin and public invitation Web flows.

## Checks

- API typecheck and lint: passed.
- Complete local API suite: 570 passed, one existing expected failure; all 79 integration cases enabled. New P01 integration suite: 10 passed.
- Contracts: 113 passed.
- Every SQL file after local database reset: 499 passed, zero failures; P01: 48 passed.
- Web: typecheck and lint passed (one existing TanStack compiler warning), 147 tests passed with two workers. An initial sample-page timeout resolved on rerun without changing tests.
- Playwright: real platform login, Arabic RTL and English LTR shop list/create; create sent Mailpit email; invitation rendered in both languages, URL fragment cleared, owner accepted and reached login with email prefilled and Arabic success notice. No horizontal overflow observed.
- Security diff review: caller JWT on platform routes; no tenant header accepted there; explicit SQL grants/search_path; token never in application response/log/persistent storage; audit target and actor verified; no ledger/balance writes; baseline unchanged.

## Provisioned rows

Organization, org_settings, disabled eta_settings, MAIN branch, main safe, installment policy v1 (12 months, zero markup), unlinked OWNER, one open invite, org.provisioned audit. No further mandatory per-shop seed rows. Derived balances and counters remain owned by existing triggers/functions.

## Implementation notes

- Original workspace drive is exFAT. Installed and checked in NTFS temporary Git worktrees, then fast-forwarded the original feat/shop branches to each task commit. User's existing CLAUDE.md edit excluded.
- Web vendors the locally built shared contracts tarball for reproducible npm ci without registry publication.
- SQL runner strips an existing Windows UTF-8 BOM. Type-generation script preserves F14's existing nullable RPC arguments, which PostgreSQL introspection cannot infer. Platform-denial coverage added to the generic SQL suite.
- Existing expected F14 defect remains: direct register_file RPC does not enforce linked entity ownership; API already enforces it. It predates P01, is recorded by existing expected-failure tests, and this task leaves old migrations unchanged.
- No remote database, deployment, publish or push. Local Supabase stopped after verification.

Done-when: usable new shop, expiring/single-use invitations, platform authorization, suspension/reactivation, existing account joins second shop, required UI and audit coverage: passed.

## Changed files

See the commit diff; the file inventory is appended below.

- .env.example
- DECISIONS.md
- docs/testing/plans/P01.md
- docs/testing/reports/P01_report.md
- docs/testing/TEST_PLAN.md
- package.json
- package-lock.json
- packages/contracts/CHANGELOG.md
- packages/contracts/package.json
- packages/contracts/src/auth.ts
- packages/contracts/src/errors.ts
- packages/contracts/src/index.ts
- packages/contracts/src/shops.test.ts
- packages/contracts/src/shops.ts
- scripts/db-smoke.mjs
- scripts/db-types.mjs
- src/app.ts
- src/controllers/admin.controller.ts
- src/controllers/invites.controller.ts
- src/lib/mailer.ts
- src/middleware/requestContext.test.ts
- src/middleware/requestContext.ts
- src/middleware/superAdmin.test.ts
- src/middleware/superAdmin.ts
- src/routes/admin.integration.test.ts
- src/routes/admin.ts
- src/routes/audit.integration.test.ts
- src/routes/auth.test.ts
- src/routes/auth.ts
- src/services/admin.service.test.ts
- src/services/admin.service.ts
- src/services/auth.service.test.ts
- src/services/auth.service.ts
- src/services/invites.service.test.ts
- src/services/invites.service.ts
- src/test/audit-registry/registry.ts
- src/test/cross-shop/check.test.ts
- src/test/cross-shop/harness.ts
- src/test/inviteMail.ts
- src/types/database.types.ts
- src/utils/env.test.ts
- src/utils/env.ts
- src/utils/inviteToken.test.ts
- src/utils/inviteToken.ts
- src/utils/supabase.ts
- supabase/config.toml
- supabase/migrations/20261006110100_p01_shop_provisioning.sql
- supabase/tests/f04_auth_test.sql
- supabase/tests/f05_tenant_test.sql
- supabase/tests/p01_provisioning_test.sql
- supabase/tests/security_guards_test.sql
- supabase/tests/tenant_and_permission_test.sql
