// S08 against local Supabase and a fake ETA (RUN_INTEGRATION=1, env as in auth.integration.test.ts).
// A fresh shop with ETA on gives its POS a lease; offline sales are built and signed the POS's way
// (src/test/offline.ts), synced, verified and posted by the worker, and their printed receipts are
// sent unchanged: the fake ETA recomputes every UUID and counts every receipt it receives.
// I1-I10 of docs/testing/plans/S08.md.
import { Writable } from 'node:stream';
import { randomUUID } from 'node:crypto';
import pino from 'pino';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  OfflineLeaseResponse,
  OfflineSaleList,
  OfflineSyncResponse,
  Sale,
  type OfflineItem,
} from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { EtaClient } from '../eta/client';
import { etaHosts } from '../eta/config';
import { etaJobHandlers, type EtaJobOptions } from '../eta/jobs';
import { supabaseEtaStore } from '../eta/store';
import { supabaseJobStore } from '../jobs/store';
import type { Job } from '../jobs/types';
import { JobWorker } from '../jobs/worker';
import { startFakeEta, type FakeEta } from '../test/fake-eta';
import { readInviteToken } from '../test/inviteMail';
import {
  buildOfflineSale,
  newDeviceKeys,
  publicKeyBase64,
  signContent,
  type DeviceKeys,
  type OfflineSaleBuilt,
} from '../test/offline';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';
import { getEnv } from '../utils/env';
import { logger } from '../utils/logger';
import { captureProblem } from '../utils/monitoring';
import { offlineJobHandlers } from './process';
import { supabaseOfflineStore } from './process';

vi.mock('../utils/monitoring', async (original) => ({
  ...(await original<typeof import('../utils/monitoring')>()),
  captureProblem: vi.fn(),
}));

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const CLIENT_ID = `s08-client-${STAMP}`;
const SECRET = `s08-secret-${STAMP}`;
const SERIAL = `S08-POS-${STAMP}`;
const KEY = `s08-preshared-${STAMP}`;
const RIN = '674859545';
const PORTAL = 'https://portal.fake-eta.test';
const ETA_ENV = ['ETA_PREPROD_ID_URL', 'ETA_PREPROD_API_URL', 'ETA_PREPROD_PORTAL_URL'] as const;
const LEVELS = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'] as const;

describe.skipIf(!RUN)('S08 offline cash sales against the local stack and a fake ETA', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let fake: FakeEta;
  let worker: JobWorker;
  let lateWorker: JobWorker;
  let handlers: ReturnType<typeof offlineJobHandlers>;
  let owner: string;
  let org: string;
  let branch: string;
  let device: string;
  let pos = '';
  let tv: string;
  let keys: DeviceKeys;
  let lease: OfflineLeaseResponse;
  let seq = 0;
  let head = '';
  let ip = 0;
  const savedEnv = new Map<string, string | undefined>();
  /** Every log line of the run (the app's and the worker's) and every answer, for I9. */
  const lines: string[] = [];
  const answers: string[] = [];
  const nextIp = () => `198.18.91.${(++ip % 250) + 1}`;

  async function call(
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    options: { key?: string; orgId?: string | null; device?: string | null } = {},
  ) {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + token);
    const orgId = options.orgId === undefined ? org : options.orgId;
    if (orgId) r.set('x-org-id', orgId);
    const deviceToken = options.device === undefined ? pos : options.device;
    if (deviceToken && orgId === org) r.set(DEVICE_TOKEN_HEADER, deviceToken);
    if (options.key) r.set('Idempotency-Key', options.key);
    const res = body ? await r.send(body) : await r;
    answers.push(JSON.stringify(res.body));
    return res;
  }
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', nextIp())
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  async function openJobs() {
    const { data, error } = await service
      .from('jobs')
      .select('job_type, status, last_error')
      .eq('organization_id', org)
      .or('job_type.like.eta.%,job_type.like.offline.%')
      .in('status', ['queued', 'running', 'failed', 'dead']);
    if (error) throw new Error(error.message);
    return data as { job_type: string; status: string; last_error: string | null }[];
  }
  async function drain(using: JobWorker = worker, timeoutMs = 30_000) {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const result = await using.tick();
      const open = await openJobs();
      const broken = open.filter((job) => job.status === 'failed' || job.status === 'dead');
      if (broken.length > 0) throw new Error(`a job failed: ${JSON.stringify(broken)}`);
      if (open.length === 0) return;
      if (Date.now() > until) throw new Error(`jobs did not drain: ${JSON.stringify(open)}`);
      if (result.succeeded === 0) await new Promise((resolve) => setTimeout(resolve, 150));
    }
  }

  /** The next offline sale of the POS, chained to the one before, signed. */
  async function offlineSale(
    quantity = 1,
    options: { idempotencyKey?: string } = {},
  ): Promise<OfflineSaleBuilt & { item: OfflineItem }> {
    seq = Math.max(seq + 1, lease.lease.next_seq);
    const built = buildOfflineSale({
      lease,
      snapshot: lease.snapshot!,
      seq,
      previousUuid: head,
      lines: [{ product_id: tv, quantity }],
      ...options,
    });
    head = built.uuid ?? head;
    return {
      ...built,
      item: { content: built.content, signature: await signContent(keys, built.content) },
    };
  }
  const sync = (items: OfflineItem[], deviceToken: string | null = pos) =>
    call('post', '/api/offline/sync', owner, { items }, { device: deviceToken });
  async function listed() {
    const res = await call('get', '/api/offline/sales', owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return OfflineSaleList.parse(res.body);
  }
  const byNumber = async (number: string) => (await listed()).filter((r) => r.number === number);
  async function salesNumbered(number: string) {
    const { data, error } = await service
      .from('sales')
      .select('id')
      .eq('organization_id', org)
      .eq('number', number);
    if (error) throw new Error(error.message);
    return data as { id: string }[];
  }
  async function fiscalByUuid(uuid: string) {
    const { data, error } = await service
      .from('fiscal_submissions')
      .select('id, status, sale_id')
      .eq('organization_id', org)
      .eq('eta_uuid', uuid)
      .single();
    if (error) throw new Error(error.message);
    return data;
  }

  beforeAll(async () => {
    fake = await startFakeEta({
      clientId: CLIENT_ID,
      clientSecret: SECRET,
      posSerial: SERIAL,
      presharedKey: KEY,
    });
    for (const name of ETA_ENV) savedEnv.set(name, process.env[name]);
    process.env['ETA_PREPROD_ID_URL'] = fake.url;
    process.env['ETA_PREPROD_API_URL'] = fake.url;
    process.env['ETA_PREPROD_PORTAL_URL'] = PORTAL;
    const env = getEnv();
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // Every log line of the app and of the worker is kept for I9.
    for (const level of LEVELS) {
      vi.spyOn(logger, level).mockImplementation((...args: unknown[]) => {
        lines.push(JSON.stringify(args));
      });
    }
    const workerLog = pino(
      { level: 'trace' },
      new Writable({
        write(chunk: Buffer, _encoding, done) {
          lines.push(chunk.toString());
          done();
        },
      }),
    );
    const hosts = etaHosts(env);
    const options: EtaJobOptions = {
      store: supabaseEtaStore(service),
      client: new EtaClient({ hosts, logger: workerLog, timeoutMs: 5000 }),
      hosts,
      logger: workerLog,
      lookupGapMs: 0,
      retryDelaysSeconds: [0],
      pollDelaysSeconds: [0],
    };
    handlers = offlineJobHandlers({ store: supabaseOfflineStore(service), hosts });
    const jobs = supabaseJobStore(service);
    worker = new JobWorker({
      store: jobs,
      handlers: { ...etaJobHandlers(options), ...handlers },
      logger: workerLog,
      batchSize: 50,
    });
    lateWorker = new JobWorker({
      store: jobs,
      handlers: {
        ...etaJobHandlers({ ...options, now: () => new Date(Date.now() + 21 * 3_600_000) }),
        ...handlers,
      },
      logger: workerLog,
      batchSize: 50,
    });

    const admin = await login('superadmin@ecotech.test');
    const email = `s08.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', nextIp())
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'S08 shop',
        tenant_slug: `s08-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', nextIp())
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    const named = await service
      .from('organizations')
      .update({ tax_registration_no: RIN, legal_name: 'S08 Furniture LLC' })
      .eq('id', org);
    expect(named.error).toBeNull();
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    branch = main.data!.id as string;
    const addressed = await call('patch', `/api/branches/${branch}`, owner, {
      name: 'Main',
      address: '16 Abbas El Akkad',
      city: 'Nasr City',
      governorate: 'Cairo',
      eta_branch_code: '0',
      building_number: '14',
    });
    expect(addressed.status, JSON.stringify(addressed.body)).toBe(200);
    const made = await pairTestDevice(service, org, branch, 'Till 1');
    device = made.id;
    pos = made.token;
    const registered = await call('put', `/api/devices/${device}/eta`, owner, {
      eta_serial: SERIAL,
      eta_os_version: 'android 14',
      eta_model_framework: '1',
      preshared_key: KEY,
      eta_status: 'active',
    });
    expect(registered.status, JSON.stringify(registered.body)).toBe(200);
    const settings = await call('put', '/api/eta/settings', owner, {
      environment: 'preprod',
      client_id: CLIENT_ID,
      client_secret: SECRET,
      activity_code: '4753',
      is_enabled: true,
    });
    expect(settings.status, JSON.stringify(settings.body)).toBe(200);
    const product = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون 55 بوصة',
      sku: 'S08-TV',
      cash_price: '1140.00',
      eta_item_code: `EG-${RIN}-TV55`,
      eta_item_type: 'EGS',
    });
    expect(product.status, JSON.stringify(product.body)).toBe(201);
    tv = (product.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: tv, quantity: 60 }] },
      { key: `s08-it-stock-${STAMP}` },
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const shift = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: branch, opening_float: '0', device_id: device },
      { key: `s08-it-shift-${STAMP}` },
    );
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
    const offline = await call('put', '/api/offline/settings', owner, {
      offline_enabled: true,
      offline_max_sale_total: '20000.00',
      offline_max_hours: 12,
      offline_max_sales: 100,
      offline_max_lease_total: '200000.00',
    });
    expect(offline.status, JSON.stringify(offline.body)).toBe(200);

    keys = await newDeviceKeys();
    const leased = await call('post', '/api/offline/lease', owner, {
      public_key: await publicKeyBase64(keys),
      snapshot_hash: null,
    });
    expect(leased.status, JSON.stringify(leased.body)).toBe(200);
    lease = OfflineLeaseResponse.parse(leased.body);
    head = lease.lease.chain_head;
    expect(lease.eta).toMatchObject({
      enabled: true,
      environment: 'preprod',
      portal_url: PORTAL,
      device_serial: SERIAL,
    });
  }, 120_000);

  afterAll(async () => {
    if (org) {
      await service.from('eta_settings').update({ is_enabled: false }).eq('organization_id', org);
      await service
        .from('jobs')
        .delete()
        .eq('organization_id', org)
        .or('job_type.like.eta.%,job_type.like.offline.%');
    }
    await fake?.close();
    for (const [name, value] of savedEnv) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    vi.restoreAllMocks();
  });

  const offlineUuids: string[] = [];

  it('I1 three offline sales: synced, verified, posted; the ETA receives each UUID once and finds it Valid', async () => {
    const sales = [await offlineSale(), await offlineSale(2), await offlineSale()];
    const res = await sync(sales.map((s) => s.item));
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(OfflineSyncResponse.parse(res.body).results.map((r) => r.result)).toEqual([
      'received',
      'received',
      'received',
    ]);
    await drain();
    const rows = await listed();
    for (const sale of sales) {
      const row = rows.find((r) => r.number === sale.number)!;
      expect(row.status).toBe('posted');
      expect(fake.received.get(sale.uuid!)).toBe(1);
      expect(fake.receipts.get(sale.uuid!)?.status).toBe('Valid');
      expect(await fiscalByUuid(sale.uuid!)).toMatchObject({
        status: 'accepted',
        sale_id: row.sale_id,
      });
      offlineUuids.push(sale.uuid!);
    }
    expect(fake.badHashes).toEqual([]);
    // The posted sale is the printed one.
    const second = rows.find((r) => r.number === sales[1]!.number)!;
    const sale = await call('get', `/api/sales/${second.sale_id}`, owner);
    expect(Sale.parse(sale.body)).toMatchObject({
      number: sales[1]!.number,
      total: sales[1]!.total,
    });
  }, 60_000);

  it('I10 the next online sale on the device chains to the last offline receipt', async () => {
    const sold = await call(
      'post',
      '/api/sales',
      owner,
      { lines: [{ product_id: tv, quantity: 1 }], expected_total: '1140.00' },
      { key: `s08-it-online-${STAMP}` },
    );
    expect(sold.status, JSON.stringify(sold.body)).toBe(201);
    await drain();
    const { data } = await service
      .from('fiscal_submissions')
      .select('previous_uuid, eta_uuid, status')
      .eq('sale_id', (sold.body as { id: string }).id)
      .single();
    expect(data).toMatchObject({ previous_uuid: offlineUuids[2], status: 'accepted' });
    head = (data as { eta_uuid: string }).eta_uuid;
    expect(fake.chainBreaks).toEqual([]);
  }, 60_000);

  it('I2 the same batch synced twice at once: one row per sequence, one sale each, received once by the ETA', async () => {
    const sales = [await offlineSale(), await offlineSale()];
    const items = sales.map((s) => s.item);
    const [first, second] = await Promise.all([sync(items), sync(items)]);
    expect([first.status, second.status]).toEqual([200, 200]);
    const outcomes = [
      ...OfflineSyncResponse.parse(first.body).results,
      ...OfflineSyncResponse.parse(second.body).results,
    ]
      .map((r) => r.result)
      .sort();
    expect(outcomes).toEqual(['duplicate', 'duplicate', 'received', 'received']);
    await drain();
    for (const sale of sales) {
      expect(await byNumber(sale.number)).toHaveLength(1);
      expect(await salesNumbered(sale.number)).toHaveLength(1);
      expect(fake.received.get(sale.uuid!)).toBe(1);
    }
  }, 60_000);

  it('I3 two worker runs at once never post twice', async () => {
    const sales = [await offlineSale(), await offlineSale(), await offlineSale()];
    expect((await sync(sales.map((s) => s.item))).status).toBe(200);
    const job: Job = {
      id: 'i3',
      organizationId: org,
      type: 'offline.process',
      payload: { device_id: device },
      attempt: 1,
      maxAttempts: 5,
    };
    const silent = pino({ level: 'silent' });
    await Promise.all([
      handlers['offline.process'](job, silent),
      handlers['offline.process'](job, silent),
    ]);
    for (const sale of sales) {
      const posted = await salesNumbered(sale.number);
      expect(posted).toHaveLength(1);
      const { data } = await service
        .from('stock_movements')
        .select('id')
        .eq('organization_id', org)
        .eq('source_type', 'sale')
        .eq('source_id', posted[0]!.id);
      expect(data).toHaveLength(1);
    }
    await drain();
  }, 60_000);

  it('I4 an imported file with one changed amount: that sale is refused and never sent, the others are posted', async () => {
    const changed = await offlineSale();
    const kept = await offlineSale();
    // The cash given is changed after signing: the content still adds up, the signature does not.
    const forged = changed.item.content.replace(
      `"tendered":"${changed.total}","change":"0.00"`,
      `"tendered":"${changed.total.replace(/^(\d+)/, (n) => String(Number(n) + 60))}","change":"60.00"`,
    );
    expect(forged).not.toBe(changed.item.content);
    const res = await call(
      'post',
      '/api/offline/import',
      owner,
      { device_id: device, items: [{ ...changed.item, content: forged }, kept.item] },
      { device: null },
    );
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    await drain();
    expect((await byNumber(changed.number))[0]).toMatchObject({
      status: 'rejected',
      conflict_code: 'VERIFY_FAILED',
      source: 'import',
    });
    expect((await fiscalByUuid(changed.uuid!)).status).toBe('cancelled');
    expect(fake.received.get(changed.uuid!)).toBeUndefined();
    expect((await byNumber(kept.number))[0]).toMatchObject({ status: 'posted', source: 'import' });
    expect(fake.received.get(kept.uuid!)).toBe(1);
  }, 60_000);

  it('I5 an online sale whose answer was lost, then the same cart offline with its key: one sale, only the online receipt', async () => {
    const key = randomUUID();
    const online = await call(
      'post',
      '/api/sales',
      owner,
      { lines: [{ product_id: tv, quantity: 1 }], expected_total: '1140.00' },
      { key },
    );
    expect(online.status, JSON.stringify(online.body)).toBe(201);
    await drain();
    const offline = await offlineSale(1, { idempotencyKey: key });
    expect((await sync([offline.item])).status).toBe(200);
    await drain();
    const [row] = await byNumber(offline.number);
    expect(row).toMatchObject({ status: 'duplicate', sale_id: (online.body as { id: string }).id });
    expect(row!.flags).toContain('reprint_needed');
    expect(fake.received.get(offline.uuid!)).toBeUndefined();
    const { data } = await service
      .from('sales')
      .select('id')
      .eq('organization_id', org)
      .eq('idempotency_key', key);
    expect(data).toHaveLength(1);
  }, 60_000);

  it('I6 after an unpair the sync is DEVICE_REVOKED; paired again, the same sales sync and post', async () => {
    const sales = [await offlineSale(), await offlineSale()];
    const unpaired = await call('post', `/api/devices/${device}/unpair`, owner, {});
    expect(unpaired.status, JSON.stringify(unpaired.body)).toBe(200);
    const refused = await sync(sales.map((s) => s.item));
    expect(refused.status).toBe(403);
    expect(code(refused)).toBe('DEVICE_REVOKED');
    pos = (await pairTestDevice(service, org, branch, 'Till 1')).token;
    const again = await sync(sales.map((s) => s.item));
    expect(again.status, JSON.stringify(again.body)).toBe(200);
    await drain();
    for (const sale of sales) expect((await byNumber(sale.number))[0]?.status).toBe('posted');
    // The old lease went with the pairing: a new one.
    const leased = await call('post', '/api/offline/lease', owner, {
      public_key: await publicKeyBase64(keys),
      snapshot_hash: lease.lease.snapshot_hash,
    });
    expect(leased.status, JSON.stringify(leased.body)).toBe(200);
    lease = { ...OfflineLeaseResponse.parse(leased.body), snapshot: lease.snapshot };
  }, 60_000);

  it('I7 a released offline receipt still pending 20 hours after its sale alerts once', async () => {
    const sale = await offlineSale();
    fake.failNextSubmit('unavailable');
    expect((await sync([sale.item])).status).toBe(200);
    await drain(lateWorker);
    const fiscal = await fiscalByUuid(sale.uuid!);
    const forIt = () =>
      vi.mocked(captureProblem).mock.calls.filter(([, tags]) => {
        const t = tags as Record<string, unknown>;
        return t['reason'] === 'deadline' && t['fiscalId'] === fiscal.id;
      });
    expect(forIt()).toHaveLength(1);
    await lateWorker.tick();
    expect(forIt()).toHaveLength(1);
  }, 60_000);

  it("I8 another shop can't list, read, resolve or import this shop's offline sales", async () => {
    const other = await login('owner.two@ecotech.test');
    const one = (await listed())[0]!;
    const as = (r: request.Test) =>
      r.set('Authorization', 'Bearer ' + other).set('X-Forwarded-For', nextIp());
    const list = await as(request(app).get('/api/offline/sales'));
    expect(list.status).toBe(200);
    expect((list.body as { id: string }[]).some((r) => r.id === one.id)).toBe(false);
    expect((await as(request(app).get(`/api/offline/sales/${one.id}`))).status).toBe(404);
    const resolve = await as(request(app).post(`/api/offline/sales/${one.id}/resolve`)).send({
      action: 'accept',
      reason: 'not mine',
    });
    expect(resolve.status).toBe(404);
    const imported = await as(request(app).post('/api/offline/import')).send({
      device_id: device,
      items: [{ content: '{}', signature: 'A'.repeat(86) + '==' }],
    });
    expect(imported.status).toBe(404);
    expect(code(imported)).toBe('DEVICE_NOT_FOUND');
  });

  it('I9 no answer, log line or alert holds a device token, a signature or a full content', async () => {
    const sale = await offlineSale();
    await sync([sale.item]);
    await drain();
    const detail = await call(
      'get',
      `/api/offline/sales/${(await byNumber(sale.number))[0]!.id}`,
      owner,
    );
    expect(detail.status).toBe(200);
    const problems = vi.mocked(captureProblem).mock.calls.map((c) => JSON.stringify(c));
    const texts = [...answers, ...lines, ...problems];
    expect(lines.length).toBeGreaterThan(0);
    for (const text of texts) {
      expect(text.includes(pos)).toBe(false);
      expect(text.includes(sale.item.signature)).toBe(false);
      expect(text.includes(sale.item.content)).toBe(false);
      expect(text.includes('"lease_id":"')).toBe(false);
    }
  }, 60_000);

  it('every receipt of the run was received at most once and hashed right', () => {
    for (const [, count] of fake.received) expect(count).toBe(1);
    expect(fake.badHashes).toEqual([]);
  });
});
