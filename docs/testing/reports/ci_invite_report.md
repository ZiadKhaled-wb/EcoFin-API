# CI invitation integration fix

Date: 2026-10-06
Status: done

## Root cause and reproduction

The integration workflow exported Supabase credentials and FRONTEND_URL but omitted SMTP_URL and MAIL_FROM. Application invitations/reset emails use Nodemailer. With no SMTP_URL, sendInviteEmail returns false without sending mail. Mailpit polling cannot recover an unsent message.

Reproduced on a fresh local stack with the original CI environment: the first admin provisioning test failed because invite_email_sent was false. Later tests reuse its token, organization and owner session, so incomplete setup explains the reported 400/401 failures.

## Changes

- .github/workflows/ci.yml exports local SMTP_URL, a test sender and the Mailpit URL from CLI status before npm test.
- vitest.config.ts runs files sequentially only when RUN_INTEGRATION=1. Shared database fixtures otherwise race the global daily-job assertions as provisioning creates shops. Unit runs remain parallel; in-test concurrency proofs and module isolation remain enabled.
- docs/testing/TEST_PLAN.md documents the required mail environment and integration execution.

The existing tests already cover invitation email delivery, used/expired 410 responses, authenticated non-admin 403 SUPER_ADMIN_REQUIRED, suspension and reactivation. No status mappings, handlers, assertions, skips or timeout settings changed. No dependency or database migration added. CLAUDE.md was untouched.

## Verification

- Missing-SMTP reproduction: failed at invite_email_sent, as expected.
- Fresh local database reset: passed.
- RUN_INTEGRATION=1 CI=true npm test with the corrected workflow environment: all 665 API tests passed (55 files; all 130 integration cases enabled), and all 126 contracts tests passed.
- The P01 route tests verified used/expired invite 410, non-super-admin owner 403, and successful suspension/reactivation without any runtime patch.
- Typecheck, lint, full format check, build and all three route registry gates passed.
- Integration workflow Bash syntax check passed.
- Security review: only local test mail configuration and test execution scheduling changed; permissions, tenant isolation and raw token handling remain intact.
- UI check: not applicable.

These checks ran locally with CI=true; GitHub CI can rerun after the user pushes. Commit only; no push.
