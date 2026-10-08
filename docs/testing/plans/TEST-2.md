# TEST-2 · Shop setup tests (EC-130)

**When:** after INT-2 (EC-129). **Done when:** all pass in CI. Every test below runs in CI on each PR: the API `db` job runs every file in `supabase/tests/` (TEST-1 glob), the API `integration` job runs the `RUN_INTEGRATION=1` suites, and the Web `check` / `e2e` jobs run the unit tests and Playwright against a local stack.

| Requirement | Where it is proven | Repo |
|---|---|---|
| Each of the 7 roles can **do** only what its default permissions allow | `supabase/tests/f06_permissions_test.sql` §1: for every permission key, a role without it gets `PERMISSION_DENIED` from `app.require_permission`; OWNER always has it. `tenant_and_permission_test.sql` §4.1: every callable write function is denied to a role that lacks its key (a new function without a case fails §4.0). | API |
| Each role **sees** only what it may use | `src/config/navigation.roles.test.ts`: permission-gated menu items follow `ROLE_DEFAULT_PERMISSIONS` for all 7 roles; the visible pages per role are snapshots. Routes with a permission use `RequirePermission` (`e2e/permissions.spec.ts`). | Web |
| Per-employee extra permissions work | `f06_permissions_test.sql` §1: an override `granted=true` gives a key, `granted=false` removes a role default; §2 audits each change. `navigation.roles.test.ts`: an extra `audit.view` shows the Audit item to a cashier. C02 uses a `granted=false` override for `catalog.price_change` (`c02_products_test.sql`, `products.integration.test.ts`). | API, Web |
| A deactivated employee is blocked at once | `ec143_employee_active_test.sql` (sessions and access end on deactivation), `src/routes/auth.sessions.integration.test.ts`, Web `e2e/employee-active.spec.ts` (EC-145: the signed-in cashier is refused on the next request). | API, Web |
| Plan limits are enforced on the server | `p05_subscription_test.sql`: branch limit (insert and un-archive), user limit (pending employees count, reactivation can't exceed it), device limit → `PLAN_LIMIT_REACHED`. INT-2 e2e: the fourth branch on the retail plan is refused through the UI. **Products:** no product limit by decision (D46, 9 Oct): plans cap branches, users and devices only. | API, Web |
| VAT results match the T01 cases | `t01_vat_test.sql`: every golden document and return in `supabase/tests/fixtures/t01_tax_cases.json` through `app.compute_document_tax` / `app.return_line_tax`; `packages/contracts/src/tax.test.ts` runs the same cases on the TypeScript engine; `src/test/t01-golden.test.ts` keeps the two copies equal. | API |
| Changing a rate doesn't change old documents | `t01_vat_test.sql` ("rate change keeps issued lines"): an issued sale line keeps its rate and tax after `update_tax_class` changes the rate. | API |
| Arabic and English: Playwright walks the setup flow (RTL check) | `e2e/shop-setup.spec.ts` (INT-2): provision → invite → settings → profile → branches (plan limit) → staff → category → taxed product → label, once in `en` and once in `ar`; on four pages it checks `html[dir]` (`rtl` / `ltr`) and that nothing scrolls sideways. `e2e/rtl.spec.ts` covers long Arabic text. | Web |

## Run locally

```text
npm run db:smoke -- supabase/tests/f06_permissions_test.sql     # and p05_, t01_, ec143_, tenant_and_permission_
RUN_E2E=1 npx playwright test e2e/shop-setup.spec.ts            # Web, API on :3001 with SMTP_URL=smtp://127.0.0.1:54325
npx vitest run src/config/navigation.roles.test.ts              # Web
```