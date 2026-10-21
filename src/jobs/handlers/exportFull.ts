// server/src/jobs/handlers/exportFull.ts
//
// 'export.full' (M03, D86): the full export of one shop, queued by public.start_full_export.
//   1. jobs_export_prepare: the tables, columns and key columns, the requester re-checked. A job
//      that is not 'importing' any more does nothing, so a retried queue entry is harmless.
//   2. ONE read-only REPEATABLE READ transaction on a direct Postgres connection: the row counts and
//      the control totals first, then every table in keyset pages of 2 000 rows (never everything in
//      memory). Each page is written to two temp files (CSV and JSON); between pages the job's state
//      is read OUTSIDE the snapshot, so a cancel stops the export at the next page.
//   3. The snapshot ends; the files, the manifest and a README are zipped (yazl, streamed from disk)
//      into one temp file, which is uploaded as a stream and registered (jobs_export_complete).
// Over the limits (500 MB uncompressed, 2 million rows) the job fails with the numbers (no retry).
// Any other error is retried once; the last attempt marks the job failed. The temp folder always goes.

import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, type WriteStream } from 'node:fs';
import { mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { SupabaseClient } from '@supabase/supabase-js';
import { Client } from 'pg';
import { ZipFile } from 'yazl';
import { z } from 'zod';
import {
  CONTRACTS_VERSION,
  EXPORT_LIMITS,
  EXPORT_MANIFEST_FORMAT_VERSION,
  ExportManifest,
  ExportPiiMode,
  type ExportManifestTable,
} from '@ziadkhaled-wb/contracts';
import { csvHeader, csvLine, EXPORT_README } from '../../services/exports/csv';
import * as storage from '../../services/storage.service';
import type { JobHandler } from '../types';

const Prepared = z.object({
  status: z.string(),
  changed: z.boolean().optional(),
  organization_id: z.string().uuid().optional(),
  pii: ExportPiiMode.optional(),
  requested_by: z.object({ id: z.string().uuid(), name: z.string() }).nullable().optional(),
  shop: z.object({ id: z.string().uuid(), name: z.string(), tenant_slug: z.string() }).optional(),
  migration: z.string().optional(),
  tables: z.array(z.string()).optional(),
  columns: z.record(z.array(z.string())).optional(),
  keys: z.record(z.array(z.string())).optional(),
  json_columns: z.record(z.array(z.string())).optional(),
});

const Totals = z.record(z.string(), z.union([z.string(), z.number()]));
const Counts = z.record(z.string(), z.number());

/** A snapshot is one open transaction; `query` runs inside it. */
export interface ExportSnapshot {
  query(text: string, values?: unknown[]): Promise<Record<string, unknown>[]>;
  close(): Promise<void>;
}
export type OpenSnapshot = () => Promise<ExportSnapshot>;

/** The real snapshot: a direct connection, `BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY`. */
export function pgSnapshot(connectionString: string): OpenSnapshot {
  return async () => {
    const client = new Client({ connectionString, application_name: 'ecofin-export' });
    await client.connect();
    try {
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SET LOCAL statement_timeout = '600s'");
      await client.query("SET LOCAL TIME ZONE 'UTC'");
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '0'");
    } catch (error) {
      await client.end().catch(() => undefined);
      throw error;
    }
    return {
      query: async (text, values) =>
        (await client.query(text, values)).rows as Record<string, unknown>[],
      close: async () => {
        try {
          await client.query('ROLLBACK');
        } finally {
          await client.end();
        }
      },
    };
  };
}

/** Over a limit or another reason that a retry would not change: the job ends 'failed'. */
class ExportAbort extends Error {
  constructor(
    readonly code: string,
    readonly detail: Record<string, unknown> = {},
  ) {
    super(code);
  }
}

/** The job was cancelled while it ran. */
class ExportCancelled extends Error {}

async function call(
  db: SupabaseClient,
  fn: string,
  args: Record<string, unknown>,
): Promise<unknown> {
  const { data, error } = await db.rpc(fn, args);
  if (error) throw new Error(`${fn} failed: ${error.message}`);
  return data;
}

/** A write stream that waits for the drain event, so a big table never piles up in memory. */
class FileSink {
  bytes = 0;
  private readonly stream: WriteStream;
  constructor(path: string) {
    this.stream = createWriteStream(path);
  }
  async write(text: string): Promise<void> {
    const chunk = Buffer.from(text, 'utf8');
    this.bytes += chunk.length;
    if (!this.stream.write(chunk)) {
      await new Promise<void>((resolve, reject) => {
        const onError = (e: Error) => reject(e);
        this.stream.once('error', onError);
        this.stream.once('drain', () => {
          this.stream.off('error', onError);
          resolve();
        });
      });
    }
  }
  async end(): Promise<void> {
    await new Promise<void>((resolve, reject) => {
      this.stream.once('error', reject);
      this.stream.end(resolve);
    });
  }
  destroy(): void {
    this.stream.destroy();
  }
}

const pad = (n: number) => String(n).padStart(2, '0');

export function exportZipName(slug: string, at: Date): string {
  const stamp = `${at.getUTCFullYear()}${pad(at.getUTCMonth() + 1)}${pad(at.getUTCDate())}-${pad(at.getUTCHours())}${pad(at.getUTCMinutes())}`;
  return `ecofin-export-${slug.replace(/[^a-zA-Z0-9_-]/g, '-')}-${stamp}.zip`;
}

export interface ExportFullDeps {
  db: SupabaseClient;
  /** Absent when DATABASE_URL is not set: the export then fails with a clear log line. */
  openSnapshot: OpenSnapshot | null;
  /** Rows per page (tests use small pages). */
  pageRows?: number;
  limits?: { maxBytes: number; maxRows: number };
}

export function exportFull(deps: ExportFullDeps): JobHandler {
  const { db } = deps;
  const pageRows = deps.pageRows ?? EXPORT_LIMITS.pageRows;
  const limits = deps.limits ?? {
    maxBytes: EXPORT_LIMITS.maxBytes,
    maxRows: EXPORT_LIMITS.maxRows,
  };
  return async (job, log) => {
    const exportJobId = z.string().uuid().parse(job.payload['export_job_id']);
    let dir: string | null = null;
    let snapshot: ExportSnapshot | null = null;
    let objectPath: string | null = null;
    try {
      const prepared = Prepared.parse(
        await call(db, 'jobs_export_prepare', { p_job_id: exportJobId }),
      );
      if (prepared.status !== 'importing') {
        log.info({ exportJobId, status: prepared.status }, 'export.full: nothing to do');
        return;
      }
      if (deps.openSnapshot === null) {
        throw new ExportAbort('EXPORT_FAILED', { reason: 'DATABASE_URL is not set' });
      }
      const { organization_id: orgId, shop, tables, columns, keys } = prepared;
      if (!orgId || !shop || !tables || !columns || !keys || !prepared.pii) {
        throw new Error('jobs_export_prepare answered without the export plan');
      }
      dir = await mkdtemp(join(tmpdir(), 'ecofin-export-'));
      const exportedAt = new Date();

      // 2. The snapshot: counts and totals first, then every table.
      snapshot = await deps.openSnapshot();
      const counts = Counts.parse(
        (
          await snapshot.query('SELECT public.jobs_export_counts($1::uuid) AS v', [exportJobId])
        )[0]?.['v'],
      );
      const totals = Totals.parse(
        (
          await snapshot.query('SELECT public.jobs_export_totals($1::uuid) AS v', [exportJobId])
        )[0]?.['v'],
      );
      const totalRows = Object.values(counts).reduce((a, b) => a + b, 0);
      if (totalRows > limits.maxRows) {
        throw new ExportAbort('EXPORT_TOO_LARGE', {
          total_rows: totalRows,
          limit_rows: limits.maxRows,
        });
      }

      let bytes = 0;
      const manifestTables: ExportManifestTable[] = [];
      for (const table of tables) {
        const cols = columns[table] ?? [];
        const jsonIdx = new Set(
          (prepared.json_columns?.[table] ?? []).map((c) => cols.indexOf(c)).filter((i) => i >= 0),
        );
        const csvSink = new FileSink(join(dir, `${table}.csv`));
        const jsonSink = new FileSink(join(dir, `${table}.json`));
        let rows = 0;
        try {
          await csvSink.write(csvHeader(cols));
          await jsonSink.write('[');
          let after: string[] | null = null;
          for (;;) {
            const page = await snapshot.query(
              'SELECT row_json, cells, key_vals FROM public.jobs_export_page($1::uuid, $2::text, $3::text[], $4::integer)',
              [exportJobId, table, after, pageRows],
            );
            if (page.length === 0) break;
            let csvChunk = '';
            let jsonChunk = '';
            for (const row of page) {
              csvChunk += csvLine(row['cells'] as (string | null)[], jsonIdx);
              jsonChunk +=
                (rows === 0 && jsonChunk === '' ? '\n' : ',\n') + (row['row_json'] as string);
              rows += 1;
            }
            await csvSink.write(csvChunk);
            await jsonSink.write(jsonChunk);
            after = page[page.length - 1]?.['key_vals'] as string[];
            if (bytes + csvSink.bytes + jsonSink.bytes > limits.maxBytes) {
              throw new ExportAbort('EXPORT_TOO_LARGE', {
                total_rows: totalRows,
                limit_rows: limits.maxRows,
                limit_bytes: limits.maxBytes,
              });
            }
            const state = await call(db, 'jobs_export_state', { p_job_id: exportJobId });
            if (state !== 'importing') throw new ExportCancelled();
            if (page.length < pageRows) break;
          }
          await jsonSink.write(rows === 0 ? ']\n' : '\n]\n');
          await csvSink.end();
          await jsonSink.end();
        } catch (error) {
          csvSink.destroy();
          jsonSink.destroy();
          throw error;
        }
        bytes += csvSink.bytes + jsonSink.bytes;
        if (rows !== (counts[table] ?? -1)) {
          throw new Error(
            `export.full: ${table} gave ${rows} rows, the snapshot counted ${counts[table]}`,
          );
        }
        manifestTables.push({ name: table, rows, columns: cols });
      }
      await snapshot.close();
      snapshot = null;

      const manifest = ExportManifest.parse({
        format_version: EXPORT_MANIFEST_FORMAT_VERSION,
        shop,
        exported_at: exportedAt.toISOString(),
        requested_by: prepared.requested_by ?? null,
        pii: prepared.pii,
        schema: {
          migration: prepared.migration ?? 'unknown',
          contracts_version: CONTRACTS_VERSION,
        },
        tables: manifestTables,
        totals,
      });

      // 3. The zip, streamed from the temp files into one temp file.
      const zipPath = join(dir, 'export.zip');
      const zip = new ZipFile();
      zip.addBuffer(Buffer.from(EXPORT_README, 'utf8'), 'README.txt');
      zip.addBuffer(Buffer.from(JSON.stringify(manifest, null, 2) + '\n', 'utf8'), 'manifest.json');
      for (const t of tables) {
        zip.addFile(join(dir, `${t}.csv`), `csv/${t}.csv`);
        zip.addFile(join(dir, `${t}.json`), `json/${t}.json`);
      }
      zip.end();
      await pipeline(zip.outputStream, createWriteStream(zipPath));
      const sha256 = createHash('sha256');
      await pipeline(createReadStream(zipPath), async function* (source) {
        for await (const chunk of source) sha256.update(chunk as Buffer);
      });
      const size = (await stat(zipPath)).size;

      const fileId = randomUUID();
      objectPath = `${orgId}/export/${exportedAt.getUTCFullYear()}/${pad(exportedAt.getUTCMonth() + 1)}/${fileId}.zip`;
      await storage.putObjectFile(objectPath, zipPath, 'application/zip');
      const done = z.object({ changed: z.boolean() }).parse(
        await call(db, 'jobs_export_complete', {
          p_job_id: exportJobId,
          p_file_id: fileId,
          p_path: objectPath,
          p_original_name: exportZipName(shop.tenant_slug, exportedAt),
          p_size_bytes: size,
          p_sha256: sha256.digest('hex'),
          p_rows: totalRows,
          p_manifest: manifest,
          p_uncompressed_bytes: bytes,
        }),
      );
      if (!done.changed) {
        // Cancelled while the zip was built: the object has no owner.
        await storage.removeObject(objectPath);
      }
      objectPath = null;
      log.info({ exportJobId, rows: totalRows, bytes, size }, 'export.full: finished');
    } catch (error) {
      if (objectPath !== null) await storage.removeObject(objectPath);
      if (error instanceof ExportCancelled) {
        log.info({ exportJobId }, 'export.full: cancelled');
        return;
      }
      if (error instanceof ExportAbort) {
        log.error({ exportJobId, code: error.code, detail: error.detail }, 'export.full: failed');
        await call(db, 'jobs_export_fail', {
          p_job_id: exportJobId,
          p_code: error.code,
          p_detail: error.code === 'EXPORT_TOO_LARGE' ? error.detail : {},
        });
        return;
      }
      if (job.attempt >= job.maxAttempts) {
        log.error({ err: error, exportJobId }, 'export.full: failed');
        await call(db, 'jobs_export_fail', {
          p_job_id: exportJobId,
          p_code: 'EXPORT_FAILED',
          p_detail: {},
        }).catch((e: unknown) =>
          log.error({ err: e, exportJobId }, 'export.full: could not mark failed'),
        );
      }
      throw error;
    } finally {
      if (snapshot !== null) await snapshot.close().catch(() => undefined);
      if (dir !== null) await rm(dir, { recursive: true, force: true });
    }
  };
}
