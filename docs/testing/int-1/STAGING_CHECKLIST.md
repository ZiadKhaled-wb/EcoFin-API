# INT-1 · Staging checklist (checks a–g with two test shops)

For a person repeating the INT-1 checks on **staging**. Nothing here touches production. Use new test passwords, never the public local-dev one.

## 0. Before you start
1. Staging API and Web are deployed from the same commits that passed INT-1 locally (EcoFin-API and EcoFin-Web `int/int-1-foundation`, after merge).
2. Every staging migration is applied (`supabase migration list` shows the same list as the repo, including `20261005120000_f14_register_file.sql` if F14 is merged).
3. You can see the staging `audit_log` table (Supabase dashboard → Table editor, read only) and the staging auth email inbox for the reset test.
4. Browser with dev tools (Network tab) open.

## 1. Seed two test shops (once)
Through the platform's normal onboarding, or by a maintainer with a staging-only SQL script modelled on `supabase/seeds/02_dev_data.sql` (never run that file itself on staging: its password is public):

| Login | Shop | Role | Branch |
|---|---|---|---|
| `qa.owner.a@…` | QA Shop A | OWNER | A-Main |
| `qa.cashier.a@…` | QA Shop A | CASHIER | A-Main |
| `qa.owner.b@…` | QA Shop B | OWNER | B-Main |
| `qa.cashier.b@…` | QA Shop B | CASHIER | B-Main |
| `qa.multi@…` | both | CASHIER in A, ACCOUNTANT in B | main branch of each |

Write down the shop ids, branch ids and employee ids (you need shop B's for check d). Keep the passwords in the team's password manager.

## 2. Checks

| # | Do this | Expected |
|---|---|---|
| a | Open the staging site (Arabic by default). Log in as `qa.owner.a`. Open the menu (☰ on small screens). | Lands on the dashboard; branch button shows A-Main; menu: Dashboard, Sales, Inventory, Purchasing, Customers, Suppliers, Employees, Accounting, Reports, Audit log, Settings. Switch to English: same items, layout flips left-to-right. |
| b | Log out. Log in as `qa.cashier.a`. Open the menu. Then type in the address bar: `/audit`, `/settings`, `/employees`, `/reports`. | Menu: Dashboard, Sales, Customers only. Each typed address shows "You don't have permission to open this page" (403 page), never the page itself. Repeat in English. |
| c | Log out. Log in as `qa.multi`. | The "Choose a shop" page lists QA Shop A (Cashier) and QA Shop B (Accountant). Choose B: menu shows Accountant items; in Network, API calls carry header `x-org-id` = shop B id. Type `/select-shop`, choose A: menu shows Cashier items, `x-org-id` = shop A id, branch = A-Main. Repeat the picker in Arabic and English. |
| d | Logged in as `qa.cashier.a`, copy the `Authorization` header from any API call. With curl or Postman: (1) `GET /api/auth/me` with header `x-org-id: <shop B id>`; (2) `PUT /api/employees/<shop B cashier id>/permissions` body `{"permissionKey":"sale.void","granted":true,"reason":"qa"}`. Then as `qa.owner.a`: (3) the same PUT; (4) `PUT /api/employees/<qa.cashier.a id>/branches` body `{"branchIds":["<shop B branch id>"],"reason":"qa"}`; (5) `GET /api/audit?actorEmployeeId=<shop B owner id>`. | (1) 403 `SHOP_NOT_ALLOWED`; (2) 403 `PERMISSION_DENIED`; (3) 404 `NOT_FOUND`; (4) 422 `BRANCH_NOT_IN_ORG` (same as for a made-up id); (5) 200 with `items: []`. No response contains any shop B name, email or id other than what you sent. |
| e | As `qa.owner.a`, send `PUT /api/employees/<qa.cashier.a id>/permissions` with body `{"permissionKey":"sale.void","granted":true,"reason":"qa e"}` and header `x-request-id: qa-e-<date>`. Then open Audit log in the UI (or the `audit_log` table filtered by `request_id`). Undo with `granted:false`. | 200. Exactly **one** audit row with action `employee.permission_set`, actor = owner A, request id `qa-e-<date>`, and your real public IP (not `::1` or the proxy's IP). |
| f | (1) As `qa.owner.a`, copy the access token, then log out in the UI; call `GET /api/auth/me` with the old token. (2) Log in; in dev tools → Application → Local storage → `ecofin-auth`, change the last characters of `accessToken`; reload any page. (3) Log out; "Forgot password?" with `qa.owner.b`'s email; open the email; follow the link; set a new password; log in with it. | (1) 401 `TOKEN_INVALID`. (2) Page loads normally; Network shows one 401 then `POST /api/auth/refresh` 200 and the retried call 200; no trip to the login page. (3) Email arrives within a minute; the reset page accepts the new password; the new password works and the old one is refused. |
| g | Log in as `qa.cashier.a` in one browser. In another browser, as `qa.owner.a`, deactivate the cashier (until the Employees screen exists: a maintainer sets `employees.is_active=false` for that employee in the staging dashboard). Back in the cashier's browser, click anything that calls the API. Then re-activate. | The cashier's next request fails with 403 `ACCOUNT_DISABLED` and the app sends them to login; a new login is refused. After re-activating, the cashier can log in again. |

## 3. Afterwards
- Undo any permission or branch change you made; reset passwords you changed.
- Record PASS/FAIL per check with screenshots in the EC-127 ticket.
