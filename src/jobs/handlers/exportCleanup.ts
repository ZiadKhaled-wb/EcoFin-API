// server/src/jobs/handlers/exportCleanup.ts
//
// Daily 'export.cleanup' (M03, D86): removes the zips of full exports older than EXPORT_LIMITS.keepDays
// from storage and marks their files rows deleted (the rows stay: rows of public.files are never
// deleted). Safe to run twice: a zip that is already gone is not listed again, and an object that is
// missing from storage counts as removed.

import type { SupabaseClient } from '@supabase/supabase-js';
import { z } from 'zod';
import { EXPORT_LIMITS } from '@ziadkhaled-wb/contracts';
import * as storage from '../../services/storage.service';
import type { JobHandler } from '../types';

const Listed = z.array(z.object({ file_id: z.string().uuid(), path: z.string() }));

export function exportCleanup(db: SupabaseClient): JobHandler {
  return async (job, log) => {
    if (!job.organizationId) throw new Error('export.cleanup needs a shop');
    const { data, error } = await db.rpc('jobs_export_cleanup_list', {
      p_org: job.organizationId,
      p_keep_days: EXPORT_LIMITS.keepDays,
    });
    if (error) throw new Error(`jobs_export_cleanup_list failed: ${error.message}`);
    const files = Listed.parse(data);
    const removed: string[] = [];
    for (const file of files) {
      // The path must be the shop's own before anything is deleted.
      if (!file.path.startsWith(`${job.organizationId}/`)) {
        log.error({ fileId: file.file_id }, 'export.cleanup: path outside the shop, left alone');
        continue;
      }
      if (await storage.removeObject(file.path)) removed.push(file.file_id);
    }
    if (removed.length > 0) {
      const done = await db.rpc('jobs_export_cleanup_done', {
        p_org: job.organizationId,
        p_file_ids: removed,
      });
      if (done.error) throw new Error(`jobs_export_cleanup_done failed: ${done.error.message}`);
    }
    log.info({ listed: files.length, removed: removed.length }, 'export.cleanup: finished');
  };
}
