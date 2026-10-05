// scripts/files-orphan-report.ts  (run: npx tsx scripts/files-orphan-report.ts)
//
// F14 (D36): lists storage objects in tenant-files that are at least 24 hours old and have no
// public.files row. REPORT ONLY: nothing is deleted. Needs the service-role key in the env
// (src/utils/env.ts); it reads the bucket and the files table, nothing else.
// Wiring it into the job runner (F13 is merged) is a follow-up, not part of this script.

import { findOrphans } from '../src/services/files.rules';
import { listStoredObjects } from '../src/services/storage.service';
import { supabaseAdmin } from '../src/utils/supabase';

const PAGE = 1000;

const objects = await listStoredObjects();

const known = new Set<string>();
for (let from = 0; ; from += PAGE) {
  const { data, error } = await supabaseAdmin
    .from('files')
    .select('path')
    .eq('bucket', 'tenant-files')
    .range(from, from + PAGE - 1);
  if (error) {
    console.error('files orphan report: could not read the files table.');
    process.exitCode = 1;
    throw new Error('files read failed');
  }
  for (const row of data) known.add(row.path);
  if (data.length < PAGE) break;
}

const orphans = findOrphans(objects, known, new Date());
console.log(
  `files orphan report: ${objects.length} objects, ${known.size} file rows, ` +
    `${orphans.length} objects older than 24 h with no row (report only, nothing deleted)`,
);
for (const path of orphans) console.log(path);
