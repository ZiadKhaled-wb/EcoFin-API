# Authentication module — backend reference

**Audience:** Frontend developers integrating with the EcoFin Pro API.
**Server:** `http://localhost:3001` in development.
**Interactive playground:** `http://localhost:3001/docs` (Swagger UI).

This document tells you exactly what every auth endpoint expects, what it
returns, and — critically — which failure modes are *intentional* so you
don't accidentally code around them.

Read the "Frontend state machine" section first. It's the contract your UI
has to implement.

---

## 1. The frontend state machine

Auth is not a single flow — it's a small state machine. Your UI has to
track these states and route accordingly.

```
                    ┌─────────────────────────┐
                    │   No session            │
                    │   (unauthenticated)     │
                    └────────────┬────────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
      ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐
      │ Activation   │   │  Login       │   │ Forgot password  │
      │ (/activate)  │   │  (/login)    │   │ (/forgot)        │
      └──────┬───────┘   └──────┬───────┘   └──────┬───────────┘
             │                  │                  │
             ▼                  ▼                  ▼
      ┌──────────────────────────────┐    ┌──────────────┐
      │  Session + must_change_pw?   │    │ Email sent   │
      └──────────────┬───────────────┘    └──────────────┘
                     │
              ┌──────┴───────┐
         true │              │ false
              ▼              ▼
      ┌──────────────┐   ┌──────────────┐
      │ Force change │   │  App shell   │
      │ password     │   │  (dashboard) │
      │ (only        │   └──────────────┘
      │  /change-pw  │
      │  and /logout)│
      └──────┬───────┘
             │
             ▼
      ┌──────────────┐
      │  App shell   │
      └──────────────┘
```

### State transitions the UI must handle

| From state | Trigger | To state | UI action |
|---|---|---|---|
| No session | `/login` returns 200 with `must_change_password: true` | Must-change-password | Redirect to change-password screen. **Block every other route.** |
| No session | `/login` returns 200 with `must_change_password: false` | App shell | Store tokens, redirect to dashboard |
| No session | `/login` returns 403 `ACCOUNT_DISABLED` | No session | Show "account disabled" message. Do not retry. |
| Must-change-password | `/change-password` returns 200 | App shell | Replace tokens (re-login to get a fresh token without the flag in context) |
| Any authenticated | Any request returns 401 `UNAUTHORIZED` | No session | Clear tokens, redirect to login |
| Any authenticated | Any request returns 403 `MUST_CHANGE_PASSWORD` | Must-change-password | Redirect to change-password. **This is the server enforcing the gate — trust it.** |

**The most important rule:** when the server returns 403 `MUST_CHANGE_PASSWORD`, it means a request was attempted from a state where the flag is still `true`. Your UI must not "work around" this by hiding the endpoint. Redirect immediately.

---

## 2. Token storage and lifecycle

### What to store

After a successful `/login` or `/activate-workspace`, you get:

```json
{
  "session": {
    "access_token": "eyJhbGciOiJIUzI1NiIs...",
    "refresh_token": "v1.MjM0NTY3ODkw..."
  }
}
```

- `access_token` — a JWT. Send it on every authenticated request as `Authorization: Bearer <token>`. Short-lived (~1 hour).
- `refresh_token` — long-lived. Used only to get a new `access_token` when the current one expires. **Never send it in an `Authorization` header.** Never log it. Never store it in `localStorage` if you can avoid it.

### Where to store

| Storage | access_token | refresh_token | Reason |
|---|---|---|---|
| `localStorage` | ❌ | ❌ | XSS-readable. A single injected script steals the whole session. |
| `sessionStorage` | ⚠️ | ❌ | Cleared on tab close (usually good UX). Still XSS-readable. |
| **httpOnly cookie** | ✅ | ✅ | Not readable by JS. Set by the backend. This is what you want. |
| In-memory + refresh cookie | ✅ | ✅ | Access token in memory, refresh token in httpOnly cookie. Best. |

**The backend does not yet set cookies.** It returns the tokens in the response body. That means the frontend is currently responsible for storing them, and `localStorage` is the easiest option — but it's also the least secure.

**Decision to make before shipping:** either (a) move token storage to httpOnly cookies set by the backend, or (b) accept `localStorage` with a short-lived access token and aggressive refresh. Option (a) is the correct answer, but it requires a small backend change (the `/login` response sets `Set-Cookie` instead of returning tokens). Track this as a v1.1 item.

### When the access token expires

Your API will start returning 401 `UNAUTHORIZED` with `code: 'UNAUTHORIZED'`. When that happens:

1. Call Supabase's refresh endpoint (or the backend's future `/refresh` route).
2. If refresh succeeds, retry the original request once.
3. If refresh fails, clear tokens and redirect to login.

**Do not infinite-loop on 401.** Retry exactly once.

---

## 3. Endpoint reference

Every endpoint, in the order you'll use them.

### Base URL

- Development: `http://localhost:3001`
- Production: (TBD)

### Common response envelope

Every error response looks like this:

```json
{
  "error": "بيانات الدخول غير صحيحة.",
  "code": "INVALID_CREDENTIALS",
  "requestId": "550e8400-e29b-41d4-a716-446655440000",
  "details": null
}
```

- `error` — user-facing message, **in Arabic**. Display it as-is.
- `code` — machine-readable identifier. **Switch on this, not on `error`.** The Arabic message can be reworded; the code is stable.
- `requestId` — include this in every bug report. It correlates to a server log line.
- `details` — optional structured detail. Usually `null`.

Every success response shape is documented per-endpoint below.

---

### 3.1 `GET /health`

Liveness check. No auth. Use it to detect backend availability.

**Response 200:**
```json
{ "ok": true, "service": "ecofin-pro-api", "env": "development" }
```

---

### 3.2 `POST /api/auth/check-license`

**Purpose:** Verify a license key before showing the activation form. Side-effect free — can be called repeatedly.

**Auth:** None.

**Rate limit:** 20 requests / 15 minutes per IP+tenant.

**Request body:**
```json
{
  "license_key": "TEST-ACTIVATION-KEY-001"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `license_key` | string | ✅ | Case-insensitive. Must contain hyphens. 8–30 chars. |

**Response 200:**
```json
{
  "license_key": "TEST-ACTIVATION-KEY-001",
  "is_used": false,
  "plan_key": "RETAIL",
  "org_name": "Test Shop"
}
```

| Field | Type | Notes |
|---|---|---|
| `license_key` | string | Normalized to uppercase |
| `is_used` | boolean | `true` = already activated. Block the activation form. |
| `plan_key` | string \| null | Plan identifier (`RETAIL`, `STARTER`, `ENTERPRISE`, ...) |
| `org_name` | string \| null | Pre-provisioned tenant name. Show as read-only context. |

**⚠️ Note:** The response deliberately does **not** contain `owner_email`. Do not expect it. The activation form asks the user to type their own email; the backend verifies it matches the pre-provisioned auth user.

**Error responses:**

| Status | Code | Meaning |
|---|---|---|
| 400 | `LICENSE_INVALID` | Malformed or unknown license key |
| 429 | `TOO_MANY_REQUESTS` | Rate limit exceeded. Check `Retry-After` header. |

**UI behavior:**
- If `is_used: true` → show "This license has already been activated. Please log in."
- If `is_used: false` → show the activation form with `org_name` pre-filled as read-only.
- On `LICENSE_INVALID` → show the `error` message, keep the input focused for retry.

---

### 3.3 `POST /api/auth/activate-workspace`

**Purpose:** One-time activation. Sets the owner's username and real password, marks the license as used.

**Auth:** None.

**Rate limit:** 20 requests / 15 minutes per IP+tenant.

**Request body:**
```json
{
  "license_key": "TEST-ACTIVATION-KEY-001",
  "email": "owner@test.local",
  "username": "owner",
  "password": "Str0ngPass!2026",
  "confirmPassword": "Str0ngPass!2026"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `license_key` | string | ✅ | Same as check-license |
| `email` | string | ✅ | Must match the pre-provisioned auth user's email. Case-insensitive. |
| `username` | string | ✅ | 3+ chars. Unique **within the tenant**. |
| `password` | string | ✅ | 8–128 chars. No composition rules. |
| `confirmPassword` | string | ✅ | Must equal `password` |

**Password policy (client-side mirror):**
- Minimum 8 characters (recommend showing "12+ recommended" hint)
- Maximum 128 characters
- No character-class requirements (letters, digits, symbols — any combination is fine)
- Reject: `password`, `password123`, `qwerty123`, `admin1234`, and ~20 similar common passwords
- **Accept non-ASCII** — Arabic passwords are valid
- **Do not trim** — leading/trailing spaces are legitimate characters

**Response 200:**
```json
{
  "tenant_slug": "testshop",
  "tenant_name": "Test Shop",
  "org_id": "00000000-0000-0000-0000-000000000001"
}
```

| Field | Notes |
|---|---|
| `tenant_slug` | **Store this in localStorage** — you'll need it on the login form |
| `tenant_name` | Display name |
| `org_id` | Internal UUID. Useful for logging. |

**Error responses:**

| Status | Code | Meaning | UI action |
|---|---|---|---|
| 400 | `LICENSE_INVALID` | Malformed or unknown key | Show message, link back to check-license |
| 400 | `LICENSE_USED` | Already activated | Show message, link to login |
| 400 | `LICENSE_EXPIRED` | Expired | Show message, contact support |
| 400 | `VALIDATION_FAILED` | Password too weak, username taken, passwords don't match | Show the specific `error` message under the relevant field |
| 401 | `INVALID_CREDENTIALS` | Email doesn't match the pre-provisioned owner | "The email you entered doesn't match this license. Check your email." |
| 404 | `LICENSE_NOT_PROVISIONED` | License exists but no org provisioned yet | "This license is being set up. Try again in a few minutes." |
| 500 | `INTERNAL` | Server error (rare) | Show generic error, offer retry |

**UI behavior:**
- After success, redirect to `/login` with `tenant_slug` pre-filled.
- **Do not auto-login.** The user should log in with their new credentials. This is deliberate — the backend doesn't return a session on activation.

---

### 3.4 `POST /api/auth/login`

**Purpose:** Authenticate.

**Auth:** None.

**Rate limit:** 10 requests / 15 minutes per IP+tenant.

**Request body:**
```json
{
  "tenant_slug": "testshop",
  "identifier": "owner",
  "password": "Str0ngPass!2026"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `tenant_slug` | string | ✅ | The value stored during activation. |
| `identifier` | string | ✅ | Username OR email. If it contains `@`, treated as email. |
| `password` | string | ✅ | |

**Response 200:**
```json
{
  "user": {
    "id": "uuid-of-auth-user",
    "personId": "uuid-of-employee-row",
    "email": "owner@test.local",
    "username": "owner",
    "role": "OWNER",
    "branchId": null,
    "orgId": "00000000-0000-0000-0000-000000000001",
    "permissions": ["pos", "sales.create"],
    "isSuperAdmin": false
  },
  "session": {
    "access_token": "eyJ...",
    "refresh_token": "v1..."
  },
  "must_change_password": false
}
```

**`user.role`** — one of: `OWNER`, `OPS_MANAGER`, `ACCOUNTANT`, `CASHIER`, `COLLECTOR`, `WAREHOUSE_MANAGER`, `HR_MANAGER`, `LAWYER`, `EMPLOYEE`, `SUPER_ADMIN`.

**`user.permissions`** — array of strings. Each is either `<module>` (e.g. `pos`) or `<module>.<action>` (e.g. `sales.create`). OWNER always has full access regardless of this array.

**`must_change_password`** — if `true`, the user is on a temporary password. See §3.6 for the required flow.

**Error responses:**

| Status | Code | Meaning | UI action |
|---|---|---|---|
| 400 | `INVALID_CREDENTIALS` | Missing fields | Client-side validation should prevent this |
| 401 | `INVALID_CREDENTIALS` | Bad slug, bad identifier, or bad password | **Show a single generic error**: "بيانات الدخول غير صحيحة." Do not distinguish. |
| 403 | `ACCOUNT_DISABLED` | Correct password, but account is deactivated | "هذا الحساب معطل. يرجى التواصل مع الإدارة." |
| 429 | `TOO_MANY_REQUESTS` | Rate limit exceeded | "محاولات كثيرة جداً. يرجى المحاولة لاحقاً." |

**⚠️ Critical:** Every 401 response — regardless of cause — has **identical** response body except `requestId`. Do not try to extract more information. If you build a UI that says "user not found" vs "wrong password", you're leaking information and the backend test suite will not protect you from accidentally shipping it. Show one generic message.

**UI behavior:**
- On 200 with `must_change_password: true` → store tokens, then **immediately redirect** to `/change-password` and block every other route.
- On 200 with `must_change_password: false` → store tokens, redirect to dashboard.
- On 403 `ACCOUNT_DISABLED` → show the message, do not clear the form (user might have a second account).
- On 429 → read the `Retry-After` header and disable the submit button for that many seconds.

---

### 3.5 `POST /api/auth/forgot-password`

**Purpose:** Trigger a Supabase-native password reset email.

**Auth:** None.

**Rate limit:** 5 requests / 1 hour per IP+tenant.

**Request body:**
```json
{
  "tenant_slug": "testshop",
  "identifier": "owner@test.local"
}
```

**Response 200 — always:**
```json
{ "success": true }
```

**This is the entire point.** Whether the tenant exists, whether the identifier matches a user, whether Supabase actually sent an email — the response is `{ "success": true }`.

**Do not add special cases.** If your UI says "we couldn't find that email" on one path and "check your inbox" on another, you've defeated the entire design.

**UI behavior:**
- Always show the same message: "If an account exists with that email, we've sent a reset link."
- Do not offer a "resend" button that reveals timing differences. Wait for user to act.

---

### 3.6 `POST /api/auth/change-password`

**Purpose:** Change the current user's password. The temp-password exit.

**Auth:** Required. Bearer token.

**Special:** This is one of only two endpoints reachable with `must_change_password = true`. The other is `/logout`.

**Request body:**
```json
{
  "currentPassword": "Str0ngPass!2026",
  "newPassword": "EvenStr0nger!2026",
  "confirmPassword": "EvenStr0nger!2026"
}
```

**Response 200:**
```json
{ "success": true }
```

**After a successful change, the current JWT remains valid** — but its `must_change_password` context is now stale. Re-login is recommended to get a token that reflects the new state. Actually, the backend reads the flag from the DB on every request, so the current token works immediately. But re-login gives a cleaner state.

**Error responses:**

| Status | Code | Meaning |
|---|---|---|
| 400 | `VALIDATION_FAILED` | Weak new password, mismatched confirmation, or new equals current |
| 401 | `INVALID_CREDENTIALS` | `currentPassword` is wrong |
| 401 | `UNAUTHORIZED` | No token, or invalid token |
| 403 | `ACCOUNT_DISABLED` | Account was deactivated mid-session |

**UI behavior:**
- Validate on the client first (matching passwords, min length) to avoid a round trip.
- On `INVALID_CREDENTIALS` → highlight the "current password" field, keep the other fields.
- On success → redirect to login with a toast ("Password changed. Please log in.").

---

### 3.7 `POST /api/auth/reset-owner-password`

**Purpose:** Owner-initiated reset of another employee's password within the same org.

**Auth:** Required + role `OWNER` + `must_change_password: false`.

**Request body:**
```json
{
  "userId": "uuid-of-target-auth-user",
  "newPassword": "NewPass!234"
}
```

| Field | Notes |
|---|---|
| `userId` | The target's Supabase `auth_id` (not their employee id) |
| `newPassword` | Same password policy as change-password |

**Response 200:**
```json
{ "success": true }
```

**Error responses:**

| Status | Code | Meaning |
|---|---|---|
| 400 | `VALIDATION_FAILED` | Weak password |
| 401 | `UNAUTHORIZED` | No token |
| 403 | `FORBIDDEN` | Not an OWNER, or target is in a different org |
| 404 | `NOT_FOUND` | Target user doesn't exist |

**UI behavior:**
- The "userId" is the auth UUID, not the employee id. If your UI has the employee list, make sure you're passing `auth_id`, not `id`. If the employee has never logged in and has no `auth_id`, the reset can't work — show "This user must log in once first."

---

### 3.8 `GET /api/auth/me`

**Purpose:** Get the current authenticated principal.

**Auth:** Required.

**Response 200:**
```json
{
  "id": "uuid",
  "personId": "uuid",
  "email": "owner@test.local",
  "username": "owner",
  "role": "OWNER",
  "branchId": null,
  "orgId": "uuid",
  "permissions": ["pos", "sales.create"],
  "isSuperAdmin": false,
  "must_change_password": false
}
```

Same shape as `login`'s `user` object, plus `must_change_password`.

**Use this to:**
- Hydrate the app shell after a page reload (you have the token but not the user object)
- Check permissions before rendering module UI
- Confirm the session is still valid

**Error responses:**

| Status | Code | Meaning |
|---|---|---|
| 401 | `UNAUTHORIZED` | No token / expired / invalid |
| 403 | `MUST_CHANGE_PASSWORD` | The temp-password flag is set. **Redirect immediately.** |
| 403 | `ACCOUNT_DISABLED` | Deactivated mid-session |

---

### 3.9 `POST /api/auth/logout`

**Purpose:** Signal logout. Stateless — the server does nothing.

**Auth:** Required.

**Response 200:**
```json
{ "success": true }
```

**Note:** In v1, there is no server-side session revocation. The access token remains valid until it expires (~1 hour). Client-side is responsible for clearing tokens.

**UI behavior:**
- Clear all tokens from storage.
- Clear any cached user state.
- Redirect to `/login`.
- Do **not** wait for the network to clear local state. If the request fails, still clear and redirect.

---

## 4. Error code catalog

Every code you might see, grouped by when.

| Code | HTTP | When | Handle by |
|---|---|---|---|
| `INVALID_CREDENTIALS` | 401 | Login failure (any cause) | Show generic message |
| `INVALID_CREDENTIALS` | 401 | Wrong current password on change-password | Highlight current-password field |
| `INVALID_CREDENTIALS` | 401 | Email mismatch during activation | Show activation form again |
| `UNAUTHORIZED` | 401 | Missing/invalid JWT | Clear tokens, redirect to login |
| `ACCOUNT_DISABLED` | 403 | Account deactivated | Show message, do not retry |
| `MUST_CHANGE_PASSWORD` | 403 | Temp-password flag still set | Redirect to change-password |
| `FORBIDDEN` | 403 | Wrong role | Show "not permitted" |
| `TENANT_SCOPE_REQUIRED` | 403 | Super admin called a tenant route | (internal — unlikely to reach UI) |
| `LICENSE_INVALID` | 400 | Bad license key | Show message, keep input |
| `LICENSE_USED` | 400 | Activation replay | "Already activated. Log in." |
| `LICENSE_EXPIRED` | 400 | Expired license | "Contact support." |
| `LICENSE_NOT_PROVISIONED` | 404 | Org not created yet | "Try again later." |
| `VALIDATION_FAILED` | 400 | Field-level validation | Show message near field |
| `NOT_FOUND` | 404 | Target missing (rare) | Show generic not-found |
| `TOO_MANY_REQUESTS` | 429 | Rate limit hit | Read `Retry-After` header, disable action |
| `INTERNAL` | 500 | Server bug | Show generic message, log `requestId` |

**Rule of thumb:** if the code is in the 4xx range, the frontend should handle it. If it's `INTERNAL`, report it with the `requestId`.

---

## 5. What "must_change_password" actually gates

When the flag is `true`, the server rejects **every** authenticated endpoint except:

- `POST /api/auth/change-password`
- `POST /api/auth/logout`

That's it. Not `/me`, not `/employees`, not `/products`, nothing.

If your UI tries to render the dashboard while the flag is set, every data-fetching call will return 403 `MUST_CHANGE_PASSWORD`. Don't design around this. Handle the transition cleanly:

1. After login, if `must_change_password: true`, navigate immediately to `/change-password`.
2. Guard every other route with a check: "if `user.must_change_password`, redirect to change-password."
3. After a successful change, re-login to get a clean token (the current one still works, but re-login gives you a fresh `user` object).

**Do not** try to call `/me` before redirecting. It will 403, and your error handler will probably log noise.

---

## 6. Headers

### Requests

| Header | When | Value |
|---|---|---|
| `Content-Type` | Always (POST/PATCH) | `application/json` |
| `Authorization` | Every authenticated request | `Bearer <access_token>` |
| `X-Request-Id` | Optional | A UUID. Echoed in the response. Useful for tracing. |

### Responses

| Header | When | Value |
|---|---|---|
| `X-Request-Id` | Always | The request's correlation id |
| `Retry-After` | On 429 only | Seconds until retry is allowed |
| `Content-Type` | Always | `application/json` |

**Log the `X-Request-Id`** for every non-2xx response. If the user reports a bug, you can correlate to the server log.

---

## 7. The three flows in full

Three sequences a frontend dev needs to implement. Copy these.

### 7.1 Activation

```
1. User lands on /activate
2. User enters license_key
3. → POST /api/auth/check-license
4. On 200 with is_used: false:
   a. Store org_name in form state (read-only display)
   b. Show email + username + password + confirm inputs
5. User fills form and submits
6. → POST /api/auth/activate-workspace
7. On 200:
   a. Store tenant_slug in localStorage
   b. Show success screen
   c. Navigate to /login with tenant_slug pre-filled
8. On 400 LICENSE_USED: show "already activated", link to /login
9. On 401 INVALID_CREDENTIALS: show "email mismatch", keep the form
```

### 7.2 Login (with temp-password branch)

```
1. User lands on /login
2. Pre-fill tenant_slug from localStorage if available
3. User enters identifier + password, submits
4. → POST /api/auth/login
5. On 200:
   a. Store access_token + refresh_token
   b. If must_change_password:
        - Store the user object
        - Navigate to /change-password
        - Block every other route
   c. Else:
        - Store the user object
        - Navigate to /dashboard
6. On 401 INVALID_CREDENTIALS:
   - Show generic message
   - Do NOT clear the identifier field
7. On 403 ACCOUNT_DISABLED:
   - Show "account disabled" message
8. On 429:
   - Show rate-limit message
   - Disable submit for Retry-After seconds
```

### 7.3 Temp-password change

```
1. User is on /change-password (redirected by login)
2. Only this route + logout are reachable
3. User enters current + new + confirm
4. Client validates: match, length, not equal to current
5. → POST /api/auth/change-password
6. On 200:
   a. Optionally re-login silently (recommended)
   b. Navigate to /dashboard with success toast
7. On 401 INVALID_CREDENTIALS:
   - Highlight "current password" field
   - Keep the other fields
8. On 400 VALIDATION_FAILED:
   - Show message under the relevant field
```

---

## 8. Frontend checklist before shipping

- [ ] Access token is **not** stored in `localStorage` (or if it is, this is documented and scheduled to move to httpOnly cookies)
- [ ] Every 401 triggers a single retry after refresh, not an infinite loop
- [ ] `must_change_password: true` triggers an immediate redirect and route blocking
- [ ] Every 403 `MUST_CHANGE_PASSWORD` triggers the same redirect
- [ ] Login error handling shows **one generic message** for all 401s
- [ ] Forgot-password shows the same message for all inputs
- [ ] Rate-limit 429 reads `Retry-After` and disables the action
- [ ] Logout clears tokens *even if the API call fails*
- [ ] `tenant_slug` is stored after activation, retrieved before login
- [ ] Every non-2xx response's `requestId` is logged client-side

---

## 9. What the backend does NOT do (and why)

A list of things the frontend might expect but shouldn't:

| Expected | Reality | Reason |
|---|---|---|
| "Refresh token" endpoint on this API | Not yet. Use Supabase's refresh directly, or wait for `/api/auth/refresh`. | Deferred to v1.1 |
| "Forgot password" sends an SMS | Only email. Supabase native. | SMS provider is v1.1 |
| Session revocation on logout | Client-side only. Token valid until expiry. | Deferred to v1.1 |
| Detailed error messages for login | One generic message for every failure | Enumeration defence |
| Owner email on check-license | Not returned | Enumeration defence |
| Auto-login after activation | Not done | Deliberate — user must log in with their new credentials |
| Token in a cookie | Not yet. In the body. | See §2 decision |

---

## 10. Contact

For any question about behavior, check:
1. `http://localhost:3001/docs` — interactive Swagger for the same endpoints
2. `docs/02-architecture/adr/0004-auth-and-tenancy.md` — the design decisions
3. The `code` field on the response — it's the stable identifier

If you find a mismatch between this document and the actual behavior, the actual behavior wins. Report the drift.