# Full export: what it is, how to take it, how to prove it restores (M03, D86)

## What the owner gets

**Settings → Export data** (`export.data`: owner and accountant; it also works when the subscription
has expired, it is the way out of the system). One click starts a background job; a little later
the page shows **Download**. The file is one zip, `ecofin-export-{shop}-{YYYYMMDD-HHmm}.zip`:

| Entry | What it is |
|---|---|
| `csv/{table}.csv` | one file per table, UTF-8 **with a BOM** (Arabic opens correctly in Excel), CRLF lines. A text cell that starts with `=`, `+`, `-` or `@` gets a `'` in front so Excel never runs it; plain numbers are left alone; an empty cell is NULL; jsonb and array columns are compact JSON text |
| `json/{table}.json` | the same rows as a JSON array, values exactly as the database holds them |
| `manifest.json` | format version, the shop, who exported and when, the latest migration and contracts version, rows and columns of every table, and the **control totals** |
| `README.txt` | Arabic and English: what each folder is |

Every table of the shop is in it (every `public` table with `organization_id`, plus the shop row)
except the ones listed with a reason in `app.export_excluded_tables()` (the job queue, password
resets, the nightly day checks, the number counters). Secret columns (token hashes, vault ids,
pairing codes) are never exported (`app.export_excluded_columns()`). National IDs are **masked**
(`**********1234`) unless the requester asked for the full export and also holds
`customer.view_pii`; a full export is audited at warning. File binaries (logos, ID photos) are not
in the zip: the `files` table lists their records.

Limits: 500 MB of CSV and JSON together, 2 million rows (otherwise the export fails with
`EXPORT_TOO_LARGE` and the numbers), one running export per shop, one per hour after a completed
one. The zip stays in storage for 7 days (the daily `export.cleanup` job removes it; the `files`
row stays with `deleted_at`).

## Control totals (the numbers a restore must reproduce)

Computed by the database in the same snapshot as the rows (`app.export_totals`):
`cash_balance_total`, `stock_on_hand_total`, `store_credit_total`, `open_contracts_remaining` (the
`remaining` of `v_contract_balances` for active and rescheduled contracts), `sales_total`,
`payments_in_total`, `payments_out_total`, `audit_rows`.

## The restore check (Q04's tool, not a product feature)

`scripts/export-restore-check.mjs <zip>` loads the `csv/` files into a **clean local** database
and compares. It refuses any database that is not on `localhost` / `127.0.0.1` / `::1`.

```bash
# 1. a local stack with the seed shops
npx supabase start && npx supabase db reset

# 2. take the export of the seed shop exactly as the worker does (needs the same env as the integration
#    tests plus DATABASE_URL = the local Postgres)
npx tsx scripts/export-seed-shop.ts d1000000-0000-0000-0000-000000000001 /tmp/export.zip

# 3. wipe the database WITHOUT the seed (so the shop is gone), then restore the zip into it and compare
npx supabase db reset --no-seed
node scripts/export-restore-check.mjs /tmp/export.zip
```

What it does: reads `manifest.json`; orders the tables by their foreign keys; with
`session_replication_role = replica` (no triggers, so nothing is re-posted into a ledger) inserts
every CSV (the `'` guard removed, an empty cell back to NULL, a NOT NULL text column that was
excluded as a secret comes back as an empty string); then counts every table and recomputes the
totals with the same SQL (`app.export_totals`). It prints, table by table, `expected` and `found`,
then each total, and exits **0 only when every number is equal**, 1 on any difference. By default
it rolls everything back at the end (`--keep` commits). The database must not have the shop yet
(otherwise it refuses: restore into a reset database).

CI runs steps 2 and 3 in the database job (see `.github/workflows/ci.yml`, "M03 restore check").

## Operations

* `DATABASE_URL` (the API's secret file on the VM) is a direct Postgres connection string. The
  export holds one `REPEATABLE READ READ ONLY` transaction for the whole read, which PostgREST
  cannot do. On Supabase use the direct connection or the pooler in **session** mode (port 5432),
  not transaction mode. Without it the export job fails with a clear log line and nothing else is
  affected.
* The bucket limit of `tenant-files` was raised from 10 MB to 500 MB by the migration. A hosted
  Supabase project also has a **global** upload limit (Project settings → Storage); it must be at
  least as big as the biggest export you expect (the zip is compressed, usually a fifth of the
  uncompressed size).
* A failed export shows its code on the screen (`EXPORT_TOO_LARGE`, `EXPORT_PERMISSION_LOST` when
  the requester lost the right meanwhile, `EXPORT_SHOP_NOT_ACTIVE`, `EXPORT_FAILED`); the log line
  `export.full: failed` has the details and is at error level.
* Re-running a stuck export: cancel it (`POST /api/exports/:id/cancel`) and start a new one.
