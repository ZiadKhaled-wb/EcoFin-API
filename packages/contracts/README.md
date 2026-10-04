# @ziadkhaled-wb/contracts

Shared request/response schemas (zod 3), error codes, roles and permission keys for EcoFin-API and EcoFin-Web.
Version 0.4.0 covers every Sprint 1 endpoint (F04 auth, F06 permissions, F07 audit search, F08 health) and the shared money rules (F12).

## Use

In this repo the API uses it through the npm workspace (`packages/*`), so there is nothing to install separately.
Build `dist/` from the repo root with `npm run build:contracts` (the API's typecheck, test and build do it for you).
`EcoFin-Web` installs it from GitHub Packages (`"@ziadkhaled-wb/contracts": "0.4.0"`, see D26); releases are published by
pushing a tag `contracts-vX.Y.Z` (see `.github/workflows/contracts-publish.yml`).

```ts
import { AuthLogin, PERMISSION_KEYS, Money, type AuthLoginBody } from '@ziadkhaled-wb/contracts';
const body = AuthLogin.body.parse(req.body); // strict: unknown keys such as organization_id are rejected
```

Each endpoint exports `{ body?, query?, response }` zod schemas plus inferred types (`AuthLoginBody`, ...).

## Money (F12, D31)

All money maths goes through these helpers; never JS `number` arithmetic. Amounts are decimal strings in and out.

```ts
import { splitMoney, taxForLine, sumTaxLines, formatEgp } from '@ziadkhaled-wb/contracts';
splitMoney('1000.00', 3); // ['333.34', '333.33', '333.33']
const lines = items.map((i) => taxForLine(i.amount, i.taxRate, doc.pricesIncludeVat)); // rounded per line
sumTaxLines(lines); // { net, tax, gross } of the document
formatEgp('1250.5', 'ar'); // '1,250.50 ج.م'
```

## Scripts

`npm run build | typecheck | lint | format:check | test`

Tests read the API baseline SQL for the permission and error-code parity checks. Default path is
`../../supabase/migrations/20261002000000_v1_baseline.sql` (relative to this package); override with `ECOFIN_BASELINE_SQL`.

## Rules

Bump `version` in `package.json` and `CONTRACTS_VERSION` in `src/index.ts` on every change, and add a line to `CHANGELOG.md`.
