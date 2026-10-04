# @ziadkhaled-wb/contracts

Shared request/response schemas (zod 3), error codes, roles and permission keys for EcoFin-API and EcoFin-Web.
Version 0.2.0 covers every Sprint 1 endpoint (F04 auth, F06 permissions, F07 audit search, F08 health).

## Use

In this repo the API uses it through the npm workspace (`packages/*`), so there is nothing to install separately.
Build `dist/` from the repo root with `npm run build:contracts` (the API's typecheck, test and build do it for you).
`EcoFin-Web` installs it from GitHub Packages (`"@ziadkhaled-wb/contracts": "0.2.0"`, see D26); releases are published by
pushing a tag `contracts-vX.Y.Z` (see `.github/workflows/contracts-publish.yml`).

```ts
import { AuthLogin, PERMISSION_KEYS, Money, type AuthLoginBody } from '@ziadkhaled-wb/contracts';
const body = AuthLogin.body.parse(req.body); // strict: unknown keys such as organization_id are rejected
```

Each endpoint exports `{ body?, query?, response }` zod schemas plus inferred types (`AuthLoginBody`, ...).

## Scripts

`npm run build | typecheck | lint | format:check | test`

Tests read the API baseline SQL for the permission and error-code parity checks. Default path is
`../../supabase/migrations/20261002000000_v1_baseline.sql` (relative to this package); override with `ECOFIN_BASELINE_SQL`.

## Rules

Bump `version` in `package.json` and `CONTRACTS_VERSION` in `src/index.ts` on every change, and add a line to `CHANGELOG.md`.
