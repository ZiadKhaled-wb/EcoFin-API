# CI formatting fix

Date: 2026-10-06
Status: done

## Changes

Applied repository Prettier rules to the five files reported by the full formatting gate:

- src/lib/mailer.ts
- src/middleware/modules.test.ts
- src/routes/branches.integration.test.ts
- src/routes/subscription.integration.test.ts
- src/routes/subscription.test.ts

Only layout and spacing changed. Syntax tree comparison confirms no TypeScript syntax changes. No tests, assertions, workflow settings or runtime behavior were changed. CLAUDE.md remains untouched, including its preexisting local edit.

## Checks

- Full npm run format:check: passed.
- Typecheck: passed.
- Lint: passed.
- npm test: 535 API unit tests and 126 contract tests passed. The 130 integration cases were not run for this formatting-only change.
- Diff and security review: formatting only. Browser check: not applicable.

Committed locally; no push.
