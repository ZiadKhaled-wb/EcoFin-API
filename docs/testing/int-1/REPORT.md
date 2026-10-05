# INT-1 · Foundation integration report (Jira EC-127)

**Date:** 5–6 Oct 2026 · **Branches:** `int/int-1-foundation` in EcoFin-API (from `feat/f14-file-storage`, on request) and EcoFin-Web (from `main` 8fbf5c0) · **Stack:** local Supabase (Docker) only, nothing remote.

**How it was run:** one agent, no subagents (user request), so the E/V/U/R roles of the task were done by the same agent; fixes were self-reviewed against the `ecotech-review` checklist. The API branch includes F14 because the user asked to branch from it; F14 itself was evaluated separately and not re-tested here beyond the full suites.

## Checks a–i

| # | Check | Result | Evidence |
|---|---|---|---|
| a | Owner A logs in through the UI → shop A → every menu | **PASS** | Playwright MCP: `/dashboard`, branch "Shop One Main", 11 top-level menus = `navigation.ts` for OWNER. Screenshots `EcoFin-Web/test-results/int-1/a-owner-a-*.png` (AR and EN) |
| b | Cashier A sees only allowed menus; typed guarded URL blocked | **PASS after fix** | Menu: Dashboard, Sales, Customers. `/audit` → 403 page. **Before the fix** `/settings` and `/employees` opened the module page (`b-cashier-a-settings-url-ar.png`); after → 403 (`b-cashier-a-settings-url-after-fix-ar.png`). Unit test `RequireNavItem.test.tsx` 5/5 |
| c | Two-shop login → picker; switching shop changes data (`x-org-id`) | **PASS** (open UX bug) | Picker lists Dev Shop One (Cashier) / Dev Shop Two (Accountant). After choosing B: requests carry `x-org-id: d1…0002`, permissions = accountant keys, branch BR1 of shop B; after choosing A: CASHIER keys, branch BR1 of shop A. API: no header → 400 `SHOP_SELECTION_REQUIRED`, A → CASHIER, B → ACCOUNTANT (`api-checks.log` [c]). Switching is only reachable by typing `/select-shop` (bug 1) |
| d | Cross-shop through the API → 403/404, nothing leaks | **PASS** | `api-checks.log` [d], 7 checks: x-org-id B → 403 `SHOP_NOT_ALLOWED`; cashier A on shop B employee → 403; owner A on shop B employee → 404 `NOT_FOUND`, no B data; shop B branch → 422 `BRANCH_NOT_IN_ORG`, identical to a non-existent branch id (no existence leak); audit search for a B employee → 0 rows; audit list → no B rows; cashier → audit 403 |
| e | One write → exactly one `audit_log` row with employee, request id, ip | **PASS** | `PUT /api/employees/:id/permissions` → 200, one row: `employee.permission_set`, owner.one's employee id, the sent `x-request-id`, the sent client IP, shop A (`api-checks.log` [e]). Also `audit.integration.test.ts`: one row per registry write route |
| f | Logout kills old token; silent refresh; forgot-password via Mailpit + reset page | **PASS** | UI logout → old token on `/api/auth/me` 401 `TOKEN_INVALID`, stored tokens cleared. Silent refresh: corrupted stored access token → `/me` 401 → `/api/auth/refresh` → page loads with a new token (`f-silent-refresh-audit-en.png`). API: refresh 200, logout → access 401 + refresh 401. Reset: e2e `forgot password, Mailpit email, reset page, new password, log in` passed |
| g | Owner deactivates cashier A → next request rejected | **PASS** (via DB) | Live token 200 → `is_active=false` → 403 `ACCOUNT_DISABLED`; new login refused (403); works after re-enable (`api-checks.log` [g]). There is **no deactivate endpoint or screen yet** (bug 2), so the flag was set with the service role, the same way `auth.sessions.integration.test.ts` does it |
| h | Arabic (RTL) and English for a, b, c | **PASS** | `dir`/`lang` switch to rtl/ar and ltr/en; drawer opens on the start side; in English the only Arabic text is the "العربية" switch label; shop names are data and stay as stored. Screenshots `*-ar.png` / `*-en.png` |
| i | CI runs these suites on a PR | **PASS with gaps** | API `ci.yml`: job `check` (typecheck, lint, format, unit tests, cross-shop/permissions/audit route checks, build) and job `db` (local Supabase, reset twice, every SQL test except F14, full `RUN_INTEGRATION=1` suite, ledger reconcile). Web `ci.yml`: typecheck, lint, format, test, build. **Skipped by CI:** the Web Playwright e2e suite (bug 3) and `supabase/tests/f14_files_test.sql` (bug 4). Last CI on `main`: green in both repos (API fb643d7, Web 8fbf5c0). This branch was not pushed, so its CI has not run |

## Test totals

| Suite | Before (as branched) | After |
|---|---|---|
| API typecheck / lint / format | ✅ / ✅ / ✅ | ✅ / ✅ / ✅ |
| API unit + contracts (`npm test`) | 470 passed, 56 skipped / 88 passed | same |
| API `RUN_INTEGRATION=1` full suite | **524 passed, 2 failed** of 526 (F07 audit test had no driver for F14's `POST /api/files`) | **526/526** |
| API route checks (cross-shop, permissions, audit) | 17 / 17 / 11 routes, all covered | same |
| SQL tests (fresh `db reset`, run twice) | smoke 79, f04 48, f05 41, f06 67, f07 20, f10 30, f11 16, f13 32, f14 10 — 0 failed | same |
| Live API checks c–g (`api-checks.log`) | 14/14 | 14/14 |
| Web typecheck / lint / format / build | ✅ / ✅ (1 library warning) / ✅ / ✅ | same |
| Web unit (`npm test`) | 128/128 | **133/133** (+5 RequireNavItem) |
| Web e2e (`RUN_E2E=1`) | 21/21 | 21/21 |

## Fixes

| # | Fix | Story | Commit | Review |
|---|---|---|---|---|
| 1 | F07 audit integration test had no driver for `POST /api/files` (multipart, 201), so `RUN_INTEGRATION=1` failed 2 tests; drivers can now declare their success status | F14 ↔ F07 glue | EcoFin-API `503a421` (on `feat/f14-file-storage`, pushed) | self-review: APPROVE (test-only, assertions unchanged in strength) |
| 2 | Menu-generated routes had no guard: a cashier typing `/settings`, `/employees`, `/reports`… got the page. `RequireNavItem` applies the menu's own rule (`canSee`, now exported) to each menu route and fails closed | F09 ↔ F06 glue (security) | EcoFin-Web `df7813c` | self-review: APPROVE. 13 lines + new guard + test; no new dependency, no contract change, no new strings; the test fails with the guard removed (2 of 5) |

## Open bugs

| # | Severity | Story | Where | Proposed Jira title |
|---|---|---|---|---|
| 1 | Medium | F09 / F04 | EcoFin-Web `src/components/layout/Topbar.tsx` account menu (only "Sign out") | Shell: add "Switch shop" to the account menu for logins in more than one shop |
| 2 | Medium (gap) | F06 (employee admin) | EcoFin-API `src/routes/employees.ts` (only `/permissions` and `/branches`) | Employees: owner can deactivate and reactivate an employee (API + screen, audited) |
| 3 | Medium | F01 (web CI) | EcoFin-Web `.github/workflows/ci.yml:20-28` | CI (web): run the Playwright e2e suite against a local stack on pull requests |
| 4 | Low | F14 | EcoFin-API `.github/workflows/ci.yml:120-149` | CI (api): add `f14_files_test.sql` to the db job |
| 5 | Low | F09 | `index.html` / no `public/` folder (no favicon) | Web: add a favicon (404 in the console on every page) |
| 6 | Info | F07 / env | local only | Audit `ip` shows `::1` through the Vite dev proxy (no `X-Forwarded-For`); confirm on staging that rows carry the real client IP |

## Environment fixes (no code changes; documented in `docs/testing/ENVIRONMENT.md`, "INT-1 update")
- Started Docker Desktop by hand.
- API and Web started with local env vars in the shell; the local `.env` files point to remote projects and were not used.
- `npx playwright install chromium` (Playwright 1.63 needs headless shell 1243).
- Web `npm ci` failed with 401 (no `NPM_TOKEN` with `read:packages`); worked around locally by building contracts 0.4.0 from the tag `contracts-v0.4.0` and `npm install --no-save` (nothing committed). **To do:** set `NPM_TOKEN` and re-run a clean `npm ci`.
- Seed: nothing missing (two shops with branch, OWNER and CASHIER; one two-shop login; super admin). Logins: `LOGINS.md`.
