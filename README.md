# EcoFin Pro — API server

Multi-tenant retail ERP/POS backend. Node 24, Express 4, TypeScript, Supabase.

## Requirements

- Node.js — see `.nvmrc` (`nvm use` to switch)
- npm >= 10
- A Supabase project (URL + anon key + service-role key)

## Setup

1. `nvm use`
2. `npm install`
3. `cp .env.example .env` and fill in the Supabase values.
4. Run the schema — see "Database" below.
5. `npm run dev`

The server binds to `PORT` (default 3001). API docs at http://localhost:3001/docs.

## Database

The canonical schema lives in `docs/db/initialization-v2.1.sql`. On a fresh
Supabase project, run it in the SQL Editor. It creates the `public` schema
from scratch — **it does not drop existing tables first**, so only run it
on an empty database.

After the schema, run `migrations/0003_role_grants.sql` in the SQL Editor.
Without it, every query through `supabaseAnon` / `supabaseUser` /
`supabaseAdmin` fails with `permission denied for table X`, because SQL
Editor DDL doesn't grant roles automatically.

Then seed the first super admin (see `docs/db/seed-first-super-admin.sql`).

## Development commands

| Command | Purpose |
|---|---|
| `npm run dev` | Watch mode — restarts on file change |
| `npm run build` | Compile to `dist/` |
| `npm start` | Run the compiled build |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run lint` | ESLint |
| `npm test` | Vitest, single run |
| `npm run test:watch` | Vitest, watch mode |
| `npm run test:coverage` | Coverage report |

## Environment variables

See `.env.example`. All are validated at boot by `src/utils/env.ts` —
the process exits with a clear message if any required value is missing.

## Architecture

- **Tenancy**: every request is scoped to one organization via the JWT.
  See `docs/02-architecture/adr/0004-auth-and-tenancy.md`.
- **Auth model**: three Supabase clients, three responsibilities. See
  the header comment in `src/utils/supabase.ts`.
- **Money**: bigint piasters, no floats. Use `egp_to_piasters()` /
  `piasters_to_egp()` at API boundaries.
- **Atomicity**: multi-step writes go through Postgres RPCs. No
  `TransactionTracker`-style manual rollback.

## Auth smoke test

Requires a seeded test tenant. See the walkthrough in
`docs/02-architecture/adr/0004-auth-and-tenancy.md` §Verification.

## Contributing

Before opening a PR:
- `npm run typecheck` — zero errors
- `npm run lint` — zero errors
- `npm test` — all passing

Three greps run in CI (add to your pre-commit hook if you have one):
- `grep -rn 'supabaseAdmin' src/ --include='*.ts'` — every hit must be
  a pre-auth flow, super-admin flow, or `auth.admin.*` call.
- `grep -rn 'as any\|: any\|<any>' src/ --include='*.ts'` — zero hits.
- `grep -rn 'console\.' src/ --include='*.ts'` — zero hits.

## Open questions

See the "Open questions" section of ADR-0004.

## Deployment

See [docs/05-operations/deployment.md](docs/05-operations/deployment.md): Docker image, Azure VM (Caddy + HTTPS), and the `Deploy (development)` workflow.
