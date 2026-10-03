# Changelog

## 0.1.0

- First release: common types (Uuid, Money, dates, pagination, idempotency key), error codes and shape, roles, 61 permission keys with role defaults, schemas for auth (F04), access (F06), audit search (F07) and health (F08).
- Auth contract: login and forgot-password take `identifier` (+ `tenantSlug`, required for usernames); shops carry `tenantSlug`; `mustChangePassword` in login and me; change-password schema; password max 72 (bcrypt limit).
- select-shop response is now `{ user, shop }` only (no tokens; Supabase tokens carry no shop, D23).
