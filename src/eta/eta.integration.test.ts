// T02 against local Supabase and a fake ETA (RUN_INTEGRATION=1, env as in auth.integration.test.ts).
// A fresh shop turns ETA on, registers a POS and sells: every sale gets its receipt, chained to
// the one before, with the QR text in the sale answer; the jobs submit and poll it to accepted.
// Then what must never go wrong: a submission the ETA took but never answered, a 422
// DuplicateSubmission and a 503 each end with the receipt received ONCE; an Invalid receipt is
// rejected with the ETA's reason; a product without an ETA code blocks only its own receipt;
// two sales at the same moment stay one chain; a receipt pending 20 hours alerts once; another
// shop can't read or retry any of it. The fake ETA recomputes every UUID from the bytes it gets.
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import { AuthLoginResponse, ErrorResponse, Sale, SaleEta } from '@ziadkhaled-wb/contracts';
import { createApp } from '../app';
import { supabaseJobStore } from '../jobs/store';
import { JobWorker } from '../jobs/worker';
import { startFakeEta, type FakeEta } from '../test/fake-eta';
import { readInviteToken } from '../test/inviteMail';
import { DEVICE_TOKEN_HEADER, pairTestDevice } from '../test/posDevice';
import { getEnv } from '../utils/env';
import { createLogger } from '../utils/logger';
import { captureProblem } from '../utils/monitoring';
import { EtaClient } from './client';
import { etaHosts } from './config';
import { etaJobHandlers, type EtaJobOptions } from './jobs';
import { supabaseEtaStore } from './store';

vi.mock('../utils/monitoring', async (original) => ({
  ...(await original<typeof import('../utils/monitoring')>()),
  captureProblem: vi.fn(),
}));

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const CLIENT_ID = `t02-client-${STAMP}`;
const SECRET = `t02-secret-${STAMP}`;
const SERIAL = `T02-POS-${STAMP}`;
const KEY = `t02-preshared-${STAMP}`;
const RIN = '674859545';
const PORTAL = 'https://portal.fake-eta.test';
const ETA_ENV = ['ETA_PREPROD_ID_URL', 'ETA_PREPROD_API_URL', 'ETA_PREPROD_PORTAL_URL'] as const;

interface FiscalRow {
  id: string;
  status: string;
  eta_uuid: string | null;
  previous_uuid: string | null;
  eta_long_id: string | null;
  eta_submission_uuid: string | null;
  attempts: number;
  last_error: string | null;
  qr_payload: string | null;
  submitted_at: string | null;
  accepted_at: string | null;
  payload: { receipt_json?: string } | null;
  environment: string;
  device_id: string | null;
}

describe.skipIf(!RUN)('T02 ETA e-receipts against local stack and a fake ETA', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let fake: FakeEta;
  let worker: JobWorker;
  let lateWorker: JobWorker;
  let owner: string;
  let org: string;
  let branch: string;
  let device: string;
  // O03: the token of the computer paired with that device; our shop's requests come from it.
  let pos = '';
  let tv: string;
  let sofa: string;
  const savedEnv = new Map<string, string | undefined>();
  let ip = 0;
  let sales = 0;

  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    options: { key?: string; orgId?: string | null } = {},
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.90.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + token);
    const orgId = options.orgId === undefined ? org : options.orgId;
    if (orgId) r.set('x-org-id', orgId);
    if (pos && orgId === org) r.set(DEVICE_TOKEN_HEADER, pos);
    if (options.key) r.set('Idempotency-Key', options.key);
    return body ? r.send(body) : r;
  };
  const code = (res: request.Response) => ErrorResponse.parse(res.body).error.code;
  async function login(email: string) {
    const r = await request(app)
      .post('/api/auth/login')
      .set('X-Forwarded-For', `198.18.90.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  /** One unit at 1 140.00, paid in cash, in the owner's open shift on the POS. */
  async function sell(product = tv): Promise<Sale> {
    const res = await call(
      'post',
      '/api/sales',
      owner,
      { lines: [{ product_id: product, quantity: 1 }], expected_total: '1140.00' },
      { key: `t02-it-sale-${STAMP}-${++sales}` },
    );
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return Sale.parse(res.body);
  }
  async function fiscalOf(saleId: string): Promise<FiscalRow> {
    const { data, error } = await service
      .from('fiscal_submissions')
      .select('*')
      .eq('sale_id', saleId)
      .single();
    if (error) throw new Error(error.message);
    return data as FiscalRow;
  }
  const etaOf = async (saleId: string) => {
    const res = await call('get', `/api/sales/${saleId}`, owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return SaleEta.parse(Sale.parse(res.body).eta);
  };
  async function openJobs() {
    const { data, error } = await service
      .from('jobs')
      .select('job_type, status, last_error')
      .eq('organization_id', org)
      .like('job_type', 'eta.%')
      .in('status', ['queued', 'running', 'failed', 'dead']);
    if (error) throw new Error(error.message);
    return data as { job_type: string; status: string; last_error: string | null }[];
  }
  /** Runs the shop's ETA jobs until none is left (a job that fails is a failed test). */
  async function drain(using: JobWorker = worker, timeoutMs = 20_000) {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const result = await using.tick();
      const open = await openJobs();
      const broken = open.filter((job) => job.status === 'failed' || job.status === 'dead');
      if (broken.length > 0) throw new Error(`an ETA job failed: ${JSON.stringify(broken)}`);
      if (open.length === 0) return;
      if (Date.now() > until) throw new Error(`ETA jobs did not drain: ${JSON.stringify(open)}`);
      if (result.succeeded === 0) await new Promise((resolve) => setTimeout(resolve, 150));
    }
  }
  const alerts = (reason: string) =>
    vi
      .mocked(captureProblem)
      .mock.calls.filter(([, tags]) => (tags as Record<string, unknown>)['reason'] === reason);

  beforeAll(async () => {
    fake = await startFakeEta({
      clientId: CLIENT_ID,
      clientSecret: SECRET,
      posSerial: SERIAL,
      presharedKey: KEY,
    });
    // The shop's pre-production hosts are the fake; production keeps its own (never reached).
    for (const name of ETA_ENV) savedEnv.set(name, process.env[name]);
    process.env['ETA_PREPROD_ID_URL'] = fake.url;
    process.env['ETA_PREPROD_API_URL'] = fake.url;
    process.env['ETA_PREPROD_PORTAL_URL'] = PORTAL;
    const env = getEnv();
    expect(env.ETA_PREPROD_API_URL).toBe(fake.url);
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // The worker, as the server runs it, with the waits of decision 5 and 7 taken out.
    const logger = createLogger({ level: 'silent' });
    const hosts = etaHosts(env);
    const options: EtaJobOptions = {
      store: supabaseEtaStore(service),
      client: new EtaClient({ hosts, logger, timeoutMs: 5000 }),
      hosts,
      logger,
      lookupGapMs: 0,
      retryDelaysSeconds: [0],
      pollDelaysSeconds: [0],
    };
    const jobs = supabaseJobStore(service);
    worker = new JobWorker({
      store: jobs,
      handlers: etaJobHandlers(options),
      logger,
      batchSize: 50,
    });
    lateWorker = new JobWorker({
      store: jobs,
      // 21 hours from now: every receipt still pending is past the 20-hour mark.
      handlers: etaJobHandlers({ ...options, now: () => new Date(Date.now() + 21 * 3_600_000) }),
      logger,
      batchSize: 50,
    });

    const admin = await login('superadmin@ecotech.test');
    const email = `t02.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.90.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'T02 shop',
        tenant_slug: `t02-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.90.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    // What the receipt needs of the seller: the RIN, and the branch's ETA code and address.
    const named = await service
      .from('organizations')
      .update({ tax_registration_no: RIN, legal_name: 'T02 Furniture LLC' })
      .eq('id', org);
    expect(named.error).toBeNull();
    const main = await service.from('branches').select('id').eq('organization_id', org).single();
    expect(main.error).toBeNull();
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
    expect((addressed.body as { building_number: string }).building_number).toBe('14');

    // The POS computer of the test: a device of the branch, already paired (O03 fixture).
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

    const p1 = await call('post', '/api/products', owner, {
      name_ar: 'تلفزيون 55 بوصة',
      sku: 'T02-TV',
      cash_price: '1140.00',
      eta_item_code: `EG-${RIN}-TV55`,
      eta_item_type: 'EGS',
    });
    expect(p1.status, JSON.stringify(p1.body)).toBe(201);
    tv = (p1.body as { id: string }).id;
    const p2 = await call('post', '/api/products', owner, {
      name_ar: 'كنبة',
      sku: 'T02-SOFA',
      cash_price: '1140.00',
    });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    sofa = (p2.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      {
        branch_id: branch,
        reason: 'found',
        lines: [
          { product_id: tv, quantity: 40 },
          { product_id: sofa, quantity: 5 },
        ],
      },
      { key: `t02-it-stock-${STAMP}` },
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    const shift = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: branch, opening_float: '0', device_id: device },
      { key: `t02-it-shift-${STAMP}` },
    );
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
  }, 120_000);

  afterAll(async () => {
    // Nothing of this shop may be left for a real worker: ETA off, its jobs gone.
    if (org) {
      await service.from('eta_settings').update({ is_enabled: false }).eq('organization_id', org);
      await service.from('jobs').delete().eq('organization_id', org).like('job_type', 'eta.%');
    }
    await fake?.close();
    for (const [name, value] of savedEnv) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  });

  it('settings and devices answer whether a secret is stored, never the secret', async () => {
    const settings = await call('get', '/api/eta/settings', owner);
    expect(settings.status).toBe(200);
    expect(settings.body).toMatchObject({
      environment: 'preprod',
      client_id: CLIENT_ID,
      has_client_secret: true,
      activity_code: '4753',
      is_enabled: true,
    });
    const devices = await call('get', '/api/devices', owner);
    expect(devices.status).toBe(200);
    expect(devices.body).toEqual([
      expect.objectContaining({
        id: device,
        name: 'Till 1',
        eta_serial: SERIAL,
        eta_status: 'active',
        has_preshared_key: true,
      }),
    ]);
    for (const res of [settings, devices]) {
      expect(res.text).not.toContain(SECRET);
      expect(res.text).not.toContain(KEY);
      expect(res.text).not.toMatch(/vault/i);
    }
    // Stored in Vault, not in the tables; and the audit rows of both writes carry neither.
    const row = await service.from('eta_settings').select('*').eq('organization_id', org).single();
    expect(JSON.stringify(row.data)).not.toContain(SECRET);
    expect(
      (row.data as { client_secret_vault_id: string | null }).client_secret_vault_id,
    ).toBeTruthy();
    const audit = await service
      .from('audit_log')
      .select('action, before, after')
      .eq('organization_id', org)
      .in('action', ['eta.settings_updated', 'device.eta_updated']);
    expect(audit.data).toHaveLength(2);
    expect(JSON.stringify(audit.data)).not.toContain(SECRET);
    expect(JSON.stringify(audit.data)).not.toContain(KEY);
  });

  it('the connection test logs the POS in, and answers the ETA code when it is refused', async () => {
    const ok = await call('post', '/api/eta/settings/test', owner, { device_id: device });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body).toEqual({ ok: true, message: null });

    const wrong = await call('put', `/api/devices/${device}/eta`, owner, {
      eta_serial: SERIAL,
      eta_os_version: 'android 14',
      eta_model_framework: '1',
      preshared_key: 'not-the-key',
      eta_status: 'active',
    });
    expect(wrong.status).toBe(200);
    const refused = await call('post', '/api/eta/settings/test', owner, { device_id: device });
    expect(refused.body).toEqual({ ok: false, message: 'invalid_presharedkey' });
    expect(refused.text).not.toContain('not-the-key');

    const restored = await call('put', `/api/devices/${device}/eta`, owner, {
      eta_serial: SERIAL,
      eta_os_version: 'android 14',
      eta_model_framework: '1',
      preshared_key: KEY,
      eta_status: 'active',
    });
    expect(restored.status).toBe(200);
    const again = await call('post', '/api/eta/settings/test', owner, { device_id: device });
    expect(again.body).toEqual({ ok: true, message: null });
  });

  it('happy path: three sales are chained, answer their QR text, and end accepted', async () => {
    const s1 = await sell();
    const s2 = await sell();
    const s3 = await sell();
    const f1 = await fiscalOf(s1.id);
    const f2 = await fiscalOf(s2.id);
    const f3 = await fiscalOf(s3.id);

    // The receipt was built with the sale: the answer has the UUID and the QR text.
    for (const [sale, row] of [
      [s1, f1],
      [s2, f2],
      [s3, f3],
    ] as const) {
      expect(row.eta_uuid).toMatch(/^[0-9a-f]{64}$/);
      expect(sale.eta).toEqual({
        status: 'pending',
        uuid: row.eta_uuid,
        qr_payload: row.qr_payload,
        last_error_code: null,
      });
      // The receipt's time: the sale's, in UTC, cut to whole seconds.
      const issued = new Date(sale.issued_at).toISOString().slice(0, 19) + 'Z';
      expect(sale.eta?.qr_payload).toBe(
        `${PORTAL}/receipts/search/${row.eta_uuid}/share/${issued}#Total:1140.00,IssuerRIN:${RIN}`,
      );
      expect(row.device_id).toBe(device);
      expect(row.environment).toBe('preprod');
    }
    // The chain: the first receipt of the POS has no previous, each next one names the one before.
    expect(f1.previous_uuid).toBe('');
    expect(f2.previous_uuid).toBe(f1.eta_uuid);
    expect(f3.previous_uuid).toBe(f2.eta_uuid);
    const tail = await service.from('devices').select('eta_last_uuid').eq('id', device).single();
    expect((tail.data as { eta_last_uuid: string }).eta_last_uuid).toBe(f3.eta_uuid);

    // While receipts are on their way the shop can't move to the other ETA system.
    const busy = await call('put', '/api/eta/settings', owner, {
      environment: 'prod',
      client_id: CLIENT_ID,
      activity_code: '4753',
      is_enabled: true,
    });
    expect(busy.status).toBe(409);
    expect(code(busy)).toBe('ETA_ENV_BUSY');

    await drain();
    for (const sale of [s1, s2, s3]) {
      const row = await fiscalOf(sale.id);
      expect(row).toMatchObject({ status: 'accepted', attempts: 0, last_error: null });
      expect(row.eta_long_id).toBe(`LONG-${sale.number}`);
      expect(row.eta_submission_uuid).toMatch(/^FAKESUB/);
      expect(row.submitted_at).not.toBeNull();
      expect(row.accepted_at).not.toBeNull();
      expect(fake.received.get(row.eta_uuid ?? '')).toBe(1);
      // What the ETA got is, byte for byte, what was hashed and stored.
      expect(fake.receipts.get(row.eta_uuid ?? '')?.json).toBe(row.payload?.receipt_json);
      expect(await etaOf(sale.id)).toMatchObject({ status: 'accepted', uuid: row.eta_uuid });
    }
    // One submission for the three, in issue order; the fake found every UUID to be the hash of
    // what it received, and the chain unbroken.
    expect(
      new Set([f1, f2, f3].map((f) => fake.receipts.get(f.eta_uuid ?? '')?.submissionUuid)).size,
    ).toBe(1);
    expect(fake.badHashes).toEqual([]);
    expect(fake.chainBreaks).toEqual([]);
    const sent = JSON.parse(fake.receipts.get(f1.eta_uuid ?? '')?.json ?? '{}') as {
      documentType: object;
      seller: {
        rin: string;
        deviceSerialNumber: string;
        branchAddress: { buildingNumber: string };
      };
      totalAmount: number;
    };
    expect(sent.documentType).toEqual({ receiptType: 's', typeVersion: '1.2' });
    expect(sent.seller).toMatchObject({
      rin: RIN,
      deviceSerialNumber: SERIAL,
      branchAddress: { buildingNumber: '14' },
    });
    expect(sent.totalAmount).toBe(1140);
  });

  it('done when (2): the ETA took the submission but the answer never came -> looked up, not sent again', async () => {
    const lookups = fake.calls.lookup;
    const submits = fake.calls.submit;
    fake.failNextSubmit('accept-then-drop');
    const sale = await sell();
    await drain();
    const row = await fiscalOf(sale.id);
    expect(row.status).toBe('accepted');
    expect(row.attempts).toBe(1); // the send whose outcome was unknown
    expect(fake.received.get(row.eta_uuid ?? '')).toBe(1); // received once, never resubmitted
    expect(fake.calls.submit).toBe(submits + 1);
    expect(fake.calls.lookup).toBe(lookups + 1);
    expect(row.eta_submission_uuid).toBe(fake.receipts.get(row.eta_uuid ?? '')?.submissionUuid);
  });

  it('422 DuplicateSubmission: waits for Retry-After, looks the receipt up, sends nothing twice', async () => {
    const lookups = fake.calls.lookup;
    const submits = fake.calls.submit;
    fake.failNextSubmit('duplicate', 0);
    const sale = await sell();
    const started = Date.now();
    await drain();
    const row = await fiscalOf(sale.id);
    expect(row.status).toBe('accepted');
    expect(Date.now() - started).toBeGreaterThanOrEqual(900); // Retry-After 0 + 1 s
    expect(fake.received.get(row.eta_uuid ?? '')).toBe(1);
    expect(fake.calls.submit).toBe(submits + 1);
    expect(fake.calls.lookup).toBe(lookups + 1);
  });

  it('a 503 that took nothing: looked up, not found, sent again -> still received once', async () => {
    const submits = fake.calls.submit;
    fake.failNextSubmit('unavailable');
    const sale = await sell();
    await drain();
    const row = await fiscalOf(sale.id);
    expect(row.status).toBe('accepted');
    expect(row.attempts).toBe(1);
    expect(fake.calls.submit).toBe(submits + 2);
    expect(fake.received.get(row.eta_uuid ?? '')).toBe(1);
  });

  it('TEST4: three outage receipts grow attempts, appear in monitor, recover in order and clear alerts', async () => {
    const sales = [await sell(), await sell(), await sell()];
    for (let attempt = 1; attempt <= 2; attempt++) {
      fake.failNextSubmit('unavailable');
      await worker.tick();
      let failedCount = 0;
      for (const sale of sales) {
        const row = await fiscalOf(sale.id);
        expect(row.attempts).toBe(attempt);
        expect(fake.received.has(row.eta_uuid ?? '')).toBe(false);
        const monitor = await call(
          'get',
          `/api/fiscal?q=${encodeURIComponent(sale.number)}`,
          owner,
        );
        expect(monitor.status, JSON.stringify(monitor.body)).toBe(200);
        const situation = (monitor.body as { items: { situation: string }[] }).items[0]?.situation;
        expect(['send_failed', 'waiting']).toContain(situation);
        if (situation === 'send_failed') failedCount++;
      }
      const summary = await call('get', '/api/fiscal/summary', owner);
      expect(summary.status).toBe(200);
      expect(summary.body).toMatchObject({ send_failed: failedCount, blocked: 0, rejected: 0 });
    }
    await drain();
    const rows = await Promise.all(sales.map((sale) => fiscalOf(sale.id)));
    for (const row of rows) {
      expect(row.status).toBe('accepted');
      expect(fake.received.get(row.eta_uuid ?? '')).toBe(1);
    }
    expect(rows[1]?.previous_uuid).toBe(rows[0]?.eta_uuid);
    expect(rows[2]?.previous_uuid).toBe(rows[1]?.eta_uuid);
    const submitted = [...fake.receipts.keys()].filter((uuid) =>
      rows.some((row) => row.eta_uuid === uuid),
    );
    expect(submitted).toEqual(rows.map((row) => row.eta_uuid));
    const recovered = await call('get', '/api/fiscal/summary', owner);
    expect(recovered.body).toMatchObject({ send_failed: 0, blocked: 0, rejected: 0 });
  }, 60000);

  it('a receipt the ETA finds Invalid is rejected with its reason; the chain goes on from it', async () => {
    fake.invalidNext('ItemCode [EG-X] is not registered for this taxpayer');
    const bad = await sell();
    await drain();
    const row = await fiscalOf(bad.id);
    expect(row.status).toBe('rejected');
    expect(row.last_error).toBe(
      'ETA_INVALID: CV307 ItemCode [EG-X] is not registered for this taxpayer',
    );
    expect(row.accepted_at).toBeNull();
    expect(await etaOf(bad.id)).toMatchObject({
      status: 'rejected',
      last_error_code: 'ETA_INVALID',
    });
    expect(
      alerts('invalid').some(([, tags]) => (tags as { fiscalId?: string }).fiscalId === row.id),
    ).toBe(true);

    const next = await sell();
    expect((await fiscalOf(next.id)).previous_uuid).toBe(row.eta_uuid);
    await drain();
    expect((await fiscalOf(next.id)).status).toBe('accepted');
  });

  it('a product without an ETA code blocks only its own receipt; fixed and retried, it is accepted', async () => {
    const before = await sell();
    const blocked = await sell(sofa);
    const after = await sell();

    expect(blocked.eta).toEqual({
      status: 'failed',
      uuid: null,
      qr_payload: null,
      last_error_code: 'BLOCKED:ITEM_CODE',
    });
    const row = await fiscalOf(blocked.id);
    expect(row.last_error).toMatch(/^BLOCKED:ITEM_CODE: .*T02-SOFA/);
    expect(row.eta_uuid).toBeNull();
    expect(
      alerts('BLOCKED:ITEM_CODE').some(
        ([, tags]) => (tags as { fiscalId?: string }).fiscalId === row.id,
      ),
    ).toBe(true);
    // The sale after it is chained to the sale before it.
    expect((await fiscalOf(after.id)).previous_uuid).toBe((await fiscalOf(before.id)).eta_uuid);
    await drain();
    expect((await fiscalOf(after.id)).status).toBe('accepted');
    expect((await fiscalOf(blocked.id)).status).toBe('failed'); // no automatic retry

    // Not retryable while it is fine; retryable once it failed. After the fix it goes through.
    const fine = await call(
      'post',
      `/api/eta/submissions/${(await fiscalOf(after.id)).id}/retry`,
      owner,
    );
    expect(fine.status).toBe(409);
    expect(code(fine)).toBe('FISCAL_NOT_RETRYABLE');
    const fixed = await call('patch', `/api/products/${sofa}`, owner, {
      eta_item_code: `EG-${RIN}-SOFA`,
      eta_item_type: 'EGS',
    });
    expect(fixed.status, JSON.stringify(fixed.body)).toBe(200);
    const retried = await call('post', `/api/eta/submissions/${row.id}/retry`, owner);
    expect(retried.status, JSON.stringify(retried.body)).toBe(200);
    expect(retried.body).toEqual({ id: row.id, status: 'pending' });
    await drain();
    const done = await fiscalOf(blocked.id);
    expect(done.status).toBe('accepted');
    expect(done.previous_uuid).toBe((await fiscalOf(after.id)).eta_uuid);
    expect(fake.received.get(done.eta_uuid ?? '')).toBe(1);
  });

  it('two sales at the same moment on one POS end in one chain, in issue order', async () => {
    const tailBefore = await service
      .from('devices')
      .select('eta_last_uuid')
      .eq('id', device)
      .single();
    const [a, b] = await Promise.all([sell(), sell()]);
    await drain();
    const [first, second] = [a, b].sort(
      (x, y) => x.issued_at.localeCompare(y.issued_at) || x.number.localeCompare(y.number),
    );
    const f1 = await fiscalOf(first!.id);
    const f2 = await fiscalOf(second!.id);
    // No gap and no fork: the earlier one follows the old tail, the later one follows it.
    expect(f1.previous_uuid).toBe((tailBefore.data as { eta_last_uuid: string }).eta_last_uuid);
    expect(f2.previous_uuid).toBe(f1.eta_uuid);
    expect(f1.eta_uuid).not.toBe(f2.eta_uuid);
    expect(f1.status).toBe('accepted');
    expect(f2.status).toBe('accepted');
    expect(fake.received.get(f1.eta_uuid ?? '')).toBe(1);
    expect(fake.received.get(f2.eta_uuid ?? '')).toBe(1);
    const tail = await service.from('devices').select('eta_last_uuid').eq('id', device).single();
    expect((tail.data as { eta_last_uuid: string }).eta_last_uuid).toBe(f2.eta_uuid);
  });

  it('a receipt still pending 20 hours after its sale alerts eta.failed exactly once', async () => {
    fake.failNextSubmit('unavailable'); // the first send fails, so the receipt is pending when checked
    const sale = await sell();
    const row = await fiscalOf(sale.id);
    await drain(lateWorker);
    const mine = alerts('deadline').filter(
      ([, tags]) => (tags as { fiscalId?: string }).fiscalId === row.id,
    );
    expect(mine).toHaveLength(1);
    expect(mine[0]?.[1]).toMatchObject({ problem: 'eta.failed', reason: 'deadline', orgId: org });
    // It kept trying, and got there.
    expect((await fiscalOf(sale.id)).status).toBe('accepted');

    // Later runs don't alert for it again, and nothing else of the shop was late.
    await lateWorker.tick();
    expect(alerts('deadline')).toHaveLength(1);
  });

  it('every receipt of the run was received exactly once, hashed right and chained', async () => {
    const { data, error } = await service
      .from('fiscal_submissions')
      .select('eta_uuid, status')
      .eq('organization_id', org);
    expect(error).toBeNull();
    const rows = data as { eta_uuid: string | null; status: string }[];
    expect(rows.length).toBeGreaterThanOrEqual(13);
    for (const row of rows) {
      expect(['accepted', 'rejected']).toContain(row.status);
      expect(fake.received.get(row.eta_uuid ?? '')).toBe(1);
    }
    expect(new Set(rows.map((r) => r.eta_uuid)).size).toBe(rows.length);
    expect(fake.badHashes).toEqual([]);
    expect(fake.chainBreaks).toEqual([]);
    expect(await openJobs()).toEqual([]);
  });

  it("cross-shop: another shop can't read or retry these receipts, or touch the POS", async () => {
    const other = await login('owner.two@ecotech.test');
    const sale = await sell();
    await drain();
    const row = await fiscalOf(sale.id);

    // In its own shop it finds nothing of ours.
    const retry = await call('post', `/api/eta/submissions/${row.id}/retry`, other, undefined, {
      orgId: null,
    });
    expect(retry.status).toBe(404);
    expect(code(retry)).toBe('FISCAL_NOT_FOUND');
    const read = await call('get', `/api/sales/${sale.id}`, other, undefined, { orgId: null });
    expect(read.status).toBe(404);
    expect(code(read)).toBe('SALE_NOT_FOUND');
    const registration = await call(
      'put',
      `/api/devices/${device}/eta`,
      other,
      {
        eta_serial: 'STOLEN',
        eta_os_version: 'os',
        eta_model_framework: '1',
        eta_status: 'pending',
      },
      { orgId: null },
    );
    expect(registration.status).toBe(404);
    expect(code(registration)).toBe('DEVICE_NOT_FOUND');
    const test = await call(
      'post',
      '/api/eta/settings/test',
      other,
      { device_id: device },
      { orgId: null },
    );
    expect(test.status).toBe(404);
    const list = await call('get', '/api/devices', other, undefined, { orgId: null });
    expect(list.status).toBe(200);
    expect(JSON.stringify(list.body)).not.toContain(device);
    // Aimed at our shop by header it is refused outright.
    const aimed = await call('post', `/api/eta/submissions/${row.id}/retry`, other);
    expect(aimed.status).toBe(403);
    expect(code(aimed)).toBe('SHOP_NOT_ALLOWED');
    const settings = await call('get', '/api/eta/settings', other);
    expect(settings.status).toBe(403);

    // Nothing of ours changed.
    expect(await fiscalOf(sale.id)).toMatchObject({ status: 'accepted', eta_uuid: row.eta_uuid });
    const mine = await call('get', '/api/devices', owner);
    expect((mine.body as { eta_serial: string }[])[0]?.eta_serial).toBe(SERIAL);
  });

  it('a cashier cannot change the ETA settings, the POS registration or retry a receipt', async () => {
    const email = `t02.cashier.${STAMP}@ecotech.test`;
    const user = await service.auth.admin.createUser({
      email,
      password: PASSWORD,
      email_confirm: true,
    });
    expect(user.error).toBeNull();
    const emp = await service
      .from('employees')
      .insert({
        organization_id: org,
        auth_user_id: user.data.user!.id,
        email,
        full_name: 'T02 Cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    const cashier = await login(email);
    const row = await service
      .from('fiscal_submissions')
      .select('id')
      .eq('organization_id', org)
      .eq('status', 'rejected')
      .limit(1)
      .single();
    for (const res of [
      await call('get', '/api/eta/settings', cashier),
      await call('put', '/api/eta/settings', cashier, {
        environment: 'preprod',
        client_id: null,
        activity_code: null,
        is_enabled: false,
      }),
      await call('post', '/api/eta/settings/test', cashier, { device_id: device }),
      await call('put', `/api/devices/${device}/eta`, cashier, {
        eta_serial: SERIAL,
        eta_os_version: 'os',
        eta_model_framework: '1',
        eta_status: 'revoked',
      }),
      await call('get', '/api/devices', cashier),
      await call('post', `/api/eta/submissions/${(row.data as { id: string }).id}/retry`, cashier),
    ]) {
      expect(res.status, JSON.stringify(res.body)).toBe(403);
      expect(code(res)).toBe('PERMISSION_DENIED');
    }
    const settings = await call('get', '/api/eta/settings', owner);
    expect(settings.body).toMatchObject({ is_enabled: true, client_id: CLIENT_ID });
  });
});
