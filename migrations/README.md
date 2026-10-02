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

Run in this order. Fresh installs run the bootstrap first: it already
contains 0001 and 0002, but **not** 0003, so they still need 0003.

| # | File | What it does |
|---|---|---|
| 0001 | `0001__role_grants.sql` | Grants every table, view and listed function to anon, authenticated and service_role (superseded by 0003 for anon/authenticated) |
| 0002 | `0002_clear_temp_password_on_activation.sql` | `activate_workspace` also clears `must_change_password` |
| 0003 | `0003_db_lockdown.sql` | Locks direct DB access: anon gets nothing; authenticated is read-only (RLS-scoped); balance views become `security_invoker`; RLS on `plans`; drops `organizations_tenant_update`; revokes EXECUTE on every function except the RLS helpers `current_user_org_id()` and `is_super_admin()`; stops default grants to anon/authenticated on new objects |

- Existing dev DB (`jtmrrsiiqmemffyuasqd`, has 0001 + 0002): run 0003.
- Fresh install: bootstrap, then 0003.

## 0003: apply, verify, roll back

0003 has two companion files. Run all three as `postgres`. Each one wraps
itself in `BEGIN ... COMMIT` (verify: `ROLLBACK`).

1. **Apply** `0003_db_lockdown.sql`. It snapshots the current grants and
   policy into `migration_backup.m0003_pre_lockdown` on its first run,
   applies the lockdown, then checks itself and aborts everything if a
   check fails. Re-running it is safe and keeps the first snapshot.
   It fails closed: if an object in `public` is owned by a role other than
   `postgres` (e.g. `supabase_admin`), its grants can't be revoked, and the
   self-check aborts naming that object.
2. **Verify** with `0003_db_lockdown.verify.sql`, preferably with
   `psql "$DATABASE_URL" -f migrations/0003_db_lockdown.verify.sql` so every
   result prints. Part A queries each state their expected result. Part B
   ends in one table where every row must say `PASS`. It acts as `anon` and
   as a real employee (`set local role` + `request.jwt.claims`) and rolls
   everything back.
3. **Smoke-test the API** against that database: log in, then call
   `GET /api/auth/me` (runs `attachEmployee` and `attachSuperAdmin`, which
   read `employees` and `super_admins` with the user's JWT).
4. **Update** the `Applied to:` header, then commit.

**Rollback** (only if the API breaks): run `0003_db_lockdown.rollback.sql`.
It restores the snapshot (grants for anon/authenticated/PUBLIC/service_role,
default privileges, view options, `plans` RLS flag and the
`organizations_tenant_update` policy), checks the result against the
snapshot, then drops it. This re-opens the audit's Critical findings. It
also resets grants that later migrations made on objects in the snapshot,
so run it before applying anything after 0003, or re-check those grants.

**After 0003, new objects are not exposed by default.** A migration that
adds a table the API reads through `supabaseUser(jwt)`, or a new function used
in an RLS policy, must grant it explicitly:

    GRANT SELECT ON public.<table> TO authenticated;
    GRANT EXECUTE ON FUNCTION public.<fn>(<args>) TO authenticated;

Never grant anything to `anon`, and never grant INSERT/UPDATE/DELETE to
`authenticated`. Writes go through the API (service role).
