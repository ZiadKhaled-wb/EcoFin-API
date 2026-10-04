# Changelog

## 0.4.0

- Money (F12): `roundMoney` (one rule: half-up to 2 decimals), `addMoney`, `subtractMoney`, `sumMoney`, `compareMoney`, `multiplyMoney`, `percentOf`, `splitMoney` / `allocateMoney` (parts add back exactly, largest remainder), VAT `taxFromNet` / `taxFromGross` / `taxForLine` / `sumTaxLines` (tax rounded per line, totals are sums of lines) and `formatEgp` (Arabic and English). Inputs and outputs are decimal strings; the maths runs on `big.js` 7.0.1, the package's first runtime dependency besides zod (D31). Additive.

## 0.3.0

- Audit (F07): `AuditRow` gains `actorName` (the acting employee's full name, null for platform/service actions), so the owner's audit screen can show who did it without a separate employees endpoint. Additive for readers; servers must now send it.

## 0.2.0

- Access (F06): the employee id moves from the request bodies to the path (`EmployeeIdParams`, used by `PUT /employees/:employeeId/permissions` and `/branches`); `EmployeeBranchesAssignBody` gains a required `reason` (stored on the audit row), like the permission override. Breaking for these two bodies only; nothing used them in 0.1.0.

## 0.1.0

- First release: common types (Uuid, Money, dates, pagination, idempotency key), error codes and shape, roles, 61 permission keys with role defaults, schemas for auth (F04), access (F06), audit search (F07) and health (F08).
- Auth contract: login and forgot-password take `identifier` (+ `tenantSlug`, required for usernames); shops carry `tenantSlug`; `mustChangePassword` in login and me; change-password schema; password max 72 (bcrypt limit).
- select-shop response is now `{ user, shop }` only (no tokens; Supabase tokens carry no shop, D23).
