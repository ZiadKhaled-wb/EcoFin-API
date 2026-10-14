// T03 against local Supabase and a fake ETA (RUN_INTEGRATION=1, env as in eta.integration.test.ts).
// A receipt the ETA finds Invalid shows the ETA's reason; after the product is fixed, "correct" queues
// a job that rebuilds it with a NEW UUID, the SAME previousUUID and referenceOldUUID = the rejected
// UUID, and the fake ETA accepts it. Without a fix nothing is sent. A blocked receipt becomes
// prepared once its data is fixed (and a receipt without a POS once a POS is assigned). The POS
// chain follows a corrected receipt only when it was the newest. Two corrections at once give one
// new UUID. Every rule also holds when the database is called directly.
import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import request from 'supertest';
import { createClient, type SupabaseClient } from '@supabase/supabase-js';
import {
  AuthLoginResponse,
  ErrorResponse,
  FiscalDetails,
  FiscalList,
  Sale,
} from '@ziadkhaled-wb/contracts';
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
import { etaJobHandlers } from './jobs';
import { supabaseEtaStore } from './store';

vi.mock('../utils/monitoring', async (original) => ({
  ...(await original<typeof import('../utils/monitoring')>()),
  captureProblem: vi.fn(),
}));

const RUN = process.env['RUN_INTEGRATION'] === '1';
const PASSWORD = 'LocalDev-Only-2026!';
const STAMP = Date.now();
const CLIENT_ID = `t03-client-${STAMP}`;
const SECRET = `t03-secret-${STAMP}`;
const SERIAL = `T03-POS-${STAMP}`;
const KEY = `t03-preshared-${STAMP}`;
const RIN = '674859545';
const ETA_ENV = ['ETA_PREPROD_ID_URL', 'ETA_PREPROD_API_URL', 'ETA_PREPROD_PORTAL_URL'] as const;

interface FiscalRow {
  id: string;
  status: string;
  eta_uuid: string | null;
  previous_uuid: string | null;
  reference_old_uuid: string | null;
  last_error: string | null;
  device_id: string | null;
  payload: { receipt_json?: string } | null;
}

describe.skipIf(!RUN)('T03 ETA monitor and corrections against local stack and a fake ETA', () => {
  let app: ReturnType<typeof createApp>;
  let service: SupabaseClient;
  let fake: FakeEta;
  let worker: JobWorker;
  let owner = '';
  let org = '';
  let branch = '';
  let device = '';
  let pos = '';
  let supabaseUrl = '';
  let anonKey = '';
  const savedEnv = new Map<string, string | undefined>();
  let ip = 0;
  let counter = 0;

  const call = (
    method: 'get' | 'post' | 'put' | 'patch',
    path: string,
    token: string,
    body?: object,
    options: { key?: string; orgId?: string | null } = {},
  ) => {
    const r = request(app)
      [method](path)
      .set('X-Forwarded-For', `198.18.91.${(++ip % 250) + 1}`)
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
      .set('X-Forwarded-For', `198.18.91.${(++ip % 250) + 1}`)
      .send({ identifier: email, password: PASSWORD });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    return AuthLoginResponse.parse(r.body).accessToken;
  }

  async function newProduct(itemCode: string | null): Promise<string> {
    const n = ++counter;
    const made = await call('post', '/api/products', owner, {
      name_ar: `منتج ${n}`,
      sku: `T03-${STAMP}-${n}`,
      cash_price: '1140.00',
      ...(itemCode ? { eta_item_code: itemCode, eta_item_type: 'EGS' } : {}),
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const id = (made.body as { id: string }).id;
    const stocked = await call(
      'post',
      '/api/stock/adjustments',
      owner,
      { branch_id: branch, reason: 'found', lines: [{ product_id: id, quantity: 20 }] },
      { key: `t03-it-stock-${STAMP}-${n}` },
    );
    expect(stocked.status, JSON.stringify(stocked.body)).toBe(201);
    return id;
  }
  async function setCode(product: string, itemCode: string) {
    const res = await call('patch', `/api/products/${product}`, owner, {
      eta_item_code: itemCode,
      eta_item_type: 'EGS',
    });
    expect(res.status, JSON.stringify(res.body)).toBe(200);
  }
  async function sell(product: string): Promise<Sale> {
    const res = await call(
      'post',
      '/api/sales',
      owner,
      { lines: [{ product_id: product, quantity: 1 }], expected_total: '1140.00' },
      { key: `t03-it-sale-${STAMP}-${++counter}` },
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
  async function drain(timeoutMs = 20_000) {
    const until = Date.now() + timeoutMs;
    for (;;) {
      const result = await worker.tick();
      const open = await openJobs();
      const broken = open.filter((job) => job.status === 'failed' || job.status === 'dead');
      if (broken.length > 0) throw new Error(`an ETA job failed: ${JSON.stringify(broken)}`);
      if (open.length === 0) return;
      if (Date.now() > until) throw new Error(`ETA jobs did not drain: ${JSON.stringify(open)}`);
      if (result.succeeded === 0) await new Promise((resolve) => setTimeout(resolve, 150));
    }
  }
  const details = async (id: string) => {
    const res = await call('get', `/api/fiscal/${id}`, owner);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    return FiscalDetails.parse(res.body);
  };
  /** A sale of `product` that the ETA finds Invalid on the item code. */
  async function rejectedSale(product: string) {
    fake.invalidNext({
      code: 'CV307',
      propertyPath: 'itemData[0].itemCode',
      message: 'the item code is not registered',
    });
    const sale = await sell(product);
    await drain();
    const row = await fiscalOf(sale.id);
    expect(row.status).toBe('rejected');
    return { sale, row };
  }
  async function fixAndCorrect(product: string, row: FiscalRow, itemCode: string) {
    await setCode(product, itemCode);
    const queued = await call('post', `/api/fiscal/${row.id}/correct`, owner);
    expect(queued.status, JSON.stringify(queued.body)).toBe(202);
    await drain();
    return fiscalOf((await details(row.id)).sale.id);
  }
  /** A sale made before POS devices: a copy of a real sale without a POS. */
  async function legacySale(product: string): Promise<string> {
    const real = await sell(product);
    const { data: s } = await service.from('sales').select('*').eq('id', real.id).single();
    const { data: lines } = await service.from('sale_lines').select('*').eq('sale_id', real.id);
    const id = randomUUID();
    const n = ++counter;
    const made = await service.from('sales').insert({
      ...s,
      id,
      number: `T03-LEG-${STAMP}-${n}`,
      idempotency_key: `t03-legacy-${STAMP}-${n}`,
      device_id: null,
      shift_id: null,
    });
    expect(made.error, JSON.stringify(made.error)).toBeNull();
    const copied = await service
      .from('sale_lines')
      .insert((lines ?? []).map((l) => ({ ...l, id: randomUUID(), sale_id: id })));
    expect(copied.error, JSON.stringify(copied.error)).toBeNull();
    return id;
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
    process.env['ETA_PREPROD_PORTAL_URL'] = 'https://portal.fake-eta.test';
    const env = getEnv();
    supabaseUrl = env.SUPABASE_URL;
    anonKey = env.SUPABASE_ANON_KEY;
    app = createApp({ env });
    service = createClient(env.SUPABASE_URL, env.SUPABASE_SERVICE_ROLE_KEY, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const logger = createLogger({ level: 'silent' });
    const hosts = etaHosts(env);
    worker = new JobWorker({
      store: supabaseJobStore(service),
      handlers: etaJobHandlers({
        store: supabaseEtaStore(service),
        client: new EtaClient({ hosts, logger, timeoutMs: 5000 }),
        hosts,
        logger,
        lookupGapMs: 0,
        retryDelaysSeconds: [0],
        pollDelaysSeconds: [0],
      }),
      logger,
      batchSize: 50,
    });

    const admin = await login('superadmin@ecotech.test');
    const email = `t03.owner.${STAMP}@ecotech.test`;
    const shop = await request(app)
      .post('/api/admin/shops')
      .set('X-Forwarded-For', `198.18.91.${(++ip % 250) + 1}`)
      .set('Authorization', 'Bearer ' + admin)
      .send({
        name: 'T03 shop',
        tenant_slug: `t03-${STAMP}`,
        plan_key: 'retail_pro',
        owner: { full_name: 'Owner', email },
      });
    expect(shop.status, JSON.stringify(shop.body)).toBe(201);
    org = shop.body.organization_id as string;
    const accepted = await request(app)
      .post('/api/auth/invites/accept')
      .set('X-Forwarded-For', `198.18.91.${(++ip % 250) + 1}`)
      .send({ token: await readInviteToken(email), password: PASSWORD });
    expect(accepted.status, JSON.stringify(accepted.body)).toBe(200);
    owner = await login(email);

    await service
      .from('organizations')
      .update({ tax_registration_no: RIN, legal_name: 'T03 Furniture LLC' })
      .eq('id', org);
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
    const shift = await call(
      'post',
      '/api/shifts',
      owner,
      { branch_id: branch, opening_float: '0', device_id: device },
      { key: `t03-it-shift-${STAMP}` },
    );
    expect(shift.status, JSON.stringify(shift.body)).toBe(201);
  }, 120_000);

  afterAll(async () => {
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

  it('done when, part 1: a rejected receipt shows the ETA reason and is resent as a corrected receipt', async () => {
    const product = await newProduct('EG-BAD-CODE');
    const { sale, row } = await rejectedSale(product);

    // The ETA's reason, in plain parts, with the screen that fixes it.
    const shown = await details(row.id);
    expect(shown.situation).toBe('rejected');
    expect(shown.diagnosis.action).toBe('correct');
    const reason = shown.diagnosis.problems.find((p) => p.code === 'ETA_REJECTED');
    expect(reason?.eta_error).toMatchObject({
      message: 'the item code is not registered',
      property_path: 'itemData[0].itemCode',
      nothing_changed: false,
    });
    expect(reason?.fix).toBe('product');
    expect(JSON.stringify(shown)).not.toContain('receipt_json');
    const listed = FiscalList.parse(
      (await call('get', '/api/fiscal?situation=problem&limit=100', owner)).body,
    );
    expect(listed.items.some((i) => i.id === row.id && i.situation === 'rejected')).toBe(true);

    // A plain retry would be rejected again: refused.
    const plain = await call('post', `/api/fiscal/${row.id}/retry`, owner);
    expect(plain.status).toBe(409);
    expect(code(plain)).toBe('USE_CORRECTION');
    const old = await call('post', `/api/eta/submissions/${row.id}/retry`, owner);
    expect(old.status).toBe(409);
    expect(code(old)).toBe('USE_CORRECTION');

    // Part 2 of "nothing changed": the data was not fixed, so nothing is sent.
    const submits = fake.calls.submit;
    const unchanged = await call('post', `/api/fiscal/${row.id}/correct`, owner);
    expect(unchanged.status, JSON.stringify(unchanged.body)).toBe(202);
    await drain();
    const after = await fiscalOf(sale.id);
    expect(after.status).toBe('rejected');
    expect(after.eta_uuid).toBe(row.eta_uuid);
    expect(after.last_error).toMatch(/^CORRECTION_NOTHING_CHANGED: /);
    expect(fake.calls.submit).toBe(submits);
    const again = await details(row.id);
    expect(
      again.diagnosis.problems.find((p) => p.code === 'ETA_REJECTED')?.eta_error?.nothing_changed,
    ).toBe(true);

    // Fix the product and correct it.
    const corrected = await fixAndCorrect(product, row, 'EG-GOOD-CODE');
    expect(corrected.status).toBe('accepted');
    expect(corrected.eta_uuid).not.toBe(row.eta_uuid);
    expect(corrected.reference_old_uuid).toBe(row.eta_uuid);
    expect(corrected.previous_uuid).toBe(row.previous_uuid);
    expect(fake.received.get(row.eta_uuid!)).toBe(1);
    expect(fake.received.get(corrected.eta_uuid!)).toBe(1);
    const sent = fake.receipts.get(corrected.eta_uuid!);
    expect(sent?.referenceOldUuid).toBe(row.eta_uuid);
    expect(sent?.previousUuid).toBe(row.previous_uuid ?? '');
    expect(fake.receipts.get(row.eta_uuid!)?.status).toBe('Invalid');
    expect(fake.badHashes).toEqual([]);
    expect(fake.chainBreaks).toEqual([]);

    const eta = Sale.parse((await call('get', `/api/sales/${sale.id}`, owner)).body).eta;
    expect(eta?.uuid).toBe(corrected.eta_uuid);
    expect(eta?.qr_payload).toContain(corrected.eta_uuid!);

    // The timeline shows every UUID the receipt had.
    const final = await details(row.id);
    expect(final.situation).toBe('accepted');
    const uuids = final.events.map((e) => e.eta_uuid).filter((u) => u !== null);
    expect(uuids).toContain(row.eta_uuid);
    expect(uuids).toContain(corrected.eta_uuid);
    expect(final.row.reference_old_uuid).toBe(row.eta_uuid);
  });

  it('done when, part 2: a blocked receipt becomes prepared after its data is fixed', async () => {
    const product = await newProduct(null);
    const sale = await sell(product);
    await drain();
    const blocked = await fiscalOf(sale.id);
    expect(blocked.status).toBe('failed');
    expect(blocked.last_error).toMatch(/^BLOCKED:ITEM_CODE/);

    const shown = await details(blocked.id);
    expect(shown.situation).toBe('blocked');
    expect(shown.diagnosis.ready).toBe(false);
    const problem = shown.diagnosis.problems.find((p) => p.code === 'ITEM_CODE');
    expect(problem?.fix).toBe('product');
    expect(problem?.products?.map((p) => p.product_id)).toEqual([product]);

    await setCode(product, 'EG-NOW-CODED');
    const fixed = await details(blocked.id);
    expect(fixed.diagnosis.problems).toEqual([]);
    expect(fixed.diagnosis.ready).toBe(true);

    const retried = await call('post', `/api/fiscal/${blocked.id}/retry`, owner);
    expect(retried.status, JSON.stringify(retried.body)).toBe(200);
    expect(retried.body).toEqual({ id: blocked.id, status: 'pending' });
    await drain();
    const done = await fiscalOf(sale.id);
    expect(done.status).toBe('accepted');
    expect(done.eta_uuid).toMatch(/^[0-9a-f]{64}$/);
  });

  it('a receipt without a POS is prepared after a POS of its branch is assigned', async () => {
    const product = await newProduct('EG-LEGACY');
    const saleId = await legacySale(product);
    await drain();
    const blocked = await fiscalOf(saleId);
    expect(blocked.status).toBe('failed');
    expect(blocked.last_error).toMatch(/^BLOCKED:NO_DEVICE/);
    const shown = await details(blocked.id);
    expect(shown.diagnosis.action).toBe('assign_device');
    expect(shown.diagnosis.problems[0]).toMatchObject({ code: 'NO_DEVICE', fix: 'assign_device' });

    const assigned = await call('post', `/api/fiscal/${blocked.id}/assign-device`, owner, {
      device_id: device,
    });
    expect(assigned.status, JSON.stringify(assigned.body)).toBe(200);
    await drain();
    const done = await fiscalOf(saleId);
    expect(done.status).toBe('accepted');
    expect(done.device_id).toBe(device);
    const sale = await service.from('sales').select('device_id').eq('id', saleId).single();
    expect(sale.data?.device_id).toBeNull();

    const noDevice = await call('post', `/api/fiscal/${blocked.id}/assign-device`, owner, {
      device_id: device,
    });
    expect(noDevice.status).toBe(409);
    expect(code(noDevice)).toBe('NOT_BLOCKED_NO_DEVICE');
    const bad = await call('post', `/api/fiscal/${blocked.id}/assign-device`, owner, {
      device_id: randomUUID(),
    });
    expect(bad.status).toBe(409); // not blocked any more: that check comes first
  });

  it('chain: correcting the newest receipt moves the head; correcting an older one does not', async () => {
    // Newest: the next sale chains to the corrected UUID.
    const p1 = await newProduct('EG-BAD-1');
    const newest = await rejectedSale(p1);
    const fixed1 = await fixAndCorrect(p1, newest.row, 'EG-OK-1');
    const { data: head } = await service
      .from('devices')
      .select('eta_last_uuid')
      .eq('id', device)
      .single();
    expect(head?.eta_last_uuid).toBe(fixed1.eta_uuid);
    const ok = await newProduct('EG-OK-2');
    const next = await sell(ok);
    await drain();
    const nextRow = await fiscalOf(next.id);
    expect(nextRow.previous_uuid).toBe(fixed1.eta_uuid);
    expect(nextRow.status).toBe('accepted');

    // Older: a later receipt already chains from the rejected one; the head stays where it is.
    const p2 = await newProduct('EG-BAD-3');
    const older = await rejectedSale(p2);
    const later = await sell(ok);
    await drain();
    const laterRow = await fiscalOf(later.id);
    expect(laterRow.previous_uuid).toBe(older.row.eta_uuid);
    const fixed2 = await fixAndCorrect(p2, older.row, 'EG-OK-3');
    expect(fixed2.reference_old_uuid).toBe(older.row.eta_uuid);
    expect(fixed2.previous_uuid).toBe(older.row.previous_uuid);
    const { data: head2 } = await service
      .from('devices')
      .select('eta_last_uuid')
      .eq('id', device)
      .single();
    expect(head2?.eta_last_uuid).toBe(laterRow.eta_uuid);
    const last = await sell(ok);
    await drain();
    expect((await fiscalOf(last.id)).previous_uuid).toBe(laterRow.eta_uuid);
    expect(fixed2.status).toBe('accepted');
    expect(fake.chainBreaks).toEqual([]);
    expect(fake.badHashes).toEqual([]);
  });

  it('race: two corrections at once give one 202, one 409 CORRECTION_QUEUED and one new UUID', async () => {
    const product = await newProduct('EG-BAD-RACE');
    const { row } = await rejectedSale(product);
    await setCode(product, 'EG-OK-RACE');
    const [a, b] = await Promise.all([
      call('post', `/api/fiscal/${row.id}/correct`, owner),
      call('post', `/api/fiscal/${row.id}/correct`, owner),
    ]);
    const statuses = [a.status, b.status].sort();
    expect(statuses, JSON.stringify([a.body, b.body])).toEqual([202, 409]);
    const loser = a.status === 409 ? a : b;
    expect(code(loser)).toBe('CORRECTION_QUEUED');
    await drain();
    const refs = [...fake.receipts.values()].filter((r) => r.referenceOldUuid === row.eta_uuid);
    expect(refs).toHaveLength(1);
    expect(fake.received.get(refs[0]!.uuid)).toBe(1);
  });

  it('a correction of a receipt that is not rejected, and a check on one that is not submitted, are refused', async () => {
    const product = await newProduct('EG-PLAIN');
    const sale = await sell(product);
    await drain();
    const row = await fiscalOf(sale.id);
    expect(row.status).toBe('accepted');
    const notRejected = await call('post', `/api/fiscal/${row.id}/correct`, owner);
    expect(notRejected.status).toBe(409);
    expect(code(notRejected)).toBe('NOT_REJECTED');
    const notSubmitted = await call('post', `/api/fiscal/${row.id}/check-now`, owner);
    expect(notSubmitted.status).toBe(409);
    expect(code(notSubmitted)).toBe('NOT_SUBMITTED');
  });

  it('retry-many, the alert counts and the day summary', async () => {
    const bad = await newProduct('EG-BAD-MANY');
    const rejected = await rejectedSale(bad);
    const blockedProduct = await newProduct(null);
    const blockedSale = await sell(blockedProduct);
    await drain();
    const blocked = await fiscalOf(blockedSale.id);
    await setCode(bad, 'EG-OK-MANY');

    const summary = await call('get', '/api/fiscal/summary', owner);
    expect(summary.status).toBe(200);
    expect(summary.body).toMatchObject({ blocked: 1, rejected: 1 });

    await setCode(blockedProduct, 'EG-OK-BLOCKED');
    const many = await call('post', '/api/fiscal/retry-many', owner, {
      ids: [rejected.row.id, blocked.id, randomUUID()],
    });
    expect(many.status, JSON.stringify(many.body)).toBe(200);
    expect((many.body as { done: number }).done).toBe(2);
    expect((many.body as { skipped: { reason: string }[] }).skipped[0]?.reason).toBe(
      'FISCAL_NOT_FOUND',
    );
    const tooMany = await call('post', '/api/fiscal/retry-many', owner, {
      ids: Array.from({ length: 201 }, () => randomUUID()),
    });
    expect(tooMany.status).toBe(400);
    await drain();
    expect((await fiscalOf(rejected.sale.id)).status).toBe('accepted');
    expect((await fiscalOf(blockedSale.id)).status).toBe('accepted');

    const day = await call(
      'get',
      `/api/fiscal/day-summary?branch_id=${branch}&date=${new Date().toISOString().slice(0, 10)}`,
      owner,
    );
    expect(day.status, JSON.stringify(day.body)).toBe(200);
    expect(day.body).toMatchObject({ all_accepted: true, rejected: 0, blocked: 0 });
  });

  it('direct-database path: a cashier is denied; the worker functions are not executable', async () => {
    const email = `t03.cashier.${STAMP}@ecotech.test`;
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
        full_name: 'T03 Cashier',
        role: 'CASHIER',
        default_branch_id: branch,
      })
      .select('id')
      .single();
    expect(emp.error).toBeNull();
    await service
      .from('employee_branches')
      .insert({ organization_id: org, employee_id: emp.data!.id, branch_id: branch });
    const token = await login(email);
    const direct: SupabaseClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${token}`, 'x-org-id': org } },
    });
    const id = (
      await service
        .from('fiscal_submissions')
        .select('id')
        .eq('organization_id', org)
        .limit(1)
        .single()
    ).data!.id as string;
    for (const [fn, args] of [
      ['fiscal_request_correction', { p_id: id }],
      ['fiscal_assign_device', { p_id: id, p_device_id: device }],
      ['fiscal_retry_many', { p_ids: [id] }],
      ['fiscal_check_now', { p_id: id }],
      ['retry_fiscal_submission', { p_id: id }],
      ['fiscal_list', {}],
    ] as const) {
      const res = await direct.rpc(fn, args);
      expect(res.error?.message, fn).toMatch(/^PERMISSION_DENIED/);
    }
    for (const [fn, args] of [
      [
        'eta_store_correction',
        {
          p_id: id,
          p_expected_old_uuid: 'a'.repeat(64),
          p_new_uuid: 'b'.repeat(64),
          p_payload: {},
          p_qr: 'x',
        },
      ],
      ['eta_load_for_correction', { p_fiscal_id: id }],
      ['eta_note_correction', { p_id: id, p_expected_old_uuid: 'a'.repeat(64), p_error: 'x' }],
    ] as const) {
      const res = await direct.rpc(fn, args);
      expect(res.error?.code, fn).toBe('42501');
    }
    const events = await direct.from('fiscal_events').select('id');
    expect(events.data ?? []).toEqual([]);
    for (const path of ['/api/fiscal', '/api/fiscal/summary', `/api/fiscal/${id}`]) {
      const res = await call('get', path, token);
      expect(res.status, path).toBe(403);
      expect(code(res)).toBe('PERMISSION_DENIED');
    }
    for (const path of [`/api/fiscal/${id}/retry`, `/api/fiscal/${id}/correct`]) {
      const res = await call('post', path, token);
      expect(res.status, path).toBe(403);
    }
    expect(captureProblem).toBeDefined();
  });

  it("cross-shop: another shop's receipts are not found on any :id route", async () => {
    const other = await login('owner.two@ecotech.test');
    const sale = await sell(await newProduct('EG-XSHOP'));
    await drain();
    const id = (await fiscalOf(sale.id)).id;
    for (const [method, path, body] of [
      ['get', `/api/fiscal/${id}`, undefined],
      ['post', `/api/fiscal/${id}/retry`, undefined],
      ['post', `/api/fiscal/${id}/correct`, undefined],
      ['post', `/api/fiscal/${id}/check-now`, undefined],
      ['post', `/api/fiscal/${id}/assign-device`, { device_id: device }],
    ] as const) {
      const res = await call(method, path, other, body, { orgId: null });
      expect(res.status, path).toBe(404);
      expect(code(res)).toBe('FISCAL_NOT_FOUND');
    }
    const many = await call(
      'post',
      '/api/fiscal/retry-many',
      other,
      { ids: [id] },
      { orgId: null },
    );
    expect(many.body).toEqual({ done: 0, skipped: [{ id, reason: 'FISCAL_NOT_FOUND' }] });
    const list = await call('get', '/api/fiscal?limit=100', other, undefined, { orgId: null });
    expect(JSON.stringify(list.body)).not.toContain(id);
    const aimed = await call('get', `/api/fiscal/${id}`, other);
    expect(aimed.status).toBe(403);
  });
});
