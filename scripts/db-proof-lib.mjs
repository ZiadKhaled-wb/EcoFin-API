// Shared helpers for the database concurrency proofs (db:numbering F11, db:ledger F10).
// Everything runs inside the LOCAL Supabase database container through `docker exec`, like
// db:smoke: psql for setup and checks, pgbench (shipped in the database image) for parallel load.
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));

function dbContainer() {
  if (process.env.SUPABASE_DB_CONTAINER) return process.env.SUPABASE_DB_CONTAINER;
  const config = readFileSync(`${root}supabase/config.toml`, 'utf8');
  const projectId = /^project_id\s*=\s*"([^"]+)"/m.exec(config)?.[1];
  if (!projectId) throw new Error('project_id not found in supabase/config.toml');
  return `supabase_db_${projectId}`;
}

export const container = dbContainer();

/** Runs SQL as postgres and returns the unaligned, tuples-only output. Throws on any error. */
export function psql(sql) {
  const run = spawnSync(
    'docker',
    [
      'exec',
      '-i',
      container,
      'psql',
      '-X',
      '-q',
      '-At',
      '-U',
      'postgres',
      '-d',
      'postgres',
      '-v',
      'ON_ERROR_STOP=1',
    ],
    { input: sql, encoding: 'utf8' },
  );
  if (run.error) throw new Error(`could not run docker (${run.error.message})`);
  if (run.status !== 0) throw new Error(`psql failed (is ${container} running?)\n${run.stderr}`);
  return run.stdout.trim();
}

/** Writes a pgbench script file inside the container. */
export function writeFile(path, content) {
  const run = spawnSync('docker', ['exec', '-i', container, 'sh', '-c', `cat > ${path}`], {
    input: content,
    encoding: 'utf8',
  });
  if (run.status !== 0) throw new Error(`could not write ${path}: ${run.stderr}`);
}

/** `clients` sessions each run `script` `transactions` times, all at once. Resolves with pgbench's output. */
export function pgbench(script, clients, transactions) {
  return new Promise((resolve, reject) => {
    const args = ['exec', container, 'pgbench', '-n', '-U', 'postgres', '-d', 'postgres'];
    args.push(
      '-c',
      String(clients),
      '-j',
      String(Math.min(clients, 8)),
      '-t',
      String(transactions),
      '-f',
      script,
    );
    const child = spawn('docker', args);
    let out = '';
    child.stdout.on('data', (d) => (out += d));
    child.stderr.on('data', (d) => (out += d));
    child.on('error', reject);
    child.on('close', (code) =>
      code === 0 ? resolve(out) : reject(new Error(`pgbench ${script} exited ${code}\n${out}`)),
    );
  });
}

/** Transactions pgbench says it completed. */
export const processed = (out) => /number of transactions actually processed: (\d+)/.exec(out)?.[1];

/**
 * Removes a throwaway proof shop and everything it owns, plus a scratch schema. Shops, branches,
 * counters, balances and ledgers are never deleted in the app (NO_DELETE / APPEND_ONLY triggers),
 * so this turns triggers off for its own transaction only (superuser, local stack only) and
 * deletes every public row with that organization_id.
 */
export function removeProofShop(organizationId, schema) {
  psql(`
    DROP SCHEMA IF EXISTS ${schema} CASCADE;
    BEGIN;
    SET LOCAL session_replication_role = replica;
    DO $$
    DECLARE r record;
    BEGIN
      FOR r IN SELECT c.table_name FROM information_schema.columns c
               JOIN information_schema.tables t USING (table_schema, table_name)
               WHERE c.table_schema = 'public' AND c.column_name = 'organization_id' AND t.table_type = 'BASE TABLE'
      LOOP
        EXECUTE format('DELETE FROM public.%I WHERE organization_id = %L', r.table_name, '${organizationId}');
      END LOOP;
    END $$;
    DELETE FROM public.organizations WHERE id = '${organizationId}';
    COMMIT;`);
}

/** Prints each [name, ok, detail] check; returns true when all passed. */
export function report(checks) {
  let allOk = true;
  for (const [name, ok, detail] of checks) {
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name} (${detail})`);
    if (!ok) allOk = false;
  }
  return allOk;
}
