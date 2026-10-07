# Changelog

## 0.12.0

- P04 legal and financing profile: `ShopProfile`, `ShopProfileUpdateBody`; error code `INSTALLMENTS_DISABLED` (403). `tax_registration_no` is edited through the profile, no longer through `PATCH /api/settings`.

## 0.11.0

- C01 categories: Category, CategoryList, CategoryCreateBody, CategoryUpdateBody, CategoryIdParams, CategoryArchiveBody, CategoryInUseDetail.

## 0.10.0

- T01 VAT engine: computeDocumentTax and returnLineTax (same results as the SQL engine on the golden cases), TaxClass schemas and bodies, TaxKind. ShopSettings gains installment_markup_vat, delivery_fee_tax_class_id, deposit_vat_timing. Error codes TAX_CLASS_NAME_TAKEN, TAX_CLASS_IN_USE, TAX_DISCOUNT_TOO_LARGE.

## 0.9.0

- P03 shop settings: ShopSettings, ShopSettingsUpdateBody, InstallmentPolicy(Body/List), Percent, InstallmentFrequency (adds daily), receipt fields, discount caps, credit weights, legal referral days. Error codes SETTINGS_INVALID, POLICY_INVALID, TAX_CLASS_NOT_FOUND, DISCOUNT_ABOVE_CAP.

## 0.8.1

- Merge EC-143 activation contracts with the shop task contracts; activation returns both naming conventions for existing callers.

## 0.8.0

- O02 staff management and password reset schemas/codes; invitation lookup includes the display login. BRANCH_REQUIRED maps to 400 for staff validation.

## 0.7.0

- O01 branch management, default safes, deactivation counts and branch error codes.

## 0.6.0

- P05 subscription states, usage, billing schemas, module keys, warning constant and structured limit errors. Shop-list rows include subscription end/state.

## 0.5.0

- P01 shop provisioning, platform shop administration, single-use invitations and the optional super-admin login flag.
## 0.4.2

- Access (EC-143): `EmployeeActiveSetBody` (`active`, `reason`), `EmployeeActiveSetResponse` and `EmployeeActiveSet` for `PUT /employees/:employeeId/active` (deactivate or reactivate an employee). Additive.

## 0.4.1

- Files (F14): `FilePurpose` (the 13 purposes of the `file_purpose` enum), `UploadFileRequest` (multipart text fields `purpose`, `entityType`, `entityId`), `FileResponse` (metadata only), `FileUrlResponse` (signed link and its expiry), `ListFilesQuery` (`entityType` + `entityId`), `FileListResponse`, and the path schema `FileIdParams`. Error codes `FILE_NOT_FOUND`, `FILE_PATH_INVALID`, `FILE_TOO_LARGE` (413) and `FILE_TYPE_NOT_ALLOWED` (415). Additive.

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
## 0.11.0

- Add category schemas and category error codes.
