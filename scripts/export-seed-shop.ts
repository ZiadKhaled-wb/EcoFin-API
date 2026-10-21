// M03 (D86): the first half of the restore check (docs/05-operations/export-restore.md).
//
//   tsx scripts/export-seed-shop.ts [organization id] [output .zip path]
//
// Runs a full export of one shop of the LOCAL stack exactly as the worker does (an import_jobs row of
// kind full_export, then the export.full handler: one snapshot, paging, zip, upload, registration),
// downloads the zip from storage and writes it to the output path. Needs the same environment as the
// integration tests (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, ...) and DATABASE_URL. The second half
// is `supabase db reset` followed by `node scripts/export-restore-check.mjs <zip>`.

import { writeFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { exportFull, pgSnapshot } from '../src/jobs/handlers/exportFull';
import { supabaseAdmin } from '../src/utils/supabase';

const org = process.argv[2] ?? 'd1000000-0000-0000-0000-000000000001';
const out = process.argv[3] ?? 'export-seed-shop.zip';
const databaseUrl = process.env['DATABASE_URL'];
if (!databaseUrl) throw new Error('DATABASE_URL is not set');
if (!/@(localhost|127\.0\.0\.1|\[::1\])[:/]/.test(databaseUrl)) {
  throw new Error('export-seed-shop only runs against a local database');
}

const owner = await supabaseAdmin
  .from('employees')
  .select('id')
  .eq('organization_id', org)
  .eq('role', 'OWNER')
  .limit(1)
  .single();
if (owner.error) throw new Error(owner.error.message);

const created = await supabaseAdmin
  .from('import_jobs')
  .insert({
    organization_id: org,
    kind: 'full_export',
    status: 'importing',
    dry_run: false,
    created_by: owner.data.id,
    report: { pii: 'full', idempotency_key: `seed-export-${randomUUID()}` },
  })
  .select('id')
  .single();
if (created.error) throw new Error(created.error.message);

const started = Date.now();
await exportFull({ db: supabaseAdmin, openSnapshot: pgSnapshot(databaseUrl) })(
  {
    id: randomUUID(),
    organizationId: org,
    type: 'export.full',
    payload: { export_job_id: created.data.id },
    attempt: 1,
    maxAttempts: 1,
  },
  pino({ level: 'info' }),
);

console.log(
  `export took ${((Date.now() - started) / 1000).toFixed(1)} s, peak memory ${Math.round(process.resourceUsage().maxRSS / 1024)} MB`,
);
const job = await supabaseAdmin
  .from('import_jobs')
  .select('status, result_file_id, rows_total, report')
  .eq('id', created.data.id)
  .single();
if (job.error || job.data.status !== 'completed' || !job.data.result_file_id) {
  throw new Error(`the export did not complete: ${JSON.stringify(job.data)}`);
}
const file = await supabaseAdmin
  .from('files')
  .select('path')
  .eq('id', job.data.result_file_id)
  .single();
if (file.error) throw new Error(file.error.message);
const blob = await supabaseAdmin.storage.from('tenant-files').download(file.data.path);
if (blob.error) throw new Error(blob.error.message);
writeFileSync(out, Buffer.from(await blob.data.arrayBuffer()));
console.log(`export written to ${out}: ${job.data.rows_total} rows`);
