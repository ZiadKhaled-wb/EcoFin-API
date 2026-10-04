# Local database (Supabase CLI)

The database schema lives in `supabase/migrations/` as plain SQL, applied by the Supabase CLI.
Everything here is **local only**.

> **Never** run `supabase link`, `supabase db push`, or point these commands at a real project.
> The seed passwords below are public. Seeds are for local and CI databases only.

Requirements: Docker running, Node 24. The CLI runs through `npx supabase@2.119.0` (pinned in
`package.json`; nothing to install globally). On the Sprint 1 dev machine, prefix npm commands with
`NODE_OPTIONS=--no-network-family-autoselection` (see `docs/testing/ENVIRONMENT.md`).

## Rebuild from zero (one command)

```bash
npm run db:reset
```

Starts the local stack if needed, drops the database, applies every migration in order, then runs
both seeds. Other scripts: `npm run db:start`, `npm run db:stop`.

Local URLs: API `http://127.0.0.1:54321`, DB `postgresql://postgres:postgres@127.0.0.1:54322/postgres`,
Studio `http://127.0.0.1:54323`, Mailpit `http://127.0.0.1:54324`. Keys: `npx supabase@2.119.0 status`.

## Seeds

Listed in order in `config.toml` under `[db.seed] sql_paths`. They run as `postgres` on every reset.

| File                       | What it creates                                                                         |
| -------------------------- | --------------------------------------------------------------------------------------- |
| `seeds/01_super_admin.sql` | The first platform super admin: `superadmin@ecotech.test`                               |
| `seeds/02_dev_data.sql`    | `dev-shop-one` (BR1, BR2) and `dev-shop-two` (BR1), each with an owner and a BR1 cashier |

Every seeded login uses the password `LocalDev-Only-2026!`. Dev emails:
`owner.one@`, `cashier.one@`, `owner.two@`, `cashier.two@` + `ecotech.test`. Fixed ids are listed at
the top of `02_dev_data.sql`.

Check the super admin can sign in (anon key from `npx supabase@2.119.0 status`):

```bash
curl -X POST "http://127.0.0.1:54321/auth/v1/token?grant_type=password" \
  -H "apikey: <local anon key>" -H "Content-Type: application/json" \
  -d '{"email":"superadmin@ecotech.test","password":"LocalDev-Only-2026!"}'
```

## Smoke test

```bash
npm run db:smoke
```

Runs `tests/smoke_test.sql` (79 checks) inside the local DB container, wrapped in
`BEGIN ... ROLLBACK`, so it leaves nothing behind. Prints `passed 79, failed 0` and exits non-zero if
any check fails or the SQL errors. Run another file with `npm run db:smoke -- <file.sql>`.

## Running the migrations twice changes nothing

```bash
npx supabase@2.119.0 migration up --local   # {"applied":[],...}: nothing pending
```

CI also compares a full `pg_dump` before and after that command (job `db` in
`.github/workflows/ci.yml`).

## Regenerate TypeScript types

```bash
npm run db:reset && npm run db:types
```

Writes `src/types/database.types.ts` (schema `public`, formatted with Prettier). Commit it with the
migration that changed the schema. Right after a reset it must give no diff.

## Adding a migration

New SQL goes in a **new** file, `supabase/migrations/<timestamp>_<name>.sql`. Never edit an existing
migration (the baseline `20261002000000_v1_baseline.sql` included). The old `migrations/` folder at
the repo root is the legacy hand-applied set and is not used by the CLI.
