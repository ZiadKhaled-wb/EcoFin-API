// Runs supabase/tests/smoke_test.sql against the local Supabase database container and
// fails (exit 1) unless every check passes. Works on Windows, macOS, Linux and in CI.
// Usage: npm run db:smoke [-- <path to another .sql file>]
// The file runs inside BEGIN ... ROLLBACK, so it leaves no test shops behind and can be
// run again without a reset. No host psql needed: it uses `docker exec <db container> psql`.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';

const root = fileURLToPath(new URL('..', import.meta.url));
const sqlFile = process.argv[2] ?? `${root}supabase/tests/smoke_test.sql`;

function dbContainer() {
  if (process.env.SUPABASE_DB_CONTAINER) return process.env.SUPABASE_DB_CONTAINER;
  const config = readFileSync(`${root}supabase/config.toml`, 'utf8');
  const projectId = /^project_id\s*=\s*"([^"]+)"/m.exec(config)?.[1];
  if (!projectId) throw new Error('project_id not found in supabase/config.toml');
  return `supabase_db_${projectId}`;
}

const container = dbContainer();
// A Windows UTF-8 BOM is not SQL whitespace after the BEGIN wrapper.
function readSql(path, ancestors = []) {
  const absolute = resolve(path);
  if (ancestors.includes(absolute)) throw new Error('Circular SQL fixture include: ' + absolute);
  return readFileSync(absolute, 'utf8')
    .replace(/^\uFEFF/, '')
    .replace(/^\\ir\s+([^\r\n]+)\s*$/gm, (_, relative) =>
      readSql(resolve(dirname(absolute), relative.trim()), [...ancestors, absolute]),
    );
}
const sql = readSql(sqlFile);
const run = spawnSync(
  'docker',
  [
    'exec',
    '-i',
    container,
    'psql',
    '-X',
    '-U',
    'postgres',
    '-d',
    'postgres',
    '-v',
    'ON_ERROR_STOP=1',
  ],
  { input: `BEGIN;\n${sql}\nROLLBACK;\n`, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 },
);

process.stdout.write(run.stdout ?? '');
process.stderr.write(run.stderr ?? '');

if (run.error) {
  console.error(`db:smoke: could not run docker (${run.error.message})`);
  process.exit(1);
}
if (run.status !== 0) {
  console.error(`db:smoke: psql exited with ${run.status} (is ${container} running?)`);
  process.exit(1);
}

const counts = /passed\s*\|\s*failed\s*\n[-+\s]+\n\s*(\d+)\s*\|\s*(\d+)/.exec(run.stdout ?? '');
if (!counts) {
  console.error('db:smoke: could not find the "passed | failed" result line');
  process.exit(1);
}
const passed = Number(counts[1]);
const failed = Number(counts[2]);
console.log(`passed ${passed}, failed ${failed}`);
process.exit(failed === 0 && passed > 0 ? 0 : 1);
