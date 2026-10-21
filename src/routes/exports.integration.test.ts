// M03 (D86) against the local stack (RUN_INTEGRATION=1, DATABASE_URL = the local Postgres, env as in
// auth.integration.test.ts), seed shop two. The whole path: start an export, one running at a time,
// the worker's handler builds the zip in one snapshot, the signed download link, the zip's content
// (manifest rows equal count(*) per table, totals equal the database, BOM, the formula guard, masked
// national IDs, no secret column), the 7-day cleanup, cancel, and the permission and shop checks.
import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { beforeAll, describe, expect, it } from 'vitest';
import request from 'supertest';
import {
  AuthLoginResponse,
  ErrorResponse,
  ExportJob,
  ExportListResponse,
  ExportManifest,
  FileUrlResponse,
} from '@ziadkhaled-wb/contracts';
import { parseCsv, readZip } from '../../scripts/export-restore-check.mjs';
import { createApp } from '../app';
import { exportFull, pgSnapshot } from '../jobs/handlers/exportFull';
import { exportCleanup } from '../jobs/handlers/exportCleanup';
import { getEnv } from '../utils/env';
import { readInviteToken } from '../test/inviteMail';
import { supabaseAdmin } from '../utils/supabase';

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const NID = '29101010100777';

describe.skipIf(!RUN)('M03 full export against local stack', () => {
  let app: ReturnType<typeof createApp>;
  let owner: string;
  let cashier: string;
  let ownerOne: string;
  let org: string;
  let ip = 0;
  const nextIp = () => `198.18.19.${(++ip % 250) + 1}`;
  const log = pino({ level: 'silent' });
  const call = (
    method: 'get' | 'post',
    path: string,
    token: string,
    opts: { body?: object; key?: string } = {},
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    if (opts.key) r.set('Idempotency-Key', opts.key);
    return opts.body ? r.send(opts.body) : r;
  };
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  /** What the worker does for a queued export.full job. */
  const runWorker = (exportJobId: string, over: { attempt?: number } = {}) =>
    exportFull({
      db: supabaseAdmin,
      openSnapshot: pgSnapshot(process.env['DATABASE_URL'] ?? ''),
      pageRows: 50,
    })(
      {
        id: randomUUID(),
        organizationId: org,
        type: 'export.full',
        payload: { export_job_id: exportJobId },
        attempt: over.attempt ?? 1,
        maxAttempts: 2,
      },
      log,
    );

  /** A fresh shop per run: rows of import_jobs are never deleted, so an old export would block this one. */
  async function provision() {
    const admin = await login('superadmin@ecotech.test');
    const email = `m03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: `M03 shop ${STAMP}`,
        tenant_slug: `m03-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner M03', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', nextIp())
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    return { org: shop.body.organization_id as string, token: await login(email) };
  }

  beforeAll(async () => {
    app = createApp({ env: getEnv() });
    const shop = await provision();
    org = shop.org;
    owner = shop.token;
    cashier = await login('cashier.two@ecotech.test');
    ownerOne = await login('owner.one@ecotech.test');
    // Data that the export must treat with care.
    const { error } = await supabaseAdmin.from('customers').insert([
      {
        organization_id: org,
        full_name: `=1+1 ${STAMP}`,
        phones: ['01099990001'],
        national_id: NID,
        notes: 'comma, "quote"\nnew line',
      },
      {
        organization_id: org,
        full_name: `عميل عربي ${STAMP}`,
        phones: ['01099990002'],
      },
    ]);
    if (error) throw new Error(error.message);
  });

  it('cancel stops a queued export; the full mode is audited at warning; the body is strict', async () => {
    const started = await call('post', '/api/exports', owner, {
      key: `m03-cancel-${STAMP}`,
      body: { pii: 'masked' },
    });
    expect(started.status, JSON.stringify(started.body)).toBe(202);
    const id = ExportJob.parse(started.body).id;
    const cancelled = ExportJob.parse(
      (await call('post', `/api/exports/${id}/cancel`, owner)).body,
    );
    expect(cancelled.status).toBe('cancelled');
    // The worker finds a cancelled job and does nothing.
    await runWorker(id);
    expect(ExportJob.parse((await call('get', `/api/exports/${id}`, owner)).body).status).toBe(
      'cancelled',
    );
    // A full export (national IDs as stored) is allowed for the owner, who holds customer.view_pii,
    // and its request is audited at warning.
    const full = await call('post', '/api/exports', owner, {
      key: `m03-full-${STAMP}`,
      body: { pii: 'full' },
    });
    expect(full.status, JSON.stringify(full.body)).toBe(202);
    const fullJob = ExportJob.parse(full.body);
    expect(fullJob.pii).toBe('full');
    const { data: fullAudit } = await supabaseAdmin
      .from('audit_log')
      .select('severity')
      .eq('entity_id', fullJob.id)
      .eq('action', 'export.requested');
    expect(fullAudit?.[0]?.severity).toBe('warning');
    await call('post', `/api/exports/${fullJob.id}/cancel`, owner);
    // Strict body.
    const bad = await call('post', '/api/exports', owner, {
      key: `m03-bad-${STAMP}`,
      body: { pii: 'raw' },
    });
    expect(bad.status).toBe(400);
    const injected = await call('post', '/api/exports', owner, {
      key: `m03-inj-${STAMP}`,
      body: { organization_id: org },
    });
    expect(injected.status).toBe(400);
  });

  it('exports the whole shop: queued, one at a time, built in one snapshot, downloaded, checked', async () => {
    const key = `m03-int-${STAMP}`;
    const started = await call('post', '/api/exports', owner, { key, body: {} });
    expect(started.status, JSON.stringify(started.body)).toBe(202);
    const job = ExportJob.parse(started.body);
    expect(job.status).toBe('queued');
    expect(job.pii).toBe('masked');
    expect(job.file_id).toBeNull();

    // The same key answers the same job; another key while it is queued: EXPORT_RUNNING.
    const repeat = await call('post', '/api/exports', owner, { key, body: {} });
    expect(ExportJob.parse(repeat.body).id).toBe(job.id);
    const second = await call('post', '/api/exports', owner, { key: `${key}-2`, body: {} });
    expect(second.status).toBe(409);
    expect(code(second)).toBe('EXPORT_RUNNING');
    expect((second.body as { error: { details: { job_id: string } } }).error.details.job_id).toBe(
      job.id,
    );

    // The queue holds the job for the worker.
    const { data: queued } = await supabaseAdmin
      .from('jobs')
      .select('job_type, status')
      .eq('organization_id', org)
      .eq('dedupe_key', job.id);
    expect(queued?.[0]?.job_type).toBe('export.full');

    await runWorker(job.id);
    const done = ExportJob.parse((await call('get', `/api/exports/${job.id}`, owner)).body);
    expect(done.status, JSON.stringify(done)).toBe('completed');
    expect(done.file_id).not.toBeNull();
    expect(done.rows).toBeGreaterThan(15);
    expect(done.size_bytes).toBeGreaterThan(500);
    expect(done.file_name).toMatch(/^ecofin-export-.*-\d{8}-\d{4}\.zip$/);
    const list = ExportListResponse.parse((await call('get', '/api/exports', owner)).body);
    expect(list.items[0]?.id).toBe(job.id);

    // A new export within the hour: EXPORT_TOO_SOON with retry_after.
    const soon = await call('post', '/api/exports', owner, { key: `${key}-3`, body: {} });
    expect(soon.status).toBe(429);
    expect(code(soon)).toBe('EXPORT_TOO_SOON');
    const retry = (soon.body as { error: { details: { retry_after: number } } }).error.details
      .retry_after;
    expect(retry).toBeGreaterThan(0);
    expect(retry).toBeLessThanOrEqual(3600);

    // The download is F14's signed link (audited as export.downloaded).
    const link = FileUrlResponse.parse(
      (await call('get', `/api/files/${done.file_id}/url`, owner)).body,
    );
    const zipRes = await fetch(link.url);
    expect(zipRes.status).toBe(200);
    const entries = readZip(Buffer.from(await zipRes.arrayBuffer()));
    const { data: audited } = await supabaseAdmin
      .from('audit_log')
      .select('action')
      .eq('organization_id', org)
      .eq('entity_id', job.id);
    expect(audited?.map((a) => a.action)).toEqual(
      expect.arrayContaining(['export.requested', 'export.completed', 'export.downloaded']),
    );

    // The manifest: every table once, rows equal count(*), the totals equal the database.
    const manifest = ExportManifest.parse(
      JSON.parse((entries['manifest.json'] as Buffer).toString('utf8')),
    );
    expect(manifest.pii).toBe('masked');
    expect(manifest.shop.id).toBe(org);
    expect(manifest.requested_by?.name).toBe('Owner M03');
    expect(manifest.schema.migration).toMatch(/^\d{14}_/);
    const names = manifest.tables.map((t) => t.name);
    expect(names).toEqual(expect.arrayContaining(['customers', 'audit_log', 'organizations']));
    expect(names).not.toContain('jobs');
    expect(names).not.toContain('password_resets');
    for (const t of manifest.tables) {
      const filter = t.name === 'organizations' ? 'id' : 'organization_id';
      const { count } = await supabaseAdmin
        .from(t.name as 'customers')
        .select('*', { count: 'exact', head: true })
        .eq(filter, org);
      // The shop keeps working while the test runs (audit rows of its own calls): the snapshot's
      // count can only be lower than or equal to now, and the CSV has exactly that many rows.
      expect(count ?? 0, t.name).toBeGreaterThanOrEqual(t.rows);
      const csv = parseCsv((entries[`csv/${t.name}.csv`] as Buffer).toString('utf8'));
      expect(csv.length - 1, t.name).toBe(t.rows);
      expect(csv[0], t.name).toEqual(t.columns);
      const json = JSON.parse(
        (entries[`json/${t.name}.json`] as Buffer).toString('utf8'),
      ) as unknown[];
      expect(json.length, t.name).toBe(t.rows);
    }
    const { data: balances } = await supabaseAdmin
      .from('cash_balances')
      .select('balance')
      .eq('organization_id', org);
    const cash = (balances ?? []).reduce((a, b) => a + Math.round(Number(b.balance) * 100), 0);
    expect(manifest.totals.cash_balance_total).toBe((cash / 100).toFixed(2));
    const { data: stock } = await supabaseAdmin
      .from('stock_levels')
      .select('on_hand')
      .eq('organization_id', org);
    expect(manifest.totals.stock_on_hand_total).toBe(
      String((stock ?? []).reduce((a, b) => a + b.on_hand, 0)),
    );

    // Excel safety and Arabic: BOM, the formula guard, quoting, Arabic, no raw national ID.
    const customers = (entries['csv/customers.csv'] as Buffer).toString('utf8');
    expect(customers.charCodeAt(0)).toBe(0xfeff);
    expect(customers).toContain(`'=1+1 ${STAMP}`);
    expect(customers).toContain(`عميل عربي ${STAMP}`);
    expect(customers).toContain('"comma, ""quote""\nnew line"');
    expect(customers).not.toContain(NID);
    expect(customers).toContain('**********0777');
    // No secret column in any file.
    for (const [name, bytes] of Object.entries(entries)) {
      if (!name.startsWith('csv/') && !name.startsWith('json/')) continue;
      const text = bytes.toString('utf8');
      expect(text, name).not.toMatch(/token_hash|client_secret_vault_id|pairing_code_hash/);
    }
    expect((entries['README.txt'] as Buffer).toString('utf8')).toContain('csv/');

    // The cleanup keeps a fresh zip, and removes one older than 7 days.
    const cleanup = exportCleanup(supabaseAdmin);
    const cleanupJob = {
      id: randomUUID(),
      organizationId: org,
      type: 'export.cleanup',
      payload: {},
      attempt: 1,
      maxAttempts: 3,
    };
    await cleanup(cleanupJob, log);
    expect(ExportJob.parse((await call('get', `/api/exports/${job.id}`, owner)).body).file_id).toBe(
      done.file_id,
    );
    await supabaseAdmin
      .from('files')
      .update({ created_at: new Date(Date.now() - 8 * 86_400_000).toISOString() })
      .eq('id', done.file_id);
    await cleanup(cleanupJob, log);
    const removed = ExportJob.parse((await call('get', `/api/exports/${job.id}`, owner)).body);
    expect(removed.file_id).toBeNull();
    expect(removed.file_removed_at).not.toBeNull();
    const gone = await call('get', `/api/files/${done.file_id}/url`, owner);
    expect(gone.status).toBe(404);
    expect(code(gone)).toBe('FILE_NOT_FOUND');
  });

  it('safety: a cashier is refused, a missing key is refused, another shop sees nothing', async () => {
    const denied = await call('post', '/api/exports', cashier, { key: `m03-c-${STAMP}`, body: {} });
    expect(denied.status).toBe(403);
    expect(code(denied)).toBe('PERMISSION_DENIED');
    expect((await call('get', '/api/exports', cashier)).status).toBe(403);
    const noKey = await call('post', '/api/exports', owner, { body: {} });
    expect(noKey.status).toBe(400);

    const mine = await supabaseAdmin
      .from('import_jobs')
      .select('id')
      .eq('organization_id', org)
      .eq('kind', 'full_export')
      .limit(1);
    const id = mine.data?.[0]?.id as string;
    expect(id).toBeTruthy();
    // Shop one's owner cannot read or cancel shop two's export, and sees none in their list.
    const read = await call('get', `/api/exports/${id}`, ownerOne);
    expect(read.status).toBe(404);
    expect(code(read)).toBe('EXPORT_NOT_FOUND');
    const cancel = await call('post', `/api/exports/${id}/cancel`, ownerOne);
    expect(cancel.status).toBe(404);
    const list = await call('get', '/api/exports', ownerOne);
    expect(JSON.stringify(list.body)).not.toContain(id);
  });
});
