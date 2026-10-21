// M03 (D86), decision 10: the restore check, Q04's tool (not a product feature).
//
//   node scripts/export-restore-check.mjs <export.zip> [--db-url <postgres url>] [--keep]
//
// Loads the `csv/` files of a full export into a CLEAN LOCAL Supabase database (the same schema, no
// rows of that shop), in foreign-key order, with `session_replication_role = replica` (no triggers:
// nothing is re-posted into a ledger), then recomputes the manifest's control totals with the same
// SQL (app.export_totals) and counts every table. Prints table by table `expected` and `found`, and
// the totals. Exit 0 when every number is equal, 1 on any difference (or a refusal).
//
// It refuses any database that is not on localhost / 127.0.0.1 / ::1. By default everything runs in
// one transaction that is rolled back at the end; `--keep` commits it.
//
// The pure parts (readZip, parseCsv, unguardCell) are exported for the tests.

import { readFileSync } from 'node:fs';
import { inflateRawSync } from 'node:zlib';
import { pathToFileURL } from 'node:url';

// --------------------------------------------------------------------------- zip (read only)

/** Every entry of a zip file as { name: Buffer }. Stored and deflated entries; no zip64. */
export function readZip(buffer) {
  let eocd = -1;
  for (let i = buffer.length - 22; i >= Math.max(0, buffer.length - 65557); i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('not a zip file (no end of central directory)');
  const count = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  const entries = {};
  for (let n = 0; n < count; n += 1) {
    if (buffer.readUInt32LE(offset) !== 0x02014b50) throw new Error('bad central directory');
    const method = buffer.readUInt16LE(offset + 10);
    const compressed = buffer.readUInt32LE(offset + 20);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const local = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString('utf8', offset + 46, offset + 46 + nameLength);
    offset += 46 + nameLength + extraLength + commentLength;
    if (buffer.readUInt32LE(local) !== 0x04034b50) throw new Error(`bad local header for ${name}`);
    const start = local + 30 + buffer.readUInt16LE(local + 26) + buffer.readUInt16LE(local + 28);
    const data = buffer.subarray(start, start + compressed);
    if (method === 0) entries[name] = Buffer.from(data);
    else if (method === 8) entries[name] = inflateRawSync(data);
    else throw new Error(`${name}: unsupported compression method ${method}`);
  }
  return entries;
}

// --------------------------------------------------------------------------- csv

/** RFC 4180: quoted cells, doubled quotes, CRLF or LF; a leading BOM is dropped. Returns string[][]. */
export function parseCsv(text) {
  const source = text.charCodeAt(0) === 0xfeff ? text.slice(1) : text;
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < source.length; i += 1) {
    const c = source[i];
    if (quoted) {
      if (c === '"') {
        if (source[i + 1] === '"') {
          cell += '"';
          i += 1;
        } else quoted = false;
      } else cell += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') {
      row.push(cell);
      cell = '';
    } else if (c === '\n' || c === '\r') {
      if (c === '\r' && source[i + 1] === '\n') i += 1;
      row.push(cell);
      rows.push(row);
      row = [];
      cell = '';
    } else cell += c;
  }
  if (cell !== '' || row.length > 0) {
    row.push(cell);
    rows.push(row);
  }
  return rows;
}

/** The export puts a ' in front of a text cell that starts with = + - @ tab or CR. Takes it off. */
export function unguardCell(value) {
  return /^'[=+\-@\t\r]/.test(value) ? value.slice(1) : value;
}

// --------------------------------------------------------------------------- main

const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]']);

function fail(message) {
  console.error(`export-restore-check: ${message}`);
  process.exit(1);
}

async function main() {
  const args = process.argv.slice(2);
  const zipPath = args.find((a) => !a.startsWith('--') && args[args.indexOf(a) - 1] !== '--db-url');
  const dbUrl =
    args[args.indexOf('--db-url') + 1] && args.includes('--db-url')
      ? args[args.indexOf('--db-url') + 1]
      : (process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres');
  const keep = args.includes('--keep');
  if (!zipPath)
    fail('usage: node scripts/export-restore-check.mjs <export.zip> [--db-url <url>] [--keep]');

  const host = new URL(dbUrl).hostname;
  if (!LOCAL_HOSTS.has(host)) {
    fail(
      `refusing ${host}: the restore check only runs on a local database (localhost / 127.0.0.1)`,
    );
  }

  const { default: pg } = await import('pg');
  const { ExportManifest } = await import('@ziadkhaled-wb/contracts');
  const entries = readZip(readFileSync(zipPath));
  if (!entries['manifest.json']) fail('manifest.json is missing from the zip');
  const manifest = ExportManifest.parse(JSON.parse(entries['manifest.json'].toString('utf8')));
  const orgId = manifest.shop.id;

  const client = new pg.Client({
    connectionString: dbUrl,
    application_name: 'ecofin-restore-check',
  });
  await client.connect();
  let ok = true;
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL session_replication_role = replica');
    await client.query("SET LOCAL TIME ZONE 'UTC'");

    // Foreign-key order: a table after the tables it points to (self references ignored).
    const fks = (
      await client.query(
        `SELECT c.conrelid::regclass::text AS child, c.confrelid::regclass::text AS parent
         FROM pg_constraint c WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace`,
      )
    ).rows;
    const names = manifest.tables.map((t) => t.name);
    const deps = new Map(names.map((n) => [n, new Set()]));
    for (const { child, parent } of fks) {
      const c = child.replace(/^public\./, '').replaceAll('"', '');
      const p = parent.replace(/^public\./, '').replaceAll('"', '');
      if (c !== p && deps.has(c) && deps.has(p)) deps.get(c).add(p);
    }
    const order = [];
    const done = new Set();
    while (order.length < names.length) {
      const next = names.filter((n) => !done.has(n) && [...deps.get(n)].every((d) => done.has(d)));
      if (next.length === 0) next.push(...names.filter((n) => !done.has(n)).slice(0, 1)); // a cycle
      for (const n of next) {
        done.add(n);
        order.push(n);
      }
    }

    // The target must hold nothing of this shop yet.
    const existing = (
      await client.query('SELECT 1 FROM public.organizations WHERE id = $1', [orgId])
    ).rowCount;
    if (existing)
      fail(`the database already has shop ${orgId}: restore into a clean (reset) database`);

    for (const name of order) {
      const csv = entries[`csv/${name}.csv`];
      if (!csv) fail(`csv/${name}.csv is missing from the zip`);
      const rows = parseCsv(csv.toString('utf8'));
      const header = rows.shift() ?? [];
      const meta = (
        await client.query(
          `SELECT a.attname AS name, a.attnotnull AS not_null, t.typname AS type, t.typcategory AS category,
                  a.attgenerated <> '' AS generated, a.atthasdef AS has_default
           FROM pg_attribute a JOIN pg_type t ON t.oid = a.atttypid
           WHERE a.attrelid = ('public.' || quote_ident($1))::regclass AND a.attnum > 0 AND NOT a.attisdropped`,
          [name],
        )
      ).rows;
      const byName = new Map(meta.map((m) => [m.name, m]));
      for (const h of header)
        if (!byName.has(h)) fail(`${name}: column ${h} does not exist in this database`);
      // Excluded secret columns come back empty; a NOT NULL text one without a default gets ''.
      const filler = meta.filter(
        (m) => !header.includes(m.name) && !m.generated && m.not_null && !m.has_default,
      );
      for (const m of filler) {
        if (m.category !== 'S')
          fail(`${name}.${m.name} is NOT NULL, not exported and not text: cannot restore`);
      }
      // Generated columns (amount = principal + profit) are computed by the database.
      const generated = new Set(meta.filter((m) => m.generated).map((m) => m.name));
      const objects = rows.map((cells) => {
        const o = {};
        header.forEach((h, i) => {
          if (generated.has(h)) return;
          const m = byName.get(h);
          const raw = unguardCell(cells[i] ?? '');
          if (raw === '' && !(m.not_null && m.category === 'S')) o[h] = null;
          else if (m.type === 'jsonb' || m.category === 'A')
            o[h] = raw === '' ? null : JSON.parse(raw);
          else o[h] = raw;
        });
        for (const m of filler) o[m.name] = '';
        return o;
      });
      const cols = [...header.filter((h) => !generated.has(h)), ...filler.map((m) => m.name)];
      const list = cols.map((c) => `"${c}"`).join(', ');
      for (let i = 0; i < objects.length; i += 2000) {
        await client.query(
          `INSERT INTO public."${name}" (${list}) OVERRIDING SYSTEM VALUE
           SELECT ${list} FROM jsonb_populate_recordset(null::public."${name}", $1::jsonb)`,
          [JSON.stringify(objects.slice(i, i + 2000))],
        );
      }
    }

    // Counts and totals, with the same SQL as the export.
    console.log('table'.padEnd(36), 'expected'.padStart(9), 'found'.padStart(9));
    for (const t of manifest.tables) {
      const filter = t.name === 'organizations' ? 'id = $1' : 'organization_id = $1';
      const { rows } = await client.query(
        `SELECT count(*)::bigint AS n FROM public."${t.name}" WHERE ${filter}`,
        [orgId],
      );
      const found = Number(rows[0].n);
      const same = found === t.rows;
      if (!same) ok = false;
      console.log(
        t.name.padEnd(36),
        String(t.rows).padStart(9),
        String(found).padStart(9),
        same ? '' : '  <-- DIFFERENT',
      );
    }
    const found = (await client.query('SELECT app.export_totals($1::uuid) AS v', [orgId])).rows[0]
      .v;
    console.log('\ntotal'.padEnd(37), 'expected'.padStart(20), 'found'.padStart(20));
    for (const [key, expected] of Object.entries(manifest.totals)) {
      const got = String(found[key]);
      const same = got === String(expected);
      if (!same) ok = false;
      console.log(
        key.padEnd(36),
        String(expected).padStart(20),
        got.padStart(20),
        same ? '' : '  <-- DIFFERENT',
      );
    }
    await client.query(keep && ok ? 'COMMIT' : 'ROLLBACK');
  } catch (error) {
    await client.query('ROLLBACK').catch(() => undefined);
    console.error(
      `export-restore-check: ${error instanceof Error ? error.message : String(error)}`,
    );
    ok = false;
  } finally {
    await client.end();
  }
  console.log(ok ? '\nRESTORE CHECK PASSED: expected = found.' : '\nRESTORE CHECK FAILED.');
  process.exit(ok ? 0 : 1);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  await main();
}
