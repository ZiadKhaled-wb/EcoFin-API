// F11 proof: 1,000 concurrent document creations get 1,000 unique, ordered, gap-free numbers.
// Runs against the LOCAL Supabase database container (never a hosted project), like db:smoke.
// Usage: npm run db:numbering   (after `npm run db:reset`; CI runs it in the db job)
//
// pgbench (shipped in the database image, so no new dependency) runs two loads at the same time
// on one branch's 'sale' counter:
//   - COMMITS clients x 1,000/COMMITS transactions that each take a number and store it, like a
//     write function does (number and document in one transaction), then commit;
//   - ROLLBACK_CLIENTS clients that take numbers and roll back (failed documents).
// Then it checks: exactly 1,000 numbers, all distinct, exactly 000001..001000 (the rolled-back
// ones were handed out again: no gaps), in the order they were handed out, and the counter is at
// 1,001. Leaves nothing behind (scratch schema and fixture shop are removed).
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('..', import.meta.url));
const TOTAL = 1000;
const COMMIT_CLIENTS = Number(process.env.F11_CLIENTS ?? 40); // max_connections is 100 locally
const ROLLBACK_CLIENTS = 8;
const ROLLBACKS_PER_CLIENT = 50;

const ORG = 'f1150000-0000-0000-0000-0000000000f1';
const BRANCH = 'f1150000-0000-0000-0000-0000000000b1';

function dbContainer() {
  if (process.env.SUPABASE_DB_CONTAINER) return process.env.SUPABASE_DB_CONTAINER;
  const config = readFileSync(`${root}supabase/config.toml`, 'utf8');
  const projectId = /^project_id\s*=\s*"([^"]+)"/m.exec(config)?.[1];
  if (!projectId) throw new Error('project_id not found in supabase/config.toml');
  return `supabase_db_${projectId}`;
}
const container = dbContainer();

function psql(sql) {
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

function writeFile(path, content) {
  const run = spawnSync('docker', ['exec', '-i', container, 'sh', '-c', `cat > ${path}`], {
    input: content,
    encoding: 'utf8',
  });
  if (run.status !== 0) throw new Error(`could not write ${path}: ${run.stderr}`);
}

function pgbench(script, clients, transactions) {
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

// Shops, branches and counters are never deleted (baseline NO_DELETE triggers). The fixture is a
// throwaway on the local stack, so the cleanup turns triggers off for its own transaction only
// (superuser, local) and removes exactly the three rows the setup created.
const cleanup = `
  DROP SCHEMA IF EXISTS f11_proof CASCADE;
  BEGIN;
  SET LOCAL session_replication_role = replica;
  DELETE FROM public.document_counters WHERE organization_id = '${ORG}';
  DELETE FROM public.branches WHERE id = '${BRANCH}' AND organization_id = '${ORG}';
  DELETE FROM public.organizations WHERE id = '${ORG}';
  COMMIT;
`;

let failed = false;
try {
  if (TOTAL % COMMIT_CLIENTS !== 0) throw new Error(`F11_CLIENTS must divide ${TOTAL}`);
  psql(`${cleanup}
    CREATE SCHEMA f11_proof;
    CREATE TABLE f11_proof.numbers (
      number  text NOT NULL,
      got_at  timestamptz NOT NULL,
      backend integer NOT NULL DEFAULT pg_backend_pid()
    );
    INSERT INTO public.organizations (id, tenant_slug, name, plan_key, status)
    VALUES ('${ORG}', 'f11-proof', 'F11 numbering proof', 'retail', 'active');
    INSERT INTO public.branches (id, organization_id, code, name, is_main)
    VALUES ('${BRANCH}', '${ORG}', 'PRF', 'Proof branch', true);`);

  writeFile(
    '/tmp/f11_commit.sql',
    // The time is read AFTER the number came back (OFFSET 0 keeps the subquery a separate step):
    // a column default could be evaluated before the call waits for the counter lock.
    `BEGIN;
INSERT INTO f11_proof.numbers (number, got_at) SELECT x.number, clock_timestamp() FROM (SELECT app.next_document_number('${ORG}', '${BRANCH}', 'sale') AS number OFFSET 0) x;
COMMIT;
`,
  );
  writeFile(
    '/tmp/f11_rollback.sql',
    `BEGIN;
SELECT app.next_document_number('${ORG}', '${BRANCH}', 'sale');
ROLLBACK;
`,
  );

  const started = Date.now();
  const [commits, rollbacks] = await Promise.all([
    pgbench('/tmp/f11_commit.sql', COMMIT_CLIENTS, TOTAL / COMMIT_CLIENTS),
    pgbench('/tmp/f11_rollback.sql', ROLLBACK_CLIENTS, ROLLBACKS_PER_CLIENT),
  ]);
  const processed = (out) => /number of transactions actually processed: (\d+)/.exec(out)?.[1];
  console.log(
    `pgbench: ${processed(commits)} committed documents (${COMMIT_CLIENTS} clients) and ` +
      `${processed(rollbacks)} rolled-back ones (${ROLLBACK_CLIENTS} clients) in ${Date.now() - started} ms`,
  );

  const [total, distinct, first, last, shaped, ordered, backends, nextValue] = psql(`
    WITH n AS (SELECT number, got_at, right(number, 6)::integer AS seq FROM f11_proof.numbers),
         o AS (SELECT seq, lag(seq) OVER (ORDER BY got_at, seq) AS prev FROM n)
    SELECT concat_ws('|',
      (SELECT count(*) FROM n),
      (SELECT count(DISTINCT number) FROM n),
      (SELECT min(seq) FROM n),
      (SELECT max(seq) FROM n),
      (SELECT bool_and(number ~ '^PRF-SL-[0-9]{2}-[0-9]{6}$') FROM n),
      (SELECT bool_and(prev IS NULL OR seq = prev + 1) FROM o),
      (SELECT count(DISTINCT backend) FROM f11_proof.numbers),
      (SELECT next_value FROM public.document_counters
        WHERE organization_id = '${ORG}' AND branch_id = '${BRANCH}' AND doc_type = 'sale'));`).split(
    '|',
  );

  const checks = [
    [`${TOTAL} documents committed`, Number(total) === TOTAL, total],
    [`${TOTAL} unique numbers`, Number(distinct) === TOTAL, distinct],
    [
      `numbers are exactly 000001..${String(TOTAL).padStart(6, '0')} (no gaps)`,
      first === '1' && last === String(TOTAL),
      `${first}..${last}`,
    ],
    ['every number has the PRF-SL-<yy>-<6 digits> shape', shaped === 't', shaped],
    [
      'numbers are in the order they were handed out (each one = previous + 1)',
      ordered === 't',
      ordered,
    ],
    [`the counter is at ${TOTAL + 1}`, Number(nextValue) === TOTAL + 1, nextValue],
    [
      'the documents came from many concurrent sessions',
      Number(backends) >= Math.min(COMMIT_CLIENTS, 10),
      `${backends} sessions`,
    ],
  ];
  for (const [name, ok, detail] of checks) {
    console.log(`${ok ? 'ok  ' : 'FAIL'} ${name} (${detail})`);
    if (!ok) failed = true;
  }
} catch (error) {
  console.error(`db:numbering: ${error.message}`);
  failed = true;
} finally {
  try {
    psql(cleanup);
  } catch (error) {
    console.error(`db:numbering: cleanup failed: ${error.message}`);
    failed = true;
  }
}

console.log(failed ? 'db:numbering: FAILED' : 'db:numbering: passed');
process.exit(failed ? 1 : 0);
