# ADR-0004 — Authentication, tenancy, and the principal model

**Status:** Accepted
**Date:** 2026-09-30
**Supersedes:** The pre-refactor auth module (see git history for the
files replaced by this ADR's implementation).

## Context

EcoFin Pro is a multi-tenant SaaS ERP. The pre-launch auth module worked
but had structural flaws that would cause security incidents with the
first paying tenant:

- Tenant context was inferred from `license_key` on every login, so a
  leaked key was a permanent cross-tenant skeleton key.
- The Supabase service-role client was used for tenant CRUD, so RLS was
  never actually tested in production code paths.
- `activateWorkspace` performed three sequential writes with a hand-rolled
  rollback. A failure on the last write left the system in an
  inconsistent state that nothing recorded.
- `checkLicense` returned the owner's email to any caller holding a
  license key, which enabled email enumeration.
- `resetOwnerPassword` had no caller authentication at all.

The schema is being rebuilt in parallel. This ADR documents the auth
model the new schema must serve, and the decisions made while hardening
the module.

## Decision

### D1. Tenant resolution via `tenant_slug`, not `license_key`

Every request that needs a tenant context resolves it from the JWT
(the `sub` claim) against the `employees` table, or — for the login
endpoint only — from a `tenant_slug` supplied in the request body. The
`license_key` is a one-time activation credential and is not accepted on
any authenticated endpoint.

**Why:** A `tenant_slug` is public, non-secret, and revocable by changing
it. A `license_key` is a bearer secret, and any system that accepts it
repeatedly multiplies the blast radius of a leak. Once activation flips
`is_used = true`, the key is dead weight.

**Alternatives considered:** embedding `org` into the JWT via a Supabase
claim hook. Rejected for v1 because the hook isn't in the schema yet, and
the per-request `employees` read is a single indexed lookup on a table we
already have to read for role/permissions.

### D2. Three Supabase clients with non-overlapping responsibilities

`supabaseAnon`, `supabaseUser(jwt)`, `supabaseAdmin`. Every tenant CRUD
read after authentication goes through `supabaseUser(jwt)` so RLS is the
actual enforcement mechanism, not a theoretical one.

**Why:** the pre-refactor code used `supabaseAdmin` everywhere, which
meant RLS policies were never exercised. If a policy was wrong, we'd only
find out in production. Now a policy mistake surfaces as a failing query
in the environment where it's cheap to fix.

**Consequence:** if you find yourself reaching for `supabaseAdmin` inside
a tenant handler, the correct move is to fix the RLS policy, not to
escalate.

### D3. `activateWorkspace` ordering: password first, DB second

The Supabase Auth password update is a network call against a service we
don't control. The DB writes are a single Postgres transaction. The order
is: update password, then call the atomic RPC.

**Why:** if the password update fails, no state has changed — the user
retries. If the DB transaction fails after the password update succeeded,
the user's Auth password is set but the license is still `is_used = false`;
retrying activation is safe. The reverse order (license first, password
second) leaves a used license with no working login on any failure of the
second call — the exact failure mode the old code shipped.

**Alternative considered:** `TransactionTracker`-style manual rollback.
Rejected: it's fragile, untested, and duplicates what Postgres already
does correctly inside a `BEGIN ... COMMIT`.

### D4. Postgres RPC for the atomic activation transaction

`public.activate_workspace(p_license_key, p_owner_auth_id, p_username)`
performs `SELECT ... FOR UPDATE` on the license, re-validates it,
flips `is_used`, sets the username, and returns the tenant identity — all
in one transaction. The service layer never checks-then-writes.

**Why:** check-then-write in TypeScript is a TOCTOU race. Two concurrent
activation requests against the same license would both pass the
pre-flight check and both proceed. The lock inside the function
serializes them; the second gets `LICENSE_USED` and is rejected.

### D5. `must_change_password` is a server-enforced gate

A user with `must_change_password = true` can reach exactly two
endpoints: `POST /api/auth/change-password` and `POST /api/auth/logout`.
Every other authenticated route carries `requirePasswordChanged`.

**Why:** the old behavior was a client-side hint. A user with a temp
password could ignore it and use the app as if nothing was wrong. The
server now refuses.

### D6. Principal is either an employee or a super admin — never both

`super_admins` lives in its own table keyed by `auth_user_id`. There is
no `SUPER_ADMIN` role on `employees`. The middleware `attachEmployee`
loads a tenant employee if one exists; `attachSuperAdmin` loads a platform
super admin if one exists. Routes pick one or the other.

**Why:** the two have different trust boundaries. Super admins operate
platform-wide; employees are scoped to one tenant. Modeling them as the
same row means every tenant query has to be re-audited for whether it
should allow a super admin.

### D7. `checkLicense` does not return `owner_email`

**Why:** the license key is designed to be shared (a sales agent hands it
to a customer). Returning the registered owner's email to anyone with the
key leaks which email a business's owner uses. The activation form lets
the user type their own email; `activateWorkspace` rejects on mismatch.

**Trade-off:** the activation page can no longer show "we sent this to
a***@example.com". If we need that UX, the fix is to send a verification
email — not to leak the address.

### D8. Generic credentials error for every login failure mode

`login` returns `Unauthorized('بيانات الدخول غير صحيحة.', 'INVALID_CREDENTIALS')`
for: unknown slug, suspended org, unknown username, unknown email, wrong
password, and "authenticated to Supabase but has no employee or
super-admin row".

**Exception:** a *correct password against a deactivated account* returns
`ACCOUNT_DISABLED`. The password check has already succeeded, so there's
no enumeration risk in telling the user why they can't log in.

**Why:** every other distinction is an enumeration oracle.

### D9. Password policy is NIST-style, not composition rules

Minimum 8, maximum 128, small common-password blocklist, no character
class requirements, no trimming.

**Why:** the old regex rejected non-ASCII characters and spaces, which is
a real usability problem in an Arabic-first product, and provided no
security benefit that length doesn't already provide.

### D10. Rate limiting on every unauthenticated auth endpoint

`express-rate-limit` with keys of `IP|tenant_slug` where a slug is
present. In-memory by default, Redis if `RATE_LIMIT_REDIS_URL` is set.

**Why:** the login endpoint is the highest-value target in the system.
Supabase's Auth API has its own limits, but they're per-project — a
single-tenant credential-stuffing run would degrade service for every
tenant.

**Known limitation:** in-memory storage is per-process. Behind more than
one API instance, configure Redis.

## Consequences

- **Every service that later adds tenant-scoped CRUD must use
  `supabaseUser(jwt)`.** A code-review checklist item, and the comment
  at the top of `utils/supabase.ts` is the guardrail.
- **RLS policies are now load-bearing.** A wrong policy will fail a
  request. This is the point, but it means policy changes need real
  testing (see "Tests to write later" in the auth refactor PR notes).
- **Activation can be retried safely.** A P1 log line is emitted when the
  post-password RPC fails, so ops can catch it.
- **No session revocation.** Logout is client-side; a stolen access token
  is valid until it expires (~1 hour). Deferred to v1.1. See "Open
  questions" below.
- **Super admins log in through the same endpoint as tenant users** and
  must supply *some* valid `tenant_slug`. This is a wart. See Open
  Questions.

## Open questions

1. **Session revocation.** Stateless JWTs can't be revoked before expiry.
   Options for v1.1: (a) a `revoked_tokens` table with a TTL index,
   checked in `authenticate`; (b) shorter access tokens + refresh rotation
   with server-side invalidation on logout; (c) accept the ~1h window.
2. **Super-admin login entry point.** Should a super admin need a
   `tenant_slug` to log in? The current implementation requires one and
   treats it as informational. A cleaner model is a separate
   `/api/platform/login` endpoint with no slug. Deferred pending a
   decision on whether super admins get a distinct UI surface.
3. **Phone-based recovery.** `forgotPassword` assumes email is deliverable.
   Egyptian SMB owners may not have a working email on their account.
   An SMS provider is deferred to v1.1; the fallback in the meantime is
   the Super Admin reissuing a temp password.
4. **Trust proxy.** `req.ip` must be meaningful for rate limiting. The
   app must set `app.set('trust proxy', <hops>)`. If that's missing, all
   traffic is keyed on the load balancer's IP and the rate limiter
   collapses into a global limiter. Add this to the app bootstrap.

## Alternatives considered (summary)

| Decision | Rejected alternative | Why |
|---|---|---|
| Slug-based tenancy | JWT `org` claim | Needs a claim hook that isn't in the schema yet |
| `supabaseUser(jwt)` for tenant reads | Keep `supabaseAdmin` everywhere | Leaves RLS as untested theory |
| RPC for atomic activation | `TransactionTracker` manual rollback | Fragile, untested, duplicates Postgres |
| Password-first ordering in activation | License-first ordering | Failure mode is unrecoverable |
| NIST password policy | Composition regex | Rejects legitimate passwords, no security benefit |
| No `owner_email` in `checkLicense` | Masked email | Even masked, it's an enumeration hint |