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