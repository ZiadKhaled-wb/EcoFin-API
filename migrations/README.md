# Migrations

Ordered SQL files that upgrade an already-deployed database. Applied in
numeric order, top to bottom.

## Naming

    NNNN_short_description.sql

- `NNNN` — zero-padded 4-digit sequence. Never reuse a number.
- `short_description` — lower_snake_case, describes the change not the table.
  `add_password_changed_at`, not `employees`.

## When a migration is required

- A new table, column, index, constraint, or view
- A new RPC function
- A change to an RLS policy
- A change to role grants
- A data backfill

## When a migration is NOT required

- A code change that doesn't touch the schema
- A dependency bump
- A new API route
- A new OpenAPI entry

## Relationship to the bootstrap

`docs/db/initialization-v2.1.sql` is the **full current schema** for a
fresh project. It always represents the end state — a fresh install
runs it once and is fully up to date.

Every migration is *also* folded into the bootstrap (usually as a new
numbered section near the bottom). This means:

- Fresh installs run one file: the bootstrap.
- Existing installs run the migrations they haven't yet applied.

Both must end up at the same schema. If they don't, you have a bug.

## Recording where a migration ran

At the top of each migration file:

    -- Applied to:
    --   * dev (project-ref) — YYYY-MM-DD
    --   * staging (project-ref) — YYYY-MM-DD
    --   * prod (project-ref) — YYYY-MM-DD

Update the list every time the migration runs somewhere. This is the only
record of what's live where until we have an automated migration runner.

## Once a migration has run in production

It is **frozen**. Do not edit it. To change something it did, write a new
migration that reverses and re-applies.

## Applying

1. Supabase Dashboard -> SQL Editor
2. Paste the migration's content
3. Run
4. Update the `Applied to:` header in the file
5. Commit

## Index and apply order

| # | File | What it does |
|---|---|---|
| 0001 | `0001__role_grants.sql` | Grants every table, view and listed function to anon, authenticated and service_role (superseded by 0003 for anon/authenticated) |
| 0002 | `0002_clear_temp_password_on_activation.sql` | `activate_workspace` also clears `must_change_password` |
| 0003 | `0003_db_lockdown.sql` | Closes direct DB access. anon gets nothing. authenticated gets only column SELECT on the 10 `employees` and 5 `super_admins` columns the API reads, and RLS limits both tables to the caller's own row. Balance views become `security_invoker`; RLS on `plans`; drops `organizations_tenant_update`; revokes EXECUTE on every function except the RLS helpers `current_user_org_id()` and `is_super_admin()`; stops default grants to anon/authenticated on new objects |
| 0004 | `0004_drop_migration_backup.sql` | Drops the `migration_backup` schema (0003's rollback snapshot). Apply only after 0003 is verified on **every** database |

**Fresh install:** bootstrap (`docs/db/initialization-v2.1.sql`), then 0001,
0002, 0003, 0004. The bootstrap is deprecated and will be replaced by the new
baseline. Until then, 0003 is not folded into it, and its §26 still grants
everything to anon, so a fresh install is open until 0003 runs.

**Existing dev DB** (`jtmrrsiiqmemffyuasqd`, has 0001 + 0002): 0003, verify,
then 0004 once 0003 is verified everywhere.

**From 0003 on, new tables/functions get NO default grants. Every migration
must GRANT what it needs explicitly.** service_role still gets its Supabase
defaults in `public`. For the API's user client (`supabaseUser(jwt)`), grant
only the columns it reads and give the table an own-row or org RLS policy:

    GRANT SELECT (<col>, <col>) ON public.<table> TO authenticated;
    GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;  -- RLS helpers only

Never grant anything to `anon`, and never grant INSERT/UPDATE/DELETE to
`authenticated`. Writes go through the API (service role). A function that
`postgres` creates outside `public` gets no PUBLIC EXECUTE either, so grant
it to every role that calls it, service_role included.

## 0003: apply, verify, roll back

0003 has two companion files. Run all three as `postgres`. Each one wraps
itself in `BEGIN ... COMMIT` (verify: `ROLLBACK`).

1. **Apply** `0003_db_lockdown.sql`. On its first run it snapshots the
   current grants, policies and flags into `migration_backup.m0003_pre_lockdown`
   (locked: no access for PUBLIC, anon or authenticated). It then applies
   the lockdown, checks itself, and aborts everything if a check fails.
   Re-running it is safe and keeps the first snapshot. It fails closed: if an
   object in `public` is owned by a role other than `postgres` (e.g.
   `supabase_admin`), its grants can't be revoked, and the self-check aborts
   naming that object.
2. **Verify** with `0003_db_lockdown.verify.sql`, preferably with
   `psql "$DATABASE_URL" -f migrations/0003_db_lockdown.verify.sql` so every
   result prints. Part A queries each state their expected result. Part B
   ends in one table where every row must say `PASS` (or `SKIP` where the
   database has no matching data). It acts as `anon`, a real employee and a
   super admin (`set local role` + `request.jwt.claims`), and rolls
   everything back.
3. **Smoke-test the API** against that database: log in, then call
   `GET /api/auth/me` (runs `attachEmployee` and `attachSuperAdmin`, which
   read `employees` and `super_admins` with the user's JWT). Then deactivate
   that employee and call `/me` again with the same token: it should now
   return `ACCOUNT_DISABLED` (before 0003 the row was hidden instead).
4. **Update** the `Applied to:` header, then commit.
5. Once 0003 is verified on every database, apply **0004** everywhere.
   Re-running 0003 after 0004 recreates `migration_backup` (with a snapshot
   of the locked state); run 0004 again after it.

**Rollback** (only if the API breaks): run `0003_db_lockdown.rollback.sql`.
**0003 rollback is only valid immediately after applying 0003, before any
later migration.** It also needs the snapshot, so it can't run after 0004.
It restores the snapshot and checks the result against it, then drops it.
That covers:
- grants for anon, authenticated, PUBLIC and service_role
- default privileges
- view options
- the RLS flags on `plans`, `employees` and `super_admins`
- `organizations_tenant_update`, `employees_tenant_all` and `super_admins_self`

It also drops the own-row policies. This re-opens the audit's Critical
findings.
