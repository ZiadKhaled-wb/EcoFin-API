# @ecotech/contracts

Shared request/response schemas (zod 3), error codes, roles and permission keys for EcoFin-API and EcoFin-Web.
Version 0.1.0 covers every Sprint 1 endpoint (F04 auth, F06 permissions, F07 audit search, F08 health).

## Use

```json
"@ecotech/contracts": "file:../EcoFin-Contracts"
```

(Later: `github:<owner>/EcoFin-Contracts#v0.1.0`.) Installing runs `prepare`, which builds `dist/`.
After editing this package, run `npm run build` here, then `npm install` in the consumer if it copied the package.

```ts
import { AuthLogin, PERMISSION_KEYS, Money, type AuthLoginBody } from '@ecotech/contracts';
const body = AuthLogin.body.parse(req.body); // strict: unknown keys such as organization_id are rejected
```

Each endpoint exports `{ body?, query?, response }` zod schemas plus inferred types (`AuthLoginBody`, ...).

## Scripts

`npm run build | typecheck | lint | format:check | test`

Tests read the API baseline SQL for the permission and error-code parity checks. Default path is
`../EcoFin-API/supabase/migrations/20261002000000_v1_baseline.sql`; override with `ECOFIN_BASELINE_SQL`.

## Rules

Bump `version` in `package.json` and `CONTRACTS_VERSION` in `src/index.ts` on every change, and add a line to `CHANGELOG.md`.
