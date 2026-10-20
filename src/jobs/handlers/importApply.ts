// server/src/jobs/handlers/importApply.ts
//
// 'import.apply' (M01, D83): the import itself, queued by public.queue_import. The worker reads
// the stored file again (the dry run kept the sheet and the header mapping it used), turns it into
// the same rows, and hands them to public.jobs_import_apply, which re-checks every row and writes
// all of them in ONE transaction or none. Safe to run twice: a job that is not 'importing' any more
// does nothing. A failed run writes its errors as a CSV (purpose export) linked to the job. If every
// attempt fails outside the database (the file can't be read), the last one marks the job failed so
// the screen never waits for ever.

import { randomUUID } from 'node:crypto';
import type { SupabaseClient } from '@supabase/supabase-js';
import { ImportKind, ImportMapping, ImportRowError } from '@ziadkhaled-wb/contracts';
import { z } from 'zod';
import { sha256Hex } from '../../services/files.rules';
import { buildErrorsCsv } from '../../services/imports/files';
import { readImportTable, toFieldRows } from '../../services/imports/parse';
import * as storage from '../../services/storage.service';
import type { JobHandler } from '../types';

const Prepared = z.object({
  organization_id: z.string().uuid(),
  kind: ImportKind,
  status: z.string(),
  branch_id: z.string().uuid().nullable(),
  rows_total: z.number().int(),
  sheet: z.string().nullable(),
  mapping: ImportMapping,
  file_path: z.string().nullable(),
  file_sha256: z.string().nullable(),
});

const Applied = z.object({
  status: z.string(),
  changed: z.boolean(),
  errors: z.array(ImportRowError).optional(),
});

async function call(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn} failed: ${error.message}`);
  return data;
}

export function importApply(db: SupabaseClient): JobHandler {
  return async (job, log) => {
    const importJobId = z.string().uuid().parse(job.payload['import_job_id']);
    try {
      const prepared = Prepared.parse(
        await call(db, 'jobs_import_prepare', { p_job_id: importJobId }),
      );
      if (prepared.status !== 'importing') {
        log.info({ importJobId, status: prepared.status }, 'import.apply: nothing to do');
        return;
      }
      if (prepared.file_path === null) throw new Error('the import file is missing');
      // The job's own shop owns the file: the path must start with the shop id.
      if (!prepared.file_path.startsWith(`${prepared.organization_id}/`)) {
        throw new Error('the import file is outside the shop');
      }
      const bytes = await storage.getObject(prepared.file_path);
      if (prepared.file_sha256 !== null && prepared.file_sha256.trim() !== sha256Hex(bytes)) {
        throw new Error('the import file changed');
      }
      const table = await readImportTable(bytes, { sheet: prepared.sheet ?? undefined });
      const rows = toFieldRows(prepared.kind, table, prepared.mapping);
      const result = Applied.parse(
        await call(db, 'jobs_import_apply', { p_job_id: importJobId, p_rows: rows }),
      );
      log.info(
        { importJobId, status: result.status, changed: result.changed },
        'import.apply: finished',
      );
      if (result.status === 'failed' && result.changed && (result.errors?.length ?? 0) > 0) {
        await attachErrors(db, prepared.organization_id, importJobId, result.errors ?? []);
      }
    } catch (error) {
      if (job.attempt >= job.maxAttempts) {
        await call(db, 'jobs_import_fail', {
          p_job_id: importJobId,
          p_reason: 'The import could not run. Upload the file again.',
        }).catch((e: unknown) =>
          log.error({ err: e, importJobId }, 'import.apply: could not mark failed'),
        );
      }
      throw error;
    }
  };
}

async function attachErrors(
  db: SupabaseClient,
  orgId: string,
  importJobId: string,
  errors: readonly ImportRowError[],
): Promise<void> {
  const csv = buildErrorsCsv(errors);
  const id = randomUUID();
  const now = new Date();
  const path = `${orgId}/export/${now.getUTCFullYear()}/${String(now.getUTCMonth() + 1).padStart(2, '0')}/${id}.csv`;
  await storage.putObject(path, csv, 'text/csv');
  try {
    await call(db, 'jobs_import_attach_result', {
      p_job_id: importJobId,
      p_file_id: id,
      p_path: path,
      p_original_name: `import-errors-${importJobId.slice(0, 8)}.csv`,
      p_mime: 'text/csv',
      p_size_bytes: csv.length,
      p_sha256: sha256Hex(csv),
    });
  } catch (error) {
    await storage.removeObject(path);
    throw error;
  }
}
